// Web Player audio adapter. Decode only when requested; short looping tracks are
// cached in browser audio memory, never copied into WASI's preopened filesystem.
let context;
const buffers = new Map();
const active = new Map();
const pending = new Set();
let manifest;
function audioContext() {
  context ??= new AudioContext();
  return context;
}
function activate() {
  // Resume directly in a trusted pointer/key handler, before the AdaScript task runs.
  audioContext().resume().catch(report);
}
function report(error) {
  console.error('[AdaWebPlayer.Audio]', error);
  document.dispatchEvent(new CustomEvent('ada-player-audio-error', {detail: String(error)}));
}
document.addEventListener('pointerdown', activate, {capture:true});
document.addEventListener('keydown', activate, {capture:true});
globalThis.__adaPlayerAudio = {
  toggle: async (id) => {
    if (pending.has(id)) return 'Loading music…';
    const playing = active.get(id);
    if (playing) {
      playing.stop(); active.delete(id);
      console.log(`[AdaWebPlayer.Audio] stopped ${id}`);
      return 'Play music';
    }
    pending.add(id);
    try {
      const ctx = audioContext();
      if (ctx.state !== 'running') throw new Error('Tap the game to enable audio.');
      manifest ??= fetch(new URL('./game/project.json', import.meta.url)).then(r => {
        if (!r.ok) throw new Error(`Project: HTTP ${r.status}`);
        return r.json();
      });
      const project = await manifest;
      const asset = project.assets?.find(a => a.id === id && a.kind === 'audio');
      if (!asset) throw new Error(`Unknown audio resource: ${id}`);
      let buffer = buffers.get(id);
      if (!buffer) {
        const path = asset.path.split('/').map(encodeURIComponent).join('/');
        const response = await fetch(new URL(`./game/${path}`, import.meta.url));
        if (!response.ok) throw new Error(`Audio: HTTP ${response.status}`);
        buffer = await ctx.decodeAudioData(await response.arrayBuffer());
        buffers.set(id, buffer);
      }
      const source = ctx.createBufferSource();
      const gain = ctx.createGain(); gain.gain.value = 0.18;
      source.buffer = buffer; source.loop = true;
      const analyser = ctx.createAnalyser(); analyser.fftSize = 256;
      source.connect(gain).connect(analyser).connect(ctx.destination);
      source.onended = () => { source.disconnect(); gain.disconnect(); analyser.disconnect(); };
      source.start(); active.set(id, source);
      console.log(`[AdaWebPlayer.Audio] playing ${id}, ${buffer.duration.toFixed(2)}s, context=${ctx.state}`);
      setTimeout(() => {
        if (!active.has(id)) return;
        const samples = new Float32Array(analyser.fftSize);
        analyser.getFloatTimeDomainData(samples);
        const rms = Math.sqrt(samples.reduce((sum, x) => sum + x*x, 0) / samples.length);
        console.log(`[AdaWebPlayer.Audio] output ${id} RMS=${rms.toFixed(5)}`);
      }, 250);
      return 'Stop music';
    } catch (error) { report(error); return `Audio: ${error.message ?? error}`; }
    finally { pending.delete(id); }
  },
  stopAll: () => { for (const source of active.values()) source.stop(); active.clear(); }
};
addEventListener('pagehide', () => { globalThis.__adaPlayerAudio.stopAll(); context?.close(); });
