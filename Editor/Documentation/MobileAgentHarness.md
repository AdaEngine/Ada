# Mobile Studio agent settings

Open **Settings → Agent** to manage the agent on this device.

- **Providers & model** opens the existing Codex/API account and model settings.
- **Skills** lists built-in and imported instructions. Open a skill to read its contents, enable or disable it, or remove an imported skill.
- **Install skill from Files** accepts standalone UTF-8 Markdown files, including `SKILL.md`. The app copies the instructions into its own storage, so the original file is no longer needed. Frontmatter `name` and `description` supply the display metadata. Skill folders, supporting files, executable scripts and remote catalogs are not imported.
- **Instructions** adds persistent user preferences to every turn, including automatic repair turns.
- **Tool rounds** limits runtime tool rounds per attempt (20, 80 or 160).
- **Repair attempts** controls retries after project validation fails (0, 1 or 2). Compilation, scene loading and simulation validation always run.
- **Open Play after success** starts the visible game preview after validation succeeds.

Save the loop settings and instructions with **Save agent settings**. Skill changes save immediately. Settings apply to all projects on this device and are captured at the start of each run. Changes are blocked while a run is in progress.

Settings are stored atomically in Application Support under `AdaEditor/MobileAgent/settings.json`. Credentials continue to use the existing credential stores. Imports allow up to 32 skills, 64 KB per file and 256 KB total skill content; additional instructions allow 16 KB. Invalid imports and failed writes preserve the previous active configuration.

Enabled skill contents are supplied as instructions to the mobile runtime. They do not grant new tools or install external processes. Mobile Studio's required build and input checks remain in place even when optional skills are disabled.
