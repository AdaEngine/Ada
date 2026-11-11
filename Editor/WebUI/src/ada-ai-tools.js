import contract from "../../Sources/AdaEditor/Assets/AdaAIToolContract.json" with { type: "json" };
import { LocalizedError } from "./localization.js";

export const adaAIToolContract = contract.version;

export function groupedTools({ planning, vision }) {
  const families = new Map();
  for (const family of contract.families) {
    const actions = family.actions.filter(
      (action) =>
        action.bindings.web &&
        (!planning || action.plan) &&
        (!action.vision || vision),
    );
    if (actions.length) families.set(family.name, { ...family, actions });
  }
  const definitions = [...families.values()].map((family) => ({
    type: "function",
    function: {
      name: family.name,
      description: family.description,
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: family.actions.map((a) => a.name) },
          arguments: { type: "object" },
        },
        required: ["action", "arguments"],
        additionalProperties: false,
        oneOf: family.actions.map((action) => ({
          description: action.description,
          properties: {
            action: { enum: [action.name] },
            arguments: action.schemas?.web ?? action.schema,
          },
        })),
      },
    },
  }));
  return { families, definitions };
}

export function resolveGroupedCall(families, name, input) {
  const action = families
    .get(name)
    ?.actions.find((a) => a.name === input?.action);
  if (!action) throw new LocalizedError("Unavailable tool: {0}", name);
  if (
    !isObject(input) ||
    Object.keys(input).length !== 2 ||
    !valid(input.arguments, action.schemas?.web ?? action.schema)
  )
    throw new LocalizedError("Invalid tool arguments");
  return {
    name: action.bindings.web,
    args: input.arguments,
    action: action.name,
    key: name + "/" + action.name,
    approval: action.approvals?.web ?? action.approval,
  };
}

export function groupedToolGuidance(families) {
  const aliases = new Map();
  for (const family of families.values())
    for (const action of family.actions) {
      const name = action.bindings.web;
      if (!aliases.has(name)) aliases.set(name, []);
      aliases.get(name).push(family.name + "/" + action.name);
    }
  return (
    "Use the advertised tool family with {action, arguments}. " +
    "In shared skills, files.read and files.list are editor_files/read and editor_files/list. " +
    "For files.write, use editor_files/create for new files or editor_files/patch or replace for existing files. " +
    "These aliases translate older names in workflow instructions. Dot and underscore spellings of the legacy names are equivalent. " +
    [...aliases]
      .map(([name, actions]) => name + "=" + actions.join("|"))
      .join(", ")
  );
}

const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);

// The shared catalog uses this JSON Schema subset. Domain services also
// validate operation-specific data, revisions and limits at dispatch.
function valid(value, schema) {
  if (
    schema.oneOf &&
    schema.oneOf.filter((rule) => valid(value, rule)).length !== 1
  )
    return false;
  if (schema.enum && !schema.enum.includes(value)) return false;
  if (schema.const !== undefined && schema.const !== value) return false;
  const type =
    value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
  const types = [].concat(schema.type ?? []);
  if (
    types.length &&
    !types.includes(type) &&
    !(types.includes("integer") && Number.isSafeInteger(value))
  )
    return false;
  if (isObject(value)) {
    const properties = schema.properties ?? {};
    return (
      (schema.required ?? []).every((key) => Object.hasOwn(value, key)) &&
      Object.entries(value).every(([key, child]) => {
        if (Object.hasOwn(properties, key))
          return valid(child, properties[key]);
        if (isObject(schema.additionalProperties))
          return valid(child, schema.additionalProperties);
        return schema.additionalProperties !== false;
      })
    );
  }
  if (Array.isArray(value))
    return (
      value.length >= (schema.minItems ?? 0) &&
      value.length <= (schema.maxItems ?? Infinity) &&
      (!schema.uniqueItems ||
        new Set(value.map((item) => JSON.stringify(item))).size ===
          value.length) &&
      (!schema.items || value.every((item) => valid(item, schema.items)))
    );
  if (typeof value === "string")
    return (
      value.length >= (schema.minLength ?? 0) &&
      value.length <= (schema.maxLength ?? Infinity) &&
      (!schema.pattern || new RegExp(schema.pattern).test(value))
    );
  return (
    typeof value !== "number" ||
    (Number.isFinite(value) &&
      value >= (schema.minimum ?? -Infinity) &&
      value <= (schema.maximum ?? Infinity) &&
      value > (schema.exclusiveMinimum ?? -Infinity) &&
      value < (schema.exclusiveMaximum ?? Infinity))
  );
}
