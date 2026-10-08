#!/usr/bin/env node

import { existsSync } from 'node:fs'
import { readdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const origin = 'https://docs.adaengine.org'
const sitemapLimit = 10_000

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character])
}

function plainText(inline) {
  if (!Array.isArray(inline)) return ''
  return inline.map((item) => item.text ?? item.code ?? '').join('').replace(/\s+/g, ' ').trim()
}

async function* htmlPages(directory, relative = '') {
  for (const entry of await readdir(path.join(directory, relative), { withFileTypes: true })) {
    const next = path.join(relative, entry.name)
    if (entry.isDirectory()) yield* htmlPages(directory, next)
    else if (entry.isFile() && entry.name === 'index.html') yield next
  }
}

function renderPage(html, url, document) {
  const title = document.metadata?.title
  if (!title || !html.includes('<div id="app"></div>') || !html.includes('</head>')) {
    throw new Error(`Unexpected DocC page format: ${url}`)
  }

  const module = document.metadata.modules?.[0]?.name
  const pageTitle = module && module !== title ? `${title} | ${module} Documentation` : `${title} | Ada Documentation`
  const abstract = plainText(document.abstract)
  const content = document.primaryContentSections?.find((section) => section.kind === 'content')?.content ?? []
  const introduction = content.filter((block) => block.type === 'paragraph')
    .slice(0, 2).map((block) => plainText(block.inlineContent)).filter(Boolean)
  const declaration = document.primaryContentSections?.find((section) => section.kind === 'declarations')
    ?.declarations?.[0]?.tokens
  const summary = abstract || introduction[0] || (declaration ? plainText(declaration) : '')
  const description = (summary || `${title} in the Ada API documentation.`).slice(0, 300)
  const fallback = `<main><h1>${escapeHtml(title)}</h1>${abstract ? `<p>${escapeHtml(abstract)}</p>` : ''}${introduction.map((text) => `<p>${escapeHtml(text)}</p>`).join('')}${declaration ? `<pre><code>${escapeHtml(plainText(declaration))}</code></pre>` : ''}</main>`

  return html
    .replace(/<title>[^<]*<\/title>/, `<title>${escapeHtml(pageTitle)}</title>`)
    .replace('</head>', `<meta name="description" content="${escapeHtml(description)}"><link rel="canonical" href="${escapeHtml(url)}"></head>`)
    .replace('<div id="app"></div>', `<div id="app">${fallback}</div>`)
}

async function prepareDoccSearch(outputDirectory) {
  const pages = []
  for await (const htmlPath of htmlPages(outputDirectory)) {
    const route = htmlPath.split(path.sep).slice(0, -1).join('/')
    if (!route.startsWith('documentation/') && !route.startsWith('tutorials/')) continue
    const jsonPath = path.join(outputDirectory, 'data', `${route}.json`)
    if (!existsSync(jsonPath)) throw new Error(`Missing DocC data for ${htmlPath}: ${jsonPath}`)

    const document = JSON.parse(await readFile(jsonPath, 'utf8'))
    const url = `${origin}/${route}/`
    const absoluteHtmlPath = path.join(outputDirectory, htmlPath)
    const html = await readFile(absoluteHtmlPath, 'utf8')
    await writeFile(absoluteHtmlPath, renderPage(html, url, document))
    pages.push(url)
  }

  if (pages.length === 0) throw new Error('No DocC documentation pages with matching JSON data were found')
  pages.sort()
  const sitemapNames = []
  for (let start = 0; start < pages.length; start += sitemapLimit) {
    const name = `sitemap-${sitemapNames.length + 1}.xml`
    sitemapNames.push(name)
    const entries = pages.slice(start, start + sitemapLimit)
      .map((url) => `  <url><loc>${escapeHtml(url)}</loc></url>`).join('\n')
    await writeFile(path.join(outputDirectory, name), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries}\n</urlset>\n`)
  }
  await writeFile(path.join(outputDirectory, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${sitemapNames.map((name) => `  <sitemap><loc>${origin}/${name}</loc></sitemap>`).join('\n')}\n</sitemapindex>\n`)
  await writeFile(path.join(outputDirectory, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${origin}/sitemap.xml\n`)
  return pages.length
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  const directory = process.argv[2]
  if (!directory) {
    console.error('Usage: node scripts/prepare-docc-search.mjs <docc-output-directory>')
    process.exitCode = 2
  } else {
    prepareDoccSearch(path.resolve(directory)).then(
      (count) => console.log(`Prepared ${count} DocC pages for search`),
      (error) => { console.error(error); process.exitCode = 1 },
    )
  }
}

export { prepareDoccSearch, renderPage }
