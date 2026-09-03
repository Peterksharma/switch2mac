// bridge.js — runs in the extension's isolated world. Relays hub messages to
// shim.js (main world) as DOM events, and rumble/telemetry the other way.
//
// Transport: the page tries a direct WebSocket to the app first (shortest
// path: no service-worker hop, which matters under a streaming video load).
// If the browser refuses it — Chrome's Local Network Access permission may
// gate loopback sockets in the future — it falls back to the service
// worker in background.js, which is outside that permission.
//
// Strings only across the world boundary: Chrome does not share objects
// between isolated and main worlds.

(() => {
  const URL = 'ws://127.0.0.1:24810';
  const RETRY_MS = 2000;
  const PING_MS = 20000;

  let socket = null;      // direct mode
  let port = null;        // relay mode
  let directFailed = false;
  let timer = null;

  const toPage = (text) =>
    document.dispatchEvent(new CustomEvent('ftcw-bridge', { detail: text }));

  function connectDirect() {
    let opened = false;
    try { socket = new WebSocket(URL); } catch { socket = null; directFailed = true; connectRelay(); return; }
    socket.onopen = () => { opened = true; toPage('{"t":"bridge","up":true}'); };
    socket.onmessage = (ev) => { if (typeof ev.data === 'string') toPage(ev.data); };
    socket.onerror = () => {};
    socket.onclose = () => {
      socket = null;
      if (!opened) {
        // Refused before opening: either the app is not running or the
        // browser blocks page-initiated loopback sockets. The relay can tell
        // the two apart, so hand over to it from now on.
        directFailed = true;
        connectRelay();
        return;
      }
      toPage('{"t":"bridge","up":false}');
      schedule(connectDirect);
    };
  }

  function connectRelay() {
    try {
      port = chrome.runtime.connect({ name: 'ftcw' });
    } catch {
      toPage('{"t":"bridge","up":false}');   // extension reloaded: orphaned script
      return;
    }
    port.onMessage.addListener((text) => { if (typeof text === 'string') toPage(text); });
    port.onDisconnect.addListener(() => {
      port = null;
      clearInterval(timer);
      toPage('{"t":"bridge","up":false}');
      setTimeout(connectRelay, RETRY_MS / 2);
    });
    timer = setInterval(() => { try { port && port.postMessage('ping'); } catch {} }, PING_MS);
  }

  function schedule(fn) { setTimeout(fn, RETRY_MS); }

  document.addEventListener('ftcw-up', (ev) => {
    if (typeof ev.detail !== 'string') return;
    if (socket && socket.readyState === WebSocket.OPEN) { socket.send(ev.detail); return; }
    if (port) { try { port.postMessage(ev.detail); } catch {} }
  });

  connectDirect();
})();
