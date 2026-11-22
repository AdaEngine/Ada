import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

/** Frontend builds consume a verified native snapshot, never a guessed schema. */
export async function nativeAgentContract(root) {
  const filename = path.join(root, "Editor/WebUI/assets/agent-contract.json");
  const regenerate =
    "Rebuild Studio, then run Editor/scripts/export-web-agent-contract.py --studio <AdaEditor>.";
  let value;
  try {
    value = JSON.parse(await readFile(filename, "utf8"));
  } catch (cause) {
    throw new Error(
      `Native agent contract is missing or invalid. ${regenerate}`,
      { cause },
    );
  }
  if (
    value.version !== 1 ||
    value.runtimeAPI !== 4 ||
    !Array.isArray(value.components) ||
    !value.components.length ||
    !value.input?.bindings?.length ||
    !value.api?.types?.length ||
    !value.examples?.length
  )
    throw new Error(`Native agent contract is incomplete. ${regenerate}`);
  const names = value.components.map((component) => component.typeName);
  if (new Set(names).size !== names.length)
    throw new Error("Duplicate native component types in agent contract");
  const hashes = Object.entries(value.sourceHashes || {});
  if (!hashes.length || hashes.length > 5000)
    throw new Error(
      `Native agent contract has no source fingerprint. ${regenerate}`,
    );
  for (const [relative, expected] of hashes) {
    if (
      !/^(Editor|Sources|Tools)\/[A-Za-z0-9_+./-]+$/.test(relative) ||
      relative
        .split("/")
        .some((part) => !part || part === "." || part === "..") ||
      !/^[a-f0-9]{64}$/.test(expected)
    )
      throw new Error("Invalid native contract source fingerprint");
    const bytes = await readFile(path.join(root, relative));
    const source = /\.(ada|md|swift|txt|ui)$/.test(relative)
      ? bytes.toString("utf8").replaceAll("\r\n", "\n")
      : bytes;
    const actual = createHash("sha256").update(source).digest("hex");
    if (actual !== expected)
      throw new Error(
        `Native agent contract is stale: ${relative}. ${regenerate}`,
      );
  }
  const { sourceHashes, ...contract } = value;
  return {
    ...contract,
    fingerprint: createHash("sha256")
      .update(JSON.stringify(sourceHashes))
      .digest("hex"),
  };
}
