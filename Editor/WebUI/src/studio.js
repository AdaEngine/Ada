import { attachFiles, removeAttachment } from "./attachments.js";
import { t, LocalizedError } from "./localization.js";
import { refreshAICredits } from "./ai-credits.js";
import { setBillingMode, developmentAssistant } from "./provider-settings.js";
import { runAgent, runTool } from "./agent.js";
import { sceneRevision } from "./scene-tools.js";
import { boundedRuntimeLines } from "./runtime-output.js";
import {
  chatState,
  editChat,
  newSession,
  switchSession,
  identity,
} from "./chat.js";
import {
  receiveUI,
  finishUI,
  editSurface,
  submitSurface,
  undoSurface,
  exportSurface,
} from "./chat-ui-controller.js";
import { writeTools } from "./agent-tools.js";
import {
  toggleAnnotations,
  cancelAnnotation,
  annotateEntity,
  annotateUI,
  annotatePreview,
  addAnnotation,
  removeAnnotation,
  editAnnotation,
} from "./annotations.js";
import { json, recovery, Preview, base64, download } from "./platform.js";
import {
  Document,
  clone,
  file,
  metadata,
  scene,
  scenePath,
  template,
  portable,
  exportZIP,
  importZIP,
  transform,
} from "./documents.js";
export class Studio {
  version = 0;
  listeners = new Set();
  account = null;
  config = {};
  projects = [];
  workspace = null;
  document = null;
  view = "editor";
  projectBrowser = false;
  libraryView = "games";
  libraryTarget = "projects";
  leaveIssue = "";
  get leavePrompt() {
    return this.leaveIssue?.message ?? String(this.leaveIssue ?? "");
  }
  set leavePrompt(value) {
    this.leaveIssue = value;
  }
  leaving = false;
  panel = "objects";
  selected = null;
  inspector = true;
  assistant = true;
  assetPanel = false;
  status = "loading";
  errorValue = "";
  get error() {
    return this.errorValue?.message ?? String(this.errorValue ?? "");
  }
  set error(value) {
    this.errorValue = value;
  }
  homePrompt = "";
  homeAttachments = [];
  attachmentBusy = false;
  creation = { dimension: 3, players: "single" };
  prompt = "";
  streamText = "";
  running = false;
  runningSessionID = null;
  permissionRequest = null;
  allowedTools = new Set();
  runtime = "idle";
  playing = false;
  viewportIssue = "";
  get viewportError() {
    return this.viewportIssue?.message ?? String(this.viewportIssue ?? "");
  }
  set viewportError(value) {
    this.viewportIssue = value;
  }
  activity = [];
  aiBalance = null;
  aiCatalog = null;
  aiPhase = "loading";
  aiRefreshEpoch = 0;
  development = null;
  providers = [];
  providerID = "";
  modelID = "";
  billingMode = "ada";
  apiKey = "";
  settings = false;
  history = false;
  checkpoints = [];
  activeFile = "Sources/Game.ada";
  savePromise = null;
  savedGeneration = 0;
  timer = null;
  recoveryQueue = Promise.resolve();
  agent = null;
  checkpointPending = false;
  latestCodeSelection = "";
  tool = "move";
  localAxes = false;
  snapTransforms = false;
  renderedGeneration = -1;
  viewportExpanded = false;
  annotationMode = false;
  annotationDraft = null;
  annotationEpoch = 0;
  composerFocus = 0;
  constructor() {
    this.preview = new Preview((state) => {
      this.runtime = state;
      this.emit();
    });
    this.preview.onEditorEvent = (type, value) =>
      this.action(() => this.editorEvent(type, value));
    this.preview.onDiagnostics = (diagnostics) => {
      diagnostics = boundedRuntimeLines(diagnostics);
      const owner = this.previewDiagnosticOwner;
      if (
        !owner ||
        owner.document !== this.document ||
        owner.generation !== this.document.contentGeneration ||
        !diagnostics.length
      )
        return;
      this.runtimeValidation = {
        ...this.runtimeValidation,
        valid: false,
        generation: owner.generation,
        diagnostics: diagnostics.map((message) => ({
          code: "runtime.script",
          message,
          repairTool: "editor_api_describe",
        })),
      };
      this.viewportError = diagnostics.join("\n");
      this.updateChat((chat) => {
        chat.events.push({
          id: crypto.randomUUID(),
          sessionID: owner.sessionID,
          type: "runtime-error",
          generation: owner.generation,
          message: diagnostics.join("\n").slice(0, 4000),
        });
        chat.events = chat.events.slice(-100);
      });
      this.emit();
    };
    window.addEventListener("online", () => {
      if (this.document) this.save().catch((e) => this.fail(e));
    });
    window.addEventListener("pagehide", () => {
      this.agent?.abort();
      this.preview.stop();
    });
    window.addEventListener("beforeunload", (e) => {
      if (
        this.running ||
        this.attachmentBusy ||
        this.homeAttachments.length > 0 ||
        !!this.homePrompt.trim() ||
        !!this.annotationDraft?.note.trim() ||
        (this.document && this.document.generation !== this.savedGeneration)
      ) {
        e.preventDefault();
        e.returnValue = "";
      }
    });
    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && this.viewportExpanded) {
        this.viewportExpanded = false;
        this.emit();
      }
      if (
        this.document &&
        !this.projectBrowser &&
        (e.metaKey || e.ctrlKey) &&
        e.key.toLowerCase() === "z" &&
        !document.activeElement?.closest(
          "input, textarea, [contenteditable=true]",
        )
      ) {
        e.preventDefault();
        e.shiftKey ? this.redo() : this.undo();
      }
    });
    window.addEventListener("keydown", (e) => {
      if (
        this.document &&
        !this.projectBrowser &&
        this.view === "editor" &&
        !this.playing &&
        !e.target.closest?.("input, textarea, [contenteditable=true]") &&
        !e.ctrlKey &&
        !e.metaKey &&
        !e.altKey
      ) {
        const tool = { w: "move", e: "rotate", r: "scale", q: "hand" }[
          e.key.toLowerCase()
        ];
        if (tool) {
          e.preventDefault();
          this.tool = tool;
          this.emit();
          this.editorCommand();
        }
        if (e.key.toLowerCase() === "f") {
          e.preventDefault();
          this.editorCommand({ action: "focus" });
        }
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        this.save().catch((error) => this.fail(error));
      }
    });
  }
  subscribe = (fn) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };
  getVersion = () => this.version;
  emit() {
    this.version++;
    for (const fn of this.listeners) fn();
  }
  fail(error) {
    if (error?.name === "AbortError") return;
    this.error = error;
    this.emit();
  }
  async action(fn) {
    try {
      return await fn();
    } catch (e) {
      this.fail(e);
    }
  }
  get snapshot() {
    return this.document?.snapshot;
  }
  get chat() {
    return chatState(this.snapshot);
  }
  get session() {
    return (
      this.chat.sessions.find((s) => s.id === this.chat.activeSessionID) ||
      this.chat.sessions[0]
    );
  }
  updateChat(update) {
    editChat(this, update);
  }
  toggleAnnotations() {
    toggleAnnotations(this);
  }
  editAnnotation(...args) {
    return editAnnotation(this, ...args);
  }
  cancelAnnotation() {
    cancelAnnotation(this);
  }
  annotateEntity(...args) {
    return annotateEntity(this, ...args);
  }
  annotateUI(...args) {
    return annotateUI(this, ...args);
  }
  annotatePreview(...args) {
    return annotatePreview(this, ...args);
  }
  addAnnotation() {
    return addAnnotation(this);
  }
  removeAnnotation(id) {
    removeAnnotation(this, id);
  }
  newSession() {
    newSession(this);
  }
  switchSession(id) {
    switchSession(this, id);
  }
  receiveUI(text, messageID, sessionID, final = false) {
    return receiveUI(this, text, messageID, sessionID, final);
  }
  finishUI(sessionID, status) {
    finishUI(this, sessionID, status);
  }
  editSurface(...args) {
    return editSurface(this, ...args);
  }
  async submitSurface(...args) {
    try {
      return await submitSurface(this, ...args);
    } catch (e) {
      this.updateChat((c) => {
        const card = c.surfaces.find((r) => r.generation === args[1]);
        if (card) card.error = e.message;
      });
      throw e;
    }
  }
  undoSurface(...args) {
    return undoSurface(this, ...args);
  }
  exportSurface(...args) {
    return exportSurface(this, ...args);
  }
  restoreSurface(id, generation) {
    const card = this.chat.surfaces.find(
      (r) =>
        r.id === id &&
        r.generation === generation &&
        r.sessionID === this.session.id &&
        r.owner === identity(this),
    );
    if (
      this.running ||
      !card?.components.root ||
      !["failed", "cancelled"].includes(card.status)
    )
      throw new LocalizedError("This card is unavailable");
    this.updateChat((c) => {
      const r = c.surfaces.find((r) => r.generation === generation);
      r.status = "ready";
      r.error = "";
    });
  }
  requestTool(name, args, signal, action) {
    const session =
      this.chat.sessions.find((s) => s.id === this.runningSessionID) ||
      this.session;
    if (!(action?.approval ?? writeTools.has(name))) return Promise.resolve();
    const grant = action
      ? JSON.stringify([this.workspace?.id, session.id, action.key])
      : session.id + ":" + name;
    if (session.mode === "plan")
      return Promise.reject(
        new LocalizedError("Discuss mode does not allow project changes"),
      );
    if (session.permission !== "ask" || this.allowedTools.has(grant))
      return Promise.resolve();
    return new Promise((resolve, reject) => {
      const done = (choice) => {
        signal.removeEventListener("abort", cancel);
        this.permissionRequest = null;
        if (choice === "session") this.allowedTools.add(grant);
        this.emit();
        choice
          ? resolve()
          : reject(new LocalizedError("The user declined the tool"));
      };
      const cancel = () => done(false);
      this.permissionRequest = {
        name,
        args,
        sessionID: session.id,
        decide: done,
      };
      signal.addEventListener("abort", cancel, { once: true });
      if (signal.aborted) cancel();
      else this.emit();
    });
  }
  get scene() {
    try {
      return this.snapshot ? scene(this.snapshot) : null;
    } catch {
      return null;
    }
  }
  get entity() {
    return this.scene?.entities.find((e) => e.id === this.selected);
  }
  get models() {
    return this.providers.find((p) => p.id === this.providerID)?.models ?? [];
  }
  get model() {
    return this.models.find((m) => m.id === this.modelID);
  }
  get sources() {
    return (
      this.snapshot?.files
        .filter((f) => f.path.startsWith("Sources/"))
        .sort((a, b) => a.path.localeCompare(b.path)) ?? []
    );
  }
  get codeFiles() {
    return (
      this.snapshot?.files
        .filter((f) => /\.(ada|md|txt|ui|json|ascn)$/.test(f.path))
        .sort((a, b) => a.path.localeCompare(b.path)) || []
    );
  }
  refreshAI() {
    return refreshAICredits(this);
  }
  async start() {
    try {
      this.development = await developmentAssistant();
      this.providers = this.development?.providers || [];
      if (this.providers.length) setBillingMode(this, "codex");
      this.account = await json("/v1/me");
      this.config = await json("/v1/ai/studio-config");
      if (!this.config.enabled) {
        this.status = "offline";
        this.projects = [];
        this.emit();
        return;
      }
      this.providers = await json("/v1/ai/providers");
      this.providerID = this.providers[0]?.id ?? "";
      this.modelID = this.models.find((m) => m.tools)?.id ?? "";
      setBillingMode(
        this,
        this.providers[0]?.transport === "codex"
          ? "codex"
          : this.providers.some((p) => p.hosted)
            ? "ada"
            : "byok",
      );
      await this.refreshAI();
      this.projects = await json("/v1/workspaces");
      this.status = "saved";
      this.emit();
      // Start in Playground; opening a project is an explicit action.
    } catch (e) {
      this.status = e.status === 401 ? "signedout" : "offline";
      if (e.status === 401) {
        this.account = null;
        this.emit();
      } else this.fail(e);
    }
  }
  async refresh() {
    this.projects = await json("/v1/workspaces");
    this.emit();
  }
  async create(dimension = 3) {
    if (this.running)
      throw new LocalizedError("Stop the assistant before switching projects");
    await this.save();
    await this.createSnapshot(template(dimension));
  }
  async createSnapshot(snapshot) {
    const clean = portable(snapshot),
      record = await json("/v1/workspaces", {
        operationID: crypto.randomUUID(),
        snapshot: clean,
      });
    this.install(record, clean);
    await this.refresh();
  }
  install(record, snapshot) {
    this.cancelAnnotation();
    this.preview.stop();
    this.workspace = record;
    this.document = new Document(snapshot);
    this.allowedTools.clear();
    this.prompt = this.session.draft || "";
    if (
      this.chat.surfaces.some((s) =>
        ["receiving", "submitting"].includes(s.status),
      )
    ) {
      this.document.chat((c) => {
        for (const surface of c.surfaces)
          if (["receiving", "submitting"].includes(surface.status))
            surface.status = "cancelled";
      });
    }
    this.selected = null;
    this.latestCodeSelection = "";
    this.activity = [];
    this.savedGeneration = 0;
    this.view = "editor";
    this.projectBrowser = false;
    this.leavePrompt = "";
    this.assetPanel = false;
    this.viewportExpanded = false;
    this.playing = false;
    this.viewportError = "";
    this.activeFile = this.sources[0]?.path ?? "Sources/Game.ada";
    this.status = "saved";
    this.history = false;
    this.error = "";
    this.checkpointPending = false;
    localStorage.setItem(`studio:last:${this.account.id}`, record.id);
    this.router?.opened(record.id);
    this.emit();
    if (this.document.generation) this.changed();
  }
  async open(record) {
    if (record.id === this.workspace?.id) {
      this.projectBrowser = false;
      this.router?.opened(record.id);
      this.emit();
      return;
    }
    if (this.running)
      throw new LocalizedError("Stop the assistant before switching projects");
    await this.save();
    const value = await json(`/v1/workspaces/${record.id}`);
    if (!value.snapshot)
      throw new LocalizedError("The project snapshot is unavailable");
    this.install(value, value.snapshot);
    const draft = await recovery("load", this.account.id, record.id);
    if (
      draft &&
      JSON.stringify(draft.snapshot) !== JSON.stringify(value.snapshot)
    ) {
      if (draft.revision === value.revision) {
        this.document.edit((s) => Object.assign(s, draft.snapshot));
        this.changed();
      } else {
        await this.createSnapshot({
          ...draft.snapshot,
          title: t("{0} — recovered", draft.snapshot.title),
        });
        this.error = new LocalizedError(
          "Unsaved changes were recovered as a separate project",
        );
        this.emit();
      }
    }
  }
  home() {
    this.navigate("overview");
  }
  navigate(view) {
    if (!this.document) return;
    this.projectBrowser = false;
    this.view = view;
    if (view === "editor") this.playing = false;
    this.assetPanel = false;
    this.viewportExpanded = false;
    this.router?.opened(this.workspace.id);
    this.emit();
  }
  browseLibrary(view) {
    if (this.router)
      return this.router.navigate(
        {
          games: "/games",
          create: "/create",
          projects: "/projects",
          account: "/account",
          publications: "/publications",
        }[view],
      );
    return this.browseProjects(false, view);
  }
  async browseProjects(local = false, view) {
    if (this.leaving) return;
    if (this.running)
      throw new LocalizedError(
        "Stop the assistant before returning to projects",
      );
    const destination =
      view || (this.leavePrompt ? this.libraryTarget : "projects");
    if (
      ![
        "games",
        "create",
        "projects",
        "account",
        "publications",
        "legal",
      ].includes(destination)
    )
      return;
    this.libraryTarget = destination;
    this.leaving = true;
    this.emit();
    try {
      if (local && this.document) {
        // Confirm the durable write, including any queued edits, before leaving.
        await this.recoveryQueue;
        await recovery("save", this.account.id, this.workspace.id, {
          revision: this.workspace.revision,
          snapshot: portable(this.snapshot),
        });
      } else {
        await this.save();
      }
      this.projectBrowser = true;
      this.libraryView = destination;
      this.router?.browsed(destination);
      this.cancelAnnotation();
      this.leavePrompt = "";
      this.history = false;
      // Retain the document, undo, selection and Player for the Continue action.
      if (destination === "projects" && this.account)
        await this.refresh().catch((e) => this.fail(e));
      return true;
    } catch (e) {
      this.leavePrompt = e;
      return false;
    } finally {
      this.leaving = false;
      this.emit();
    }
  }
  changed(checkpoint = false) {
    this.checkpointPending ||= checkpoint;
    if (!this.document) return;
    this.status = "saving";
    const record = this.workspace,
      snapshot = clone(this.snapshot),
      account = this.account.id;
    this.recoveryQueue = this.recoveryQueue
      .then(() =>
        recovery("save", account, record.id, {
          revision: record.revision,
          snapshot,
        }),
      )
      .catch((e) => this.fail(e));
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.save().catch((e) => this.fail(e)), 900);
    this.emit();
  }
  async save(checkpoint = false) {
    this.checkpointPending ||= checkpoint;
    clearTimeout(this.timer);
    if (this.savePromise) {
      await this.savePromise;
      return this.save();
    }
    const doc = this.document,
      record = this.workspace;
    if (
      !doc ||
      !record ||
      (doc.generation === this.savedGeneration && !this.checkpointPending)
    )
      return;
    const snapshot = portable(doc.snapshot),
      generation = doc.generation,
      keeps = this.checkpointPending;
    this.checkpointPending = false;
    const save = async () => {
      try {
        const result = await json(
          `/v1/workspaces/${record.id}`,
          {
            operationID: crypto.randomUUID(),
            expectedRevision: record.revision,
            snapshot,
            checkpoint: keeps,
          },
          "PUT",
        );
        if (this.document !== doc) return;
        this.workspace = { ...result };
        this.savedGeneration = generation;
        if (doc.generation === generation) {
          await this.recoveryQueue;
          if (doc.generation === generation)
            await recovery("remove", this.account.id, record.id);
        }
        this.status = doc.generation === generation ? "saved" : "saving";
      } catch (e) {
        if (this.document !== doc) return;
        if (e.status === 409) {
          this.agent?.abort();
          await this.createSnapshot({
            ...clone(doc.snapshot),
            title: t("{0} — copy", doc.snapshot.title),
          });
          this.error = new LocalizedError(
            "The project changed in another tab. Your edits were saved as a separate copy.",
          );
        } else {
          this.status = e.status === 401 ? "signedout" : "offline";
          this.checkpointPending ||= keeps;
          throw e;
        }
      } finally {
        this.emit();
      }
    };
    this.savePromise = save();
    try {
      await this.savePromise;
    } finally {
      this.savePromise = null;
    }
    if (
      this.document === doc &&
      (doc.generation !== this.savedGeneration || this.checkpointPending)
    )
      return this.save();
  }
  editScene(update) {
    this.document.scene(update);
    this.changed();
  }
  select(id) {
    this.selected = id;
    this.inspector = true;
    this.emit();
    this.editorCommand();
  }
  editorCommand(options = {}) {
    if (!this.preview.ready || this.playing) return;
    return this.preview
      .message("editor", {
        selected: this.selected,
        tool: this.tool,
        local: this.localAxes,
        snap: this.snapTransforms,
        ...options,
      })
      .catch((error) => this.fail(error));
  }
  editorEvent(type, value) {
    if (this.playing || !this.document || this.view !== "editor") return;
    if (type === "select") {
      this.selected = this.scene.entities.some((e) => e.id === value.id)
        ? value.id
        : null;
      this.inspector = true;
      this.emit();
    }
    if (
      type === "tool" &&
      ["move", "rotate", "scale", "hand"].includes(value.tool)
    ) {
      this.tool = value.tool;
      this.emit();
    }
    if (type === "error") throw new Error(value.message);
    if (type === "transform") {
      // A tool drag may span an agent/manual revision. Never overwrite that edit.
      if (
        this.renderedGeneration !== this.document.contentGeneration ||
        this.running
      ) {
        this.preview.key = "";
        return this.syncViewport();
      }
      const transformValue = value.transform;
      if (
        ![
          transformValue?.position,
          transformValue?.rotation,
          transformValue?.scale,
        ].every(
          (v, i) =>
            Array.isArray(v) &&
            v.length === [3, 4, 3][i] &&
            v.every(
              (n) =>
                typeof n === "number" &&
                Number.isFinite(n) &&
                Math.abs(n) < 1_000_000,
            ),
        )
      )
        throw new LocalizedError("Invalid transform");
      this.editScene((scene) => {
        const entity = scene.entities.find((e) => e.id === value.id);
        if (entity)
          entity.components["AdaTransform.Transform"] = {
            ...entity.components["AdaTransform.Transform"],
            ...clone(transformValue),
          };
      });
    }
    if (type === "shortcut") {
      if (value.key === "escape") {
        this.viewportExpanded = false;
        this.emit();
      }
      if (value.key === "z") value.shift ? this.redo() : this.undo();
      if (value.key === "s") return this.save();
      if (!this.running && this.selected && value.key === "delete")
        this.removeEntity();
      if (!this.running && this.selected && value.key === "d")
        this.duplicateEntity();
    }
  }
  duplicateEntity() {
    if (!this.selected) return;
    const selected = this.selected,
      ids = new Map([[selected, crypto.randomUUID()]]);
    this.editScene((scene) => {
      for (;;) {
        const count = ids.size;
        for (const e of scene.entities)
          if (ids.has(e.parent) && !ids.has(e.id))
            ids.set(e.id, crypto.randomUUID());
        if (count === ids.size) break;
      }
      scene.entities.push(
        ...scene.entities
          .filter((e) => ids.has(e.id))
          .map((e) => ({
            ...clone(e),
            id: ids.get(e.id),
            parent: ids.get(e.parent) ?? e.parent,
            name: e.id === selected ? t("{0} — copy", e.name) : e.name,
          })),
      );
    });
    this.select(ids.get(selected));
  }
  setField(component, field, value) {
    this.editScene((s) => {
      const entity = s.entities.find((e) => e.id === this.selected);
      if (entity) entity.components[component][field] = value;
    });
  }
  addEntity() {
    const id = crypto.randomUUID();
    const visual =
      metadata(this.snapshot).runtime.plugins.preset === "game2d"
        ? {
            "AdaSprite.Sprite": {
              tintColor: { red: 0.52, green: 0.47, blue: 0.98, alpha: 1 },
              size: { width: 80, height: 80 },
            },
          }
        : {
            "AdaScene.Mesh3DComponent": {
              mesh: "Cube",
              size: 1,
              color: { red: 0.52, green: 0.47, blue: 0.98, alpha: 1 },
              roughness: 0.65,
              metallic: 0,
            },
          };
    this.editScene((s) =>
      s.entities.push({
        id,
        name: t("New object"),
        enabled: true,
        parent: null,
        components: {
          "AdaTransform.Transform": transform(),
          ...visual,
        },
      }),
    );
    this.select(id);
  }
  removeEntity() {
    const removed = new Set([this.selected]);
    this.editScene((s) => {
      for (;;) {
        const before = removed.size;
        for (const e of s.entities)
          if (removed.has(e.parent)) removed.add(e.id);
        if (before === removed.size) break;
      }
      s.entities = s.entities.filter((e) => !removed.has(e.id));
    });
    this.selected = null;
    this.emit();
  }
  undo() {
    this.document?.undo();
    if (!this.entity) this.selected = null;
    this.changed();
  }
  redo() {
    this.document?.redo();
    if (!this.entity) this.selected = null;
    this.changed();
  }
  writeCode(text) {
    this.document.write(this.activeFile, text);
    this.changed();
  }
  rename(title) {
    if (!title.trim() || title === this.snapshot.title) return;
    this.document.edit((s) => {
      s.title = title.trim();
      const meta = metadata(s);
      meta.project.displayName = s.title;
      file(s, ".ada/project.json").data = base64(
        new TextEncoder().encode(JSON.stringify(meta, null, 2)),
      );
    });
    this.changed();
  }
  async uploadAsset(input) {
    const document = this.document;
    const path =
        "Assets/Imports/" +
        crypto.randomUUID() +
        "_" +
        input.name.replace(/[^a-zA-Z0-9_.-]/g, "_"),
      data = base64(new Uint8Array(await input.arrayBuffer()));
    if (this.document !== document)
      throw new LocalizedError("A different project is open");
    document.edit((s) => s.files.push({ path, data }));
    this.changed();
    return path;
  }
  attachFiles(inputs, home = false) {
    return attachFiles(this, inputs, { home });
  }
  async attachFile(input) {
    return (await this.attachFiles([input]))[0];
  }
  removeAttachment(id, home = !this.document) {
    removeAttachment(this, id, home);
  }
  async importFile(input) {
    if (this.running)
      throw new LocalizedError("Stop the assistant before switching projects");
    await this.save();
    await this.createSnapshot(importZIP(await input.arrayBuffer()));
  }
  export() {
    download(this.snapshot.title + ".zip", exportZIP(this.snapshot));
  }
  async showHistory() {
    await this.save();
    this.checkpoints = await json(
      `/v1/workspaces/${this.workspace.id}/history`,
    );
    this.history = true;
    this.emit();
  }
  async checkpoint() {
    await this.save(true);
    await this.showHistory();
  }
  async restore(revision) {
    if (this.running)
      throw new LocalizedError("Stop the assistant before restoring a version");
    await this.save();
    const id = this.workspace.id;
    await json(`/v1/workspaces/${id}/restore`, {
      operationID: crypto.randomUUID(),
      expectedRevision: this.workspace.revision,
      revision,
    });
    await this.recoveryQueue;
    await recovery("remove", this.account.id, id);
    const restored = await json(`/v1/workspaces/${id}`);
    this.install(restored, restored.snapshot);
  }
  async play(editMode = false) {
    if (!this.snapshot) return;
    this.playing = !editMode;
    this.navigate(editMode ? "editor" : "preview");
    return this.syncViewport(editMode);
  }
  async syncViewport(editMode = !this.playing) {
    if (!this.snapshot) return;
    const document = this.document;
    const generation = document.contentGeneration;
    const snapshot = portable(this.snapshot);
    snapshot.messages = [];
    const revision = await sceneRevision(snapshot);
    const current = () =>
      this.document === document && document.contentGeneration === generation;
    try {
      // Creating a project from the home composer mounts Workspace asynchronously.
      if (!this.preview.host) await new Promise(requestAnimationFrame);
      await this.preview.load(snapshot, this.config, editMode);
      if (current()) {
        this.viewportError = "";
        this.renderedGeneration = generation;
        this.runtimeValidation = {
          valid: true,
          generation,
          sceneRevision: revision,
          editMode,
          rendered: true,
          diagnostics: [],
        };
        this.previewDiagnosticOwner = {
          document,
          generation,
          sessionID: this.runningSessionID || this.session.id,
        };
        if (editMode) await this.editorCommand();
      }
    } catch (e) {
      if (e.name !== "AbortError" && current()) {
        this.runtime = "error";
        this.viewportError = e;
        this.runtimeValidation = {
          valid: false,
          generation,
          sceneRevision: revision,
          editMode,
          rendered: false,
          diagnostics: [
            {
              code: "runtime.load",
              file:
                e.message.match(/Sources\/[A-Za-z0-9_./-]+\.ada/)?.[0] ||
                scenePath(snapshot),
              message: boundedRuntimeLines([e.message])[0],
              repairHint:
                "Inspect the named source or component and use editor_project_apply/editor_scene_apply to repair it. Read schemas before changing encodings.",
            },
          ],
        };
        this.emit();
      }
      throw e;
    }
  }
  async stop() {
    this.playing = false;
    this.navigate("editor");
    return this.syncViewport(true);
  }
  async retryViewport() {
    this.preview.stop();
    this.viewportError = "";
    return this.syncViewport();
  }
  stopAgent() {
    this.agent?.abort();
  }
  append(value) {
    this.document.append(value);
    this.changed();
  }
  send(text, options) {
    return runAgent(this, text, options);
  }
  runTool(name, args) {
    return runTool(this, name, args);
  }
}
