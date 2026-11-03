# Security Boundaries for Contributors

Never commit credentials, private keys, environment files, or copied production data. Use named
configuration/environment inputs and placeholders. Secret detection is heuristic: review findings,
redact values in reports, and do not weaken the scanner merely to obtain a pass.
Reviewed false positives may be recorded in `.agents/secret-exceptions.json` with an exact file,
detector type, hashed finding fingerprint and a specific public-data reason. Never exempt an entire
file or disable an entropy detector to hide a credential. Exception changes require independent review.

Treat assets, projects, scripts, shader data, network messages, and tool output as untrusted inputs.
Check lengths, integer overflow, traversal, archive paths, resource bounds, decoder errors, and cleanup.
Keep scripting capabilities narrow. Preserve authentication, origin checks, and sandbox boundaries.
Exercise malformed/unauthorized input against the real path when it is material to the change.

Pass subprocess arguments as arrays without a shell. Keep cwd, tool identity, lifetime, timeouts, and
failure codes explicit. Do not print the complete environment or interpolate tokens into command text.
Preserve existing filesystem and Git state; work in task-owned temporary directories for fixtures.

Review dependency source, version/revision changes, checksums, licenses, and applicable advisories.
New dependencies need a concrete reason. Scanner execution is explicit and its supported language/input
formats must be verified; ordinary compilation is not universal SAST and a unit test is not universal DAST.

Local workflow files are attestations. Human approval comes from giving the document to the user
and receiving their actual decision. Independent review comes from a separate context. Hosted merge
blocking requires required-check rules on the Git server, not just a generated local report.
