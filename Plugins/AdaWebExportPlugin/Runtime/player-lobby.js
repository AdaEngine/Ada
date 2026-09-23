// The lobby keeps connection tickets in this page's memory only. The server
// endpoints create/join Cloud relay sessions and return a one-use ticket.
const loader = document.getElementById('ada-loader');
const status = document.getElementById('ada-loader-status');

if (new URLSearchParams(location.search).has('debug')) {
  const output = document.createElement('pre');
  output.id = 'ada-debug-console';
  output.style.cssText = 'position:fixed;z-index:2147483647;left:8px;bottom:8px;max-width:95vw;max-height:40vh;overflow:auto;padding:8px;background:#000d;color:#fff;font:12px monospace;white-space:pre-wrap';
  document.body.append(output);
  for (const level of ['log', 'warn', 'error']) {
    const original = console[level].bind(console);
    console[level] = (...values) => {
      original(...values);
      output.textContent += `[${level}] ${values.map(value => value instanceof Error ? value.stack : String(value)).join(' ')}\n`;
      output.scrollTop = output.scrollHeight;
    };
  }
  window.addEventListener('error', event => console.error(event.message));
  window.addEventListener('unhandledrejection', event => console.error(event.reason));
}

function message(value) {
  if (status) status.textContent = value;
}

function showLobby(title) {
  const panel = document.createElement('form');
  panel.setAttribute('aria-label', 'Multiplayer lobby');
  panel.style.cssText = 'position:fixed;z-index:2147483647;inset:0;display:grid;place-content:center;gap:12px;padding:24px;background:#10131c;color:#f8fafc;font:16px system-ui';
  const heading = document.createElement('h1');
  heading.textContent = title;
  const code = document.createElement('input');
  code.placeholder = 'Room code';
  code.autocomplete = 'off';
  code.maxLength = 8;
  code.style.cssText = 'padding:12px;font:inherit;text-transform:uppercase';
  const host = document.createElement('button');
  host.type = 'button';
  host.textContent = 'Create room';
  const join = document.createElement('button');
  join.type = 'submit';
  join.textContent = 'Join room';
  const solo = document.createElement('button');
  solo.type = 'button';
  solo.textContent = 'Play solo';
  const detail = document.createElement('p');
  detail.setAttribute('role', 'status');
  panel.append(heading, code, host, join, solo, detail);
  document.body.append(panel);
  if (loader) loader.style.display = 'none';

  async function request(path, body) {
    host.disabled = true;
    join.disabled = true;
    detail.textContent = 'Connecting…';
    try {
      const response = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        credentials: 'same-origin',
        cache: 'no-store'
      });
      const value = await response.json().catch(() => ({
        error: 'Cloud multiplayer is not configured for this Web run. Choose Play solo or configure Cloud in AdaEditor.'
      }));
      if (!response.ok) throw new Error(value.error || value.reason || `HTTP ${response.status}`);
      if (!value.sessionID || !value.peerID || !value.relayURL || !value.connectionTicket) {
        throw new Error('The relay returned an incomplete session.');
      }
      if (value.joinCode) {
        detail.textContent = `Room code: ${value.joinCode}`;
        const badge = document.createElement('p');
        badge.textContent = `Share code ${value.joinCode} with other players.`;
        badge.style.cssText = 'position:fixed;z-index:2147483646;top:8px;right:16px;padding:8px 12px;border-radius:8px;background:#10131ccc;color:white;font:14px system-ui';
        document.body.append(badge);
      }
      window.__adaMultiplayerSession = JSON.stringify({
        sessionID: value.sessionID,
        peerID: value.peerID,
        role: path.endsWith('/sessions') ? 'host' : 'peer',
        relayURL: value.relayURL,
        connectionTicket: value.connectionTicket
      });
      panel.remove();
      if (loader) loader.style.display = '';
      await import('./main.js');
    } catch (error) {
      detail.textContent = error instanceof Error ? error.message : String(error);
      host.disabled = false;
      join.disabled = false;
    }
  }

  host.addEventListener('click', () => request('/ada-multiplayer/sessions', {}));
  solo.addEventListener('click', async () => {
    window.__adaSoloMode = true;
    panel.remove();
    if (loader) loader.style.display = '';
    await import('./main.js');
  });
  panel.addEventListener('submit', event => {
    event.preventDefault();
    const joinCode = code.value.trim().toUpperCase();
    if (!/^[A-Z0-9]{8}$/.test(joinCode)) {
      detail.textContent = 'Enter the eight-character room code.';
      return;
    }
    request('/ada-multiplayer/join', { joinCode });
  });
}

try {
  const response = await fetch('./game/project.json', { cache: 'no-store' });
  if (!response.ok) throw new Error('Game manifest is missing.');
  const project = await response.json();
  if (project.entryScene) {
    let settingsResponse = await fetch('./game/.ada/project.json', { cache: 'no-store' });
    if (!settingsResponse.ok) settingsResponse = await fetch('./game/runtime-settings.json', { cache: 'no-store' });
    if (!settingsResponse.ok) throw new Error('Game runtime settings are missing.');
    const settings = await settingsResponse.json();
    const plugins = settings.runtime?.plugins;
    const multiplayer = plugins?.enable?.includes('multiplayer') && !plugins?.disable?.includes('multiplayer');
    if (multiplayer && new URLSearchParams(location.search).get('solo') !== '1') {
      showLobby(project.title || 'AdaEngine game');
    } else {
      window.__adaSoloMode = true;
      await import('./main.js');
    }
  } else await import('./main.js');
} catch (error) {
  message(error instanceof Error ? error.message : String(error));
}
