# ADR-0032. Local MCP Tool Execution for Hosted Ada AI

- Status **Accepted**
- Date **2026-11-23**
- Scope Desktop Ada Studio and Ada Cloud's hosted tool contract

## Context

Studio can expose its own MCP server to an external ACP agent. Hosted Ada AI uses a separate versioned catalog validated by Ada Cloud and executes the catalog's tools in Studio. A user-configured MCP server can supply arbitrary tool names and schemas, start a process using local credentials, and return data that influences subsequent tool calls.

## Decision

Desktop Studio manages MCP connections, discovery, user selection, argument validation, call approval and execution on the user's device. Only user-owned Studio settings can authorize local launch. Talk to the hosted model through one fixed, versioned external-tool family. Return approved tools and bounded schemas as data through that family. Keep Cloud validation at the envelope and mode boundary. Studio validates dynamic tool schemas and checks local authorization at dispatch.

Use the same connector for a bounded first-party workflow such as Blender and for tools the user explicitly selects on other local servers. Tool selection governs the assistant's access. The OS account governs the executable's privileges. Existing hosted client contracts remain available during rollout.

## Consequences

New local tools can be authorized without adding static Cloud catalog entries for each server. Cloud needs a coordinated contract rollout for the envelope. Studio owns compatibility, permissions, and process lifecycle, and the model learns a tool's schema through discovery before calling it. The first release limits compatibility to local stdio tool servers and bounded text or structured data. See [the feature design](../Designs/ada-ai-external-mcp.md).
