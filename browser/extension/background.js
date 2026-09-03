// background.js — the extension's service worker owns the WebSocket to the
// menu-bar app (ws://127.0.0.1:24810). Extension contexts are not subject to
// Chrome's Local Network Access permission, which would otherwise prompt (or
// silently block) a public https:// page opening a loopback socket.
//
// Content scripts (bridge.js) attach through chrome.runtime.connect ports;
// every hub message is fanned out to all ports, rumble from any port goes to
// the hub. Hub pings (every 15 s) and port traffic keep the worker alive.

const URL = 'ws://127.0.0.1:24810';
const RETRY_MS = 2000;

const ports = new Set();
let socket = null;
let retryTimer = null;
let replay = new Map();   // slot → last "connected"/"name" JSON, for late ports

const fanOut = (text) => { for (const port of ports) { try { port.postMessage(text); } catch {} } };

function connect() {
  retryTimer = null;
  if (socket || ports.size === 0) return;
  try { socket = new WebSocket(URL); } catch { scheduleRetry(); return; }
  socket.onopen = () => fanOut('{"t":"bridge","up":true}');
  socket.onmessage = (ev) => {
    if (typeof ev.data !== 'string') return;
    track(ev.data);
    fanOut(ev.data);
  };
  socket.onclose = () => {
    socket = null;
    replay = new Map();
    fanOut('{"t":"bridge","up":false}');
    scheduleRetry();
  };
  socket.onerror = () => {};
}

function scheduleRetry() {
  if (retryTimer !== null || ports.size === 0) return;
  retryTimer = setTimeout(connect, RETRY_MS);
}

// Remember per-slot identity so a tab opened later sees connected pads.
function track(text) {
  let m;
  try { m = JSON.parse(text); } catch { return; }
  if (m.t === 'connected' || m.t === 'name') replay.set(m.slot, text);
  else if (m.t === 'disconnected') replay.delete(m.slot);
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'ftcw') return;
  ports.add(port);
  port.onMessage.addListener((text) => {
    if (typeof text !== 'string' || text === 'ping') return;
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(text);
  });
  port.onDisconnect.addListener(() => {
    ports.delete(port);
    if (ports.size === 0 && socket) { socket.close(); socket = null; }
  });
  if (socket && socket.readyState === WebSocket.OPEN) {
    port.postMessage('{"t":"bridge","up":true}');
    for (const text of replay.values()) port.postMessage(text);
  } else {
    connect();
  }
});
