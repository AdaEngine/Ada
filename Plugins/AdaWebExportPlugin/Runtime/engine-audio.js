// PCM output for AdaAudio's device-less miniaudio engine. This is shared by all
// exported products; decoding/mixing and sound controls stay in AdaAudio.
let context;
let nextID = 1;
const engines = new Map();
const sampleRate = 48000;
const channels = 2;
const targetFrames = 4096;
function audioContext() {
  const Constructor = globalThis.AudioContext ?? globalThis.webkitAudioContext;
  if (!Constructor) throw new Error('Web Audio is unavailable in this browser');
  context ??= new Constructor();
  return context;
}
function activate() {
  if (!context || ![...engines.values()].some(engine => engine.started)) return;
  context.resume().catch(error => console.error('[AdaAudio.Web]', error));
}
function stop(engine) {
  engine.started = false;
  for (const source of engine.sources) {
    source.onended = null;
    try { source.stop(); } catch { /* source may have finished before this event */ }
    source.disconnect();
  }
  engine.sources.clear(); engine.nextTime = 0;
}
document.addEventListener('pointerdown', activate, { capture: true });
document.addEventListener('keydown', activate, { capture: true });
globalThis.__adaEngineAudio = {
  create() {
    const ctx = audioContext();
    const gain = ctx.createGain(); gain.connect(ctx.destination);
    const id = nextID++;
    engines.set(id, { gain, started: false, nextTime: 0, sources: new Set() });
    return id;
  },
  start(id) { const engine = engines.get(id); if (engine) engine.started = true; },
  stop(id) { const engine = engines.get(id); if (engine) stop(engine); },
  destroy(id) { const engine = engines.get(id); if (engine) { stop(engine); engine.gain.disconnect(); engines.delete(id); } },
  neededFrames(id) {
    const engine = engines.get(id);
    if (!engine?.started || context?.state !== 'running') return 0;
    const queued = Math.max(0, Math.ceil((engine.nextTime - context.currentTime) * sampleRate));
    return Math.max(0, targetFrames - queued);
  },
  submit(id, samples) {
    const engine = engines.get(id);
    if (!engine?.started || context?.state !== 'running') return;
    const frames = samples.length / channels;
    if (!Number.isInteger(frames) || frames < 1 || frames > targetFrames) throw new Error('Invalid PCM block');
    const buffer = context.createBuffer(channels, frames, sampleRate);
    for (let channel = 0; channel < channels; channel++) {
      const output = buffer.getChannelData(channel);
      for (let frame = 0; frame < frames; frame++) output[frame] = samples[frame * channels + channel];
    }
    const source = context.createBufferSource(); source.buffer = buffer;
    source.connect(engine.gain); engine.sources.add(source);
    source.onended = () => { source.disconnect(); engine.sources.delete(source); };
    const when = Math.max(context.currentTime + 0.01, engine.nextTime);
    source.start(when); engine.nextTime = when + frames / sampleRate;
  }
};
addEventListener('pagehide', () => {
  for (const engine of engines.values()) { stop(engine); engine.gain.disconnect(); }
  engines.clear(); context?.close(); context = undefined;
});
