import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { parse } from "yaml";
import { nativeAgentContract } from "./native-agent-contract.mjs";
import { webAuthoringDocs } from "./web-authoring-docs.mjs";
import { browserExamples } from "./browser-examples.mjs";
const repositoryRoot = fileURLToPath(new URL("../../..", import.meta.url));
export async function agentResources(output, root = repositoryRoot) {
  const nativeContract = await nativeAgentContract(root);
  const read = (p) => readFile(path.join(root, p), "utf8");
  const skills = [];
  const base = "Editor/Sources/AdaEditor/Assets/AgentSkills";
  for (const entry of await readdir(path.join(root, base), {
    withFileTypes: true,
  })) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
    const dir = entry.name;
    // Shared native workflows keep notes/generator recipes beside Sources.
    // Cloud workspaces deliberately allow supporting text only under Docs.
    // Adapt bundled guidance at export; never rewrite user project workflows.
    const content = (await read(`${base}/${dir}/SKILL.md`))
      .replaceAll("`Design/`", "`Docs/Design/`")
      .replaceAll("`Generators/`", "`Docs/Generators/`");
    const front = parse(content.split("---")[1] || "") || {};
    skills.push({
      id: front.id || front.name || dir,
      name: front.name || dir,
      description: front.description || "",
      content,
    });
  }
  const native = await read(
    "Editor/Sources/AdaEditor/Agent/EditorAgentA2UIModels.swift",
  );
  const match = native.match(
    /static func promptContext\(\)[\s\S]*?return """([\s\S]*?)\n        """/,
  );
  if (!match) throw new Error("Native A2UI contract could not be exported");
  const example = {
    version: "v0.9.1",
    updateComponents: {
      surfaceId: "npc-config",
      components: [
        { id: "root", component: "Column", children: ["name", "submit"] },
        {
          id: "name",
          component: "TextField",
          text: { path: "/npc/name" },
          placeholder: "NPC name",
        },
        {
          id: "submit",
          component: "Button",
          text: "Generate preview",
          action: {
            event: {
              name: "generate_npc_preview",
              context: { name: { path: "/npc/name" } },
            },
          },
        },
      ],
    },
  };
  const contract = match[1]
    .replaceAll("\r\n", "\n")
    .replace(/^        /gm, "")
    .replace(/^Native Studio Image .*\n/m, "")
    .replaceAll(
      "\\(A2UIClient.catalogID)",
      "https://adaengine.org/a2ui/catalogs/forms/v1",
    )
    .replaceAll("\\(componentExample)", JSON.stringify(example));
  if (contract.includes("\\("))
    throw new Error("Unresolved native contract interpolation");
  skills.push({
    id: "ada-chat-ui",
    name: "Interactive chat UI",
    description: "A2UI forms, local scene tools, revisions and submissions.",
    content: contract,
  });
  const docs = JSON.parse(
    await read("Editor/Sources/AdaEditor/Assets/Documentation/catalog.json"),
  );
  const browserDocs = webAuthoringDocs(nativeContract);
  docs.unshift(...browserDocs);
  const examples = browserExamples(nativeContract);
  const browserContract = { ...nativeContract };
  delete browserContract.examples; // Only the adapted complete examples are shipped below.
  const a2uiCatalog = JSON.parse(
    await read("Sources/AdaA2UI/Resources/catalog.json"),
  );
  delete a2uiCatalog.components.Image;
  await mkdir(output, { recursive: true });
  await writeFile(
    path.join(output, "agent-resources.json"),
    JSON.stringify({
      version: 1,
      contract: browserContract,
      skills,
      docs,
      examples,
      a2uiCatalog,
    }),
  );
  await writeFile(
    path.join(output, "recipes.md"),
    browserDocs
      .map(
        (article) =>
          "# " +
          article.title +
          "\n\n" +
          article.blocks
            .map((block) =>
              block.kind === "heading"
                ? "## " + block.text
                : block.kind === "code"
                  ? "```" + (block.language || "") + "\n" + block.text + "\n```"
                  : block.text,
            )
            .join("\n\n"),
      )
      .join("\n\n"),
  );
}
