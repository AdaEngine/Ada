#!/usr/bin/env node

import { copyFile, mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const markerStart = "<!-- adaengine-docc-theme:start -->";
const markerEnd = "<!-- adaengine-docc-theme:end -->";
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const sourceDirectory = path.join(repositoryRoot, "Documentation", "DocCTheme");

async function htmlFiles(inDirectory) {
  const entries = await readdir(inDirectory, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const entryPath = path.join(inDirectory, entry.name);
    if (entry.isDirectory()) {
      files.push(...await htmlFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".html")) {
      files.push(entryPath);
    }
  }

  return files;
}

function assetPrefix(inHTML) {
  const stylesheet = inHTML.match(/<link\b[^>]*href=["']([^"']*\/css\/index\.[^"']+\.css)["'][^>]*>/i)?.[1];
  if (stylesheet) {
    return stylesheet.slice(0, stylesheet.lastIndexOf("css/"));
  }

  const baseURL = inHTML.match(/\bbaseUrl\s*=\s*["']([^"']*)["']/)?.[1] || "/";
  return baseURL.endsWith("/") ? baseURL : `${baseURL}/`;
}

function injectTheme(inHTML) {
  const withoutExistingTheme = inHTML.replace(new RegExp(`${markerStart}[\\s\\S]*?${markerEnd}`, "g"), "");
  if (!withoutExistingTheme.includes("</head>")) {
    throw new Error("DocC HTML does not contain a closing head element.");
  }

  const prefix = assetPrefix(withoutExistingTheme);
  const tags = [
    markerStart,
    `<link href="${prefix}css/adaengine-theme.css" rel="stylesheet" data-adaengine-docc-theme>`,
    `<script defer src="${prefix}js/adaengine-docc-theme.js" data-adaengine-docc-theme></script>`,
    markerEnd
  ].join("");
  return withoutExistingTheme.replace("</head>", `${tags}</head>`);
}

async function applyTheme(outputDirectory) {
  const outputStats = await stat(outputDirectory).catch(() => undefined);
  if (!outputStats?.isDirectory()) {
    throw new Error(`DocC output directory does not exist: ${outputDirectory}`);
  }

  const outputHTMLFiles = await htmlFiles(outputDirectory);
  if (outputHTMLFiles.length === 0) {
    throw new Error(`No DocC HTML files found in: ${outputDirectory}`);
  }

  await mkdir(path.join(outputDirectory, "css"), { recursive: true });
  await mkdir(path.join(outputDirectory, "js"), { recursive: true });
  await copyFile(path.join(sourceDirectory, "theme.css"), path.join(outputDirectory, "css", "adaengine-theme.css"));
  await copyFile(path.join(sourceDirectory, "theme.js"), path.join(outputDirectory, "js", "adaengine-docc-theme.js"));

  for (const htmlFile of outputHTMLFiles) {
    const source = await readFile(htmlFile, "utf8");
    await writeFile(htmlFile, injectTheme(source));
  }

  return outputHTMLFiles.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const outputArgument = process.argv[2];
  if (!outputArgument) {
    console.error("Usage: node scripts/apply-docc-theme.mjs <docc-output-directory>");
    process.exitCode = 2;
  } else {
    const outputDirectory = path.resolve(process.cwd(), outputArgument);
    try {
      const htmlCount = await applyTheme(outputDirectory);
      console.log(`Applied AdaEngine DocC theme to ${htmlCount} HTML files in ${outputDirectory}`);
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    }
  }
}

export { applyTheme, assetPrefix, injectTheme };
