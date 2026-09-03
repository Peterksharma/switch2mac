// bridge.js — runs in the extension's isolated world. Relays hub messages
// from the service worker (background.js) to shim.js in the page's main
// world as DOM events, and rumble the other way.
//
// Strings only across the world boundary: Chrome does not share objects
// between isolated and main worlds.

(() => {
  const RETRY_MS = 1000;
  const PING_MS = 20000;
  let port = null;
  let pingTimer = null;

  const toPage = (text) =>
    document.dispatchEvent(new CustomEvent('ftcw-bridge', { detail: text }));

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'ftcw' });
    } catch {
      // Extension reloaded/removed: this content script is orphaned.
      toPage('{"t":"bridge","up":false}');
      return;
    }
    port.onMessage.addListener((text) => { if (typeof text === 'string') toPage(text); });
    port.onDisconnect.addListener(() => {
      port = null;
      clearInterval(pingTimer);
      toPage('{"t":"bridge","up":false}');
      setTimeout(connect, RETRY_MS);
    });
    // Port traffic keeps the service worker alive while a page is open.
    pingTimer = setInterval(() => { try { port && port.postMessage('ping'); } catch {} }, PING_MS);
  }

  document.addEventListener('ftcw-rumble', (ev) => {
    if (port && typeof ev.detail === 'string') {
      try { port.postMessage(ev.detail); } catch {}
    }
  });

  connect();
})();
