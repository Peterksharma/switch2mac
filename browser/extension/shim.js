// shim.js — runs in the page's main world. Wraps navigator.getGamepads() so
// controllers streamed by the Finally the Controller Works app appear as
// standard-mapping gamepads alongside any real ones, fires
// gamepadconnected/gamepaddisconnected, and forwards vibrationActuator
// effects back to the app (rumble).
//
// Button layout is POSITIONAL by default (the bottom face button is the
// standard "A"/index 0, exactly as an Xbox pad would report), so on-screen
// prompts in Xbox Cloud Gaming match what your thumb does. Set
// NINTENDO_LABELS to true to map by label instead (Switch A → standard A).

(() => {
  if (navigator.__ftcwBridge) return;

  const NINTENDO_LABELS = false;
  // How the pad introduces itself. Sites classify controllers by the vendor
  // id in this string (045e Xbox, 057e Nintendo, …) and pick glyphs and
  // per-vendor handling from that. 'nintendo' keeps the real identity;
  // 'xbox' presents as an Xbox Wireless Controller, which some streaming
  // services treat on a better-trodden path (GeForce NOW sends an
  // "is Xbox" flag to its servers with every input packet).
  // Per-site override without touching files: in the site's DevTools console
  //   localStorage.ftcwPersona = 'xbox'   (or 'nintendo'; remove to reset)
  // then reload the page.
  const PERSONA_DEFAULT = 'nintendo';
  const PERSONA = (() => {
    try { const v = localStorage.getItem('ftcwPersona'); if (v === 'xbox' || v === 'nintendo') return v; } catch {}
    return PERSONA_DEFAULT;
  })();
  // Expose C / GL / GR as buttons 18-20. Off by default: real Xbox pads stop
  // at 17 (Share), and some sites misbehave with extra indices.
  const EXTRA_BUTTONS = false;

  // Switch2.Buttons bits (Protocol/Switch2Protocol.swift).
  const BIT = {
    y: 1 << 0, x: 1 << 1, b: 1 << 2, a: 1 << 3, r: 1 << 6, zr: 1 << 7,
    minus: 1 << 8, plus: 1 << 9, rStick: 1 << 10, lStick: 1 << 11,
    home: 1 << 12, capture: 1 << 13, c: 1 << 14,
    dpadDown: 1 << 16, dpadUp: 1 << 17, dpadRight: 1 << 18, dpadLeft: 1 << 19,
    l: 1 << 22, zl: 1 << 23, gr: 1 << 24, gl: 1 << 25,
  };

  // Standard Gamepad button indices → Switch2 bit. Indices 6/7 (triggers)
  // are analog and handled separately; 17 = share/capture (Xbox Series X
  // extension index), 18 = C, 19/20 = GL/GR back paddles.
  const face = NINTENDO_LABELS
    ? [BIT.a, BIT.b, BIT.x, BIT.y]      // by label
    : [BIT.b, BIT.a, BIT.y, BIT.x];     // by position: bottom, right, left, top
  const BUTTON_BITS = [
    face[0], face[1], face[2], face[3],
    BIT.l, BIT.r, 0, 0,
    BIT.minus, BIT.plus, BIT.lStick, BIT.rStick,
    BIT.dpadUp, BIT.dpadDown, BIT.dpadLeft, BIT.dpadRight,
    BIT.home, BIT.capture,
    ...(EXTRA_BUTTONS ? [BIT.c, BIT.gl, BIT.gr] : []),
  ];
  const BUTTON_COUNT = BUTTON_BITS.length;

  const pads = new Map();       // slot → virtual pad
  const nativeGetGamepads = Navigator.prototype.getGamepads;
  let bridgeUp = false;

  const toApp = (obj) =>
    document.dispatchEvent(new CustomEvent('ftcw-up', { detail: JSON.stringify(obj) }));
  const rumbleToApp = (slot, strong, weak) => toApp({ t: 'rumble', slot, strong, weak });

  // Delivery telemetry: how state messages actually arrive in this page
  // (intervals between them) and how often the site polls getGamepads().
  // Sent to the hub every 5 s as {"t":"stats"}; the hub rebroadcasts it to
  // any other client, so it can be read outside the browser.
  const STATS_WINDOW_MS = 5000;
  let arrivals = new Map();   // slot → [performance.now(), …]
  let getCalls = 0;
  let statsTimer = null;
  function noteArrival(slot) {
    let a = arrivals.get(slot);
    if (!a) { a = []; arrivals.set(slot, a); }
    a.push(performance.now());
    if (statsTimer === null) statsTimer = setTimeout(flushStats, STATS_WINDOW_MS);
  }
  function flushStats() {
    statsTimer = null;
    for (const [slot, a] of arrivals) {
      const gaps = [];
      for (let i = 1; i < a.length; i++) gaps.push(a[i] - a[i - 1]);
      gaps.sort((x, y) => x - y);
      const q = (f) => gaps.length ? +gaps[Math.min(gaps.length - 1, Math.floor(gaps.length * f))].toFixed(1) : 0;
      toApp({ t: 'stats', slot, win: STATS_WINDOW_MS, n: a.length, med: q(0.5), p95: q(0.95),
              max: gaps.length ? +gaps[gaps.length - 1].toFixed(1) : 0, over60: gaps.filter((g) => g > 60).length,
              gets: getCalls, hidden: document.hidden, url: location.host });
    }
    arrivals = new Map();
    getCalls = 0;
  }

  function makeActuator(slot) {
    let timer = null;
    let pending = null;
    const finish = (result) => {
      if (pending) { const p = pending; pending = null; p(result); }
    };
    const stop = () => {
      if (timer) { clearTimeout(timer); timer = null; }
      rumbleToApp(slot, 0, 0);
    };
    return {
      type: 'dual-rumble',
      effects: ['dual-rumble'],
      playEffect(type, params = {}) {
        if (type !== 'dual-rumble') return Promise.resolve('invalid-parameter');
        const strong = clamp01(params.strongMagnitude);
        const weak = clamp01(params.weakMagnitude);
        const duration = Math.max(0, Number(params.duration) || 0);
        const startDelay = Math.max(0, Number(params.startDelay) || 0);
        if (timer) clearTimeout(timer);
        finish('preempted');
        return new Promise((resolve) => {
          pending = resolve;
          const start = () => {
            rumbleToApp(slot, strong, weak);
            timer = setTimeout(() => { timer = null; rumbleToApp(slot, 0, 0); finish('complete'); }, duration);
          };
          if (startDelay > 0) timer = setTimeout(start, startDelay); else start();
        });
      },
      reset() { stop(); finish('preempted'); return Promise.resolve('complete'); },
      stop,
    };
  }

  const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));

  const padId = (model, name) => PERSONA === 'xbox'
    ? 'Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)'
    : `${name || model} (STANDARD GAMEPAD Vendor: 057e Product: 2069)`;

  function makePad(slot, model, name) {
    const buttons = [];
    for (let i = 0; i < BUTTON_COUNT; i++) {
      const button = { pressed: false, touched: false, value: 0 };
      // Own properties shadow the native accessors, so `instanceof` checks
      // pass without ever touching the (throwing) prototype getters.
      if (typeof GamepadButton !== 'undefined') Object.setPrototypeOf(button, GamepadButton.prototype);
      buttons.push(button);
    }
    const pad = {
      id: padId(model, name),
      index: -1,
      connected: true,
      mapping: 'standard',
      timestamp: performance.now(),
      axes: [0, 0, 0, 0],
      buttons,
      hapticActuators: [],
      vibrationActuator: makeActuator(slot),
      __ftcwSlot: slot,
    };
    if (typeof Gamepad !== 'undefined') Object.setPrototypeOf(pad, Gamepad.prototype);
    return pad;
  }

  // Place virtual pads in the lowest indices not occupied by real gamepads.
  function assignIndex(pad) {
    const taken = new Set();
    for (const g of nativeGetGamepads.call(navigator)) if (g) taken.add(g.index);
    for (const p of pads.values()) if (p !== pad && p.index >= 0) taken.add(p.index);
    let i = 0;
    while (taken.has(i)) i++;
    pad.index = i;
  }

  function fire(type, pad) {
    const ev = new Event(type);
    Object.defineProperty(ev, 'gamepad', { value: pad, enumerable: true });
    window.dispatchEvent(ev);
  }

  function applyState(pad, m) {
    const b = m.b >>> 0;
    const btn = pad.buttons;
    for (let i = 0; i < BUTTON_COUNT; i++) {
      const bit = BUTTON_BITS[i];
      if (!bit) continue;
      const on = (b & bit) !== 0;
      btn[i].pressed = on; btn[i].touched = on; btn[i].value = on ? 1 : 0;
    }
    const lt = Math.max((b & BIT.zl) ? 1 : 0, (m.lt || 0) / 255);
    const rt = Math.max((b & BIT.zr) ? 1 : 0, (m.rt || 0) / 255);
    btn[6].value = lt; btn[6].pressed = lt > 0.5; btn[6].touched = lt > 0;
    btn[7].value = rt; btn[7].pressed = rt > 0.5; btn[7].touched = rt > 0;
    // App axes: +y = up. Standard Gamepad: +y = down.
    pad.axes[0] = m.lx; pad.axes[1] = -m.ly; pad.axes[2] = m.rx; pad.axes[3] = -m.ry;
    pad.timestamp = performance.now();
  }

  function disconnectAll() {
    for (const [slot, pad] of pads) {
      pads.delete(slot);
      pad.connected = false;
      pad.vibrationActuator.stop();
      fire('gamepaddisconnected', pad);
    }
  }

  document.addEventListener('ftcw-bridge', (ev) => {
    let m;
    try { m = JSON.parse(ev.detail); } catch { return; }
    switch (m.t) {
      case 'bridge':
        bridgeUp = !!m.up;
        if (!bridgeUp) disconnectAll();
        break;
      case 'connected': {
        let pad = pads.get(m.slot);
        if (pad) { pad.id = padId(m.model, m.name); break; }
        pad = makePad(m.slot, m.model, m.name);
        assignIndex(pad);
        pads.set(m.slot, pad);
        fire('gamepadconnected', pad);
        break;
      }
      case 'name': {
        const pad = pads.get(m.slot);
        if (pad) pad.id = padId('', m.name);
        break;
      }
      case 'state': {
        const pad = pads.get(m.slot);
        if (pad) { applyState(pad, m); noteArrival(m.slot); }
        break;
      }
      case 'disconnected': {
        const pad = pads.get(m.slot);
        if (!pad) break;
        pads.delete(m.slot);
        pad.connected = false;
        pad.vibrationActuator.stop();
        fire('gamepaddisconnected', pad);
        break;
      }
    }
  });

  // Chrome hands out a fresh immutable snapshot per getGamepads() call, and
  // sites diff consecutive snapshots to detect edges. Mutating one shared
  // object would make "previous" and "current" the same thing, so hand out
  // copies the way the browser does.
  function snapshot(pad) {
    const copy = {
      id: pad.id, index: pad.index, connected: pad.connected, mapping: pad.mapping,
      timestamp: pad.timestamp, axes: pad.axes.slice(),
      buttons: pad.buttons.map((b) => {
        const button = { pressed: b.pressed, touched: b.touched, value: b.value };
        if (typeof GamepadButton !== 'undefined') Object.setPrototypeOf(button, GamepadButton.prototype);
        return button;
      }),
      hapticActuators: pad.hapticActuators,
      vibrationActuator: pad.vibrationActuator,
      __ftcwSlot: pad.__ftcwSlot,
    };
    if (typeof Gamepad !== 'undefined') Object.setPrototypeOf(copy, Gamepad.prototype);
    return copy;
  }

  Navigator.prototype.getGamepads = function () {
    const real = Array.from(nativeGetGamepads.call(this));
    if (pads.size === 0) return real;
    getCalls++;
    for (const pad of pads.values()) {
      while (real.length <= pad.index) real.push(null);
      if (real[pad.index] === null || real[pad.index] === undefined) real[pad.index] = snapshot(pad);
    }
    return real;
  };

  Object.defineProperty(navigator, '__ftcwBridge', {
    value: { get pads() { return [...pads.values()]; }, get up() { return bridgeUp; }, persona: PERSONA },
  });
})();
