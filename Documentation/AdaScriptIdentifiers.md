# AdaScript identifiers

`Identifiers.uuid()` returns a new 36-character lowercase UUID string on each call.
It is a synchronous, stateless host API in interpreted and native AdaScript runtimes.
It does not depend on simulation time or a seeded random generator. Generate an ID
once for an operation that needs stable identity; retain that value when retrying.
UUIDs identify values and are not authentication secrets.
