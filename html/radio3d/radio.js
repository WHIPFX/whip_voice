// RadioUI: interactive 3D handheld radio (three.js) with a working segment LCD.
// The page owns the <canvas> (size/position it with CSS, e.g. bottom-right in game); RadioUI fills it.
//
//   const radio = new RadioUI(canvas, { modelUrl: './radio.glb' }); await radio.init();
//   radio.addEventListener('channel', e => console.log(e.detail));   // see README for every event
//   radio.setPower(true); radio.setReceiving(true, 'UNIT 12');
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { drawLCD } from './lcd.js';

const DEFAULTS = {
  modelUrl: './radio.glb',
  minChannel: 100, maxChannel: 999,
  channel: 100, volume: 6, power: false,
  channelNames: {},                                   // { 100: 'DISPATCH', 101: 'EMS' } shown instead of CH-100
  frequency: (ch) => ch.toFixed(3),                   // the channel is the frequency: 420 -> 420.000 (MHz on the LCD)
  sounds: true,
  keyboard: false,                                    // test page shortcuts (see README)
  idle: true,                                         // gentle idle motion
  layout: 'corner',                                   // 'corner' (in game) | 'inspect' (orbit to look around)
  look: true,                                         // corner: faces you flat; the pointer past an edge turns that side to you
  powerHint: true,                                    // the ⏻ under the volume knob pulses while the radio is off
  blit: 'auto',                                       // copy frames to a 2D canvas: 'auto' = only inside FiveM NUI
  pixelRatio: Math.min(window.devicePixelRatio || 1, 2),
  bootLogo: 'WHIP',
};

const LABELS = {
  knob_volume: 'Volume (drag or scroll) · click: power off', knob_channel: 'Channel (drag or scroll) · click: next', btn_ptt: 'Push to talk (hold)', btn_side: 'Backlight',
  btn_speaker: 'Speaker: nearby players hear the radio', key_up: 'Channel up', key_down: 'Channel down', key_menu: 'Menu: beeps on/off',
  key_star: 'Clear', key_hash: 'Enter channel',
};
for (let d = 0; d <= 9; d++) LABELS['key_' + d] = 'Type channel ' + d;
const PRESS = { key: 0.0011, btn_ptt: 0.0013, btn_side: 0.0009, btn_speaker: 0.0009 };  // press travel (m)

export class RadioUI extends EventTarget {
  state = { power: false, channel: 1, volume: 6, tx: false, rx: false, rxName: '', signal: 4, battery: 4, light: false,
            speaker: false, beeps: true, entry: '' };
  #o; #canvas; #gl; #ctx2d; #renderer; #scene; #camera; #controls; #root; #pivot; #parts = {}; #pickables = []; #labels = {};
  #lcdCanvas; #lcdTex; #screenMat; #keyMat; #ledMat; #mats = new Map();
  #hover = null; #down = null; #anim = []; #dirty = true; #last = 0; #t0 = performance.now();
  #mode = 'off'; #modeUntil = 0; #subUntil = 0; #subKind = 'freq'; #msg = ''; #lightUntil = 0; #blink = true;
  #audio = null; #raf = 0; #open = true; #openT = 1; #ro; #knobAngle = { knob_volume: 0, knob_channel: 0 };
  #raycaster = new THREE.Raycaster(); #ptr = new THREE.Vector2(); #keydown; #keyup; #listeners = []; #tick = null; #closedDrawn = false;
  #look = { yaw: 0, pitch: 0, tYaw: 0, tPitch: 0, px: null, py: null, t: 0 }; #foot = null; #box0; #bodyBox; #keysBottom = 0; #halo = null;
  #anchor = new THREE.Vector3(); #turned = new THREE.Vector3();

  constructor(canvas, options = {}) {
    super();
    this.#canvas = canvas;
    this.#o = { ...DEFAULTS, ...options, channelNames: { ...(options.channelNames || {}) } };
    Object.assign(this.state, { channel: this.#o.channel, volume: this.#o.volume });
  }

  // ------------------------------------------------------------------ setup
  async init() {
    const o = this.#o;
    const inNui = typeof window.GetParentResourceName === 'function' || /^nui:|cfx-nui-/.test(location.href);
    const blit = o.blit === 'auto' ? inNui : !!o.blit;
    this.#gl = blit ? document.createElement('canvas') : this.#canvas;
    if (blit) this.#ctx2d = this.#canvas.getContext('2d');
    const r = this.#renderer = new THREE.WebGLRenderer({ canvas: this.#gl, antialias: true, alpha: true, premultipliedAlpha: true });
    r.setClearColor(0x000000, 0); r.outputColorSpace = THREE.SRGBColorSpace;
    r.toneMapping = THREE.ACESFilmicToneMapping; r.toneMappingExposure = 1.05;
    const scene = this.#scene = new THREE.Scene();
    const pm = new THREE.PMREMGenerator(r);
    scene.environment = pm.fromScene(new RoomEnvironment(), 0.04).texture; scene.environmentIntensity = 0.55;
    pm.dispose();                                     // whip: the generator's own targets and shaders; the texture stays
    const key = new THREE.DirectionalLight(0xfff4e8, 2.2); key.position.set(-0.6, 0.9, 1.2); scene.add(key);
    const rim = new THREE.DirectionalLight(0xd8e6ff, 1.6); rim.position.set(0.9, 0.5, -0.8); scene.add(rim);
    const fill = new THREE.DirectionalLight(0xffffff, 0.45); fill.position.set(0.8, -0.2, 1.0); scene.add(fill);
    this.#camera = new THREE.PerspectiveCamera(16, 1, 0.01, 10);

    // Embedded textures decode straight from memory (createImageBitmap, as three's ImageBitmapLoader does), never via a
    // blob:/data: URL: strict pages (CSP, e.g. the browser preview) may refuse to fetch or show those.
    const loader = new GLTFLoader();
    loader.register((parser) => {
      const viaUrl = parser.loadImageSource.bind(parser);
      parser.loadImageSource = (index, texLoader) => {
        const def = parser.json.images[index];
        if (def.bufferView === undefined || typeof createImageBitmap !== 'function') return viaUrl(index, texLoader);
        if (parser.sourceCache[index]) return parser.sourceCache[index].then((t) => t.clone());
        return (parser.sourceCache[index] = parser.getDependency('bufferView', def.bufferView)
          .then((view) => createImageBitmap(new Blob([view], { type: def.mimeType }), { premultiplyAlpha: 'none', colorSpaceConversion: 'none' }))
          .then((bitmap) => { const tex = new THREE.Texture(bitmap); tex.needsUpdate = true; tex.userData.mimeType = def.mimeType; return tex; }));
      };
      return { name: 'memory_textures' };
    });
    let gltf;
    if (/\.json(\?|#|$)/i.test(o.modelUrl)) {          // GLB packed as base64 in JSON, for hosts that won't serve .glb
      const res = await fetch(o.modelUrl); if (!res.ok) throw new Error(`model ${o.modelUrl}: HTTP ${res.status}`);
      const { glb } = await res.json(); const raw = atob(glb); const bytes = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
      gltf = await loader.parseAsync(bytes.buffer, '');
    } else gltf = await loader.loadAsync(o.modelUrl);
    const root = this.#root = gltf.scene.getObjectByName('radio') || gltf.scene;
    this.#pivot = new THREE.Group(); this.#pivot.add(root); scene.add(this.#pivot);
    const box = new THREE.Box3().setFromObject(root); const c = box.getCenter(new THREE.Vector3());
    root.position.sub(c);                                                 // radio centred on the pivot
    this.#pivot.updateMatrixWorld(true);                                  // neutral pose: pivot space = world space
    this.#box0 = new THREE.Box3().setFromObject(root);
    const body = root.getObjectByName('radio_body');
    this.#bodyBox = body ? new THREE.Box3().setFromObject(body) : this.#box0.clone();   // front face = max.z, top = max.y
    root.traverse((ob) => {
      if (!ob.isMesh) return;
      const name = this.#partName(ob);
      if (name) {
        ob.material = ob.material.clone(); ob.userData.part = name;
        this.#mats.set(ob, { color: ob.material.color.clone(), emissive: ob.material.emissive.clone(), ei: ob.material.emissiveIntensity });
        this.#pickables.push(ob);
        if (/_label$/.test(ob.name)) this.#labels[name] = ob;      // printed dial mark: extra hit area for its knob
      }
      for (const k of ['map', 'emissiveMap']) if (ob.material[k]) ob.material[k].anisotropy = r.capabilities.getMaxAnisotropy();
      if (ob.material.transparent) { ob.material.depthWrite = false; ob.renderOrder = 2; }
    });
    for (const n of ['screen', 'led', 'knob_volume', 'knob_channel', 'btn_ptt', 'btn_side', 'btn_speaker']) this.#parts[n] = root.getObjectByName(n);
    root.traverse((ob) => { if (/^key_/.test(ob.name)) this.#parts[ob.name] = ob; });
    for (const p of Object.values(this.#parts)) if (p) p.userData.rest = { pos: p.position.clone(), rot: p.rotation.clone() };
    this.#keysBottom = Math.min(...Object.entries(this.#parts).filter(([n, p]) => p && n.startsWith('key_'))
      .map(([, p]) => new THREE.Box3().setFromObject(p).min.y));                // neutral pose still: pivot space
    // power hint halo: a soft glow around the ⏻ (position from the model), drawn additively over the mark
    const vl = this.#labels.knob_volume, pmm = vl?.userData.power_mm, amm = vl?.userData.atlas_mm;
    if (pmm && amm) {
      const k = 24, hc = document.createElement('canvas'); hc.width = Math.round(amm[0] * k); hc.height = Math.round(amm[1] * k);
      const g = hc.getContext('2d'), gr = g.createRadialGradient(pmm[0] * k, pmm[1] * k, 0, pmm[0] * k, pmm[1] * k, 2.7 * k);
      gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.35, 'rgba(255,255,255,0.55)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = gr; g.fillRect(0, 0, hc.width, hc.height);
      const map = new THREE.CanvasTexture(hc); map.flipY = false;                 // glTF UVs: v = 0 at the top
      this.#halo = new THREE.Mesh(vl.geometry, new THREE.MeshBasicMaterial({ map, color: 0x3cff32, transparent: true, opacity: 0,
        blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
      this.#halo.renderOrder = 3; this.#halo.visible = false; vl.add(this.#halo);
    }

    // LCD: a canvas texture on the screen plane (glTF UVs: v = 0 at the top, so no flip)
    this.#lcdCanvas = document.createElement('canvas'); this.#lcdCanvas.width = 512; this.#lcdCanvas.height = 256;
    const tex = this.#lcdTex = new THREE.CanvasTexture(this.#lcdCanvas);
    tex.colorSpace = THREE.SRGBColorSpace; tex.flipY = false; tex.anisotropy = r.capabilities.getMaxAnisotropy();
    this.#screenMat = new THREE.MeshBasicMaterial({ map: tex, toneMapped: false });
    this.#parts.screen.material = this.#screenMat;
    const anyKey = this.#parts.key_5; this.#keyMat = anyKey.material;
    this.#ledMat = this.#parts.led.material; this.#ledMat.emissive.set(0x000000); this.#ledMat.toneMapped = false;

    this.#bindInput();
    this.#ro = new ResizeObserver(() => this.#resize()); this.#ro.observe(this.#canvas); this.#resize();
    if (o.layout === 'inspect') this.setLayout('inspect');
    if (o.power) this.setPower(true, { silent: true, instant: true }); else this.#applyPower();
    this.#tick = (now) => this.#loop(now); this.#raf = requestAnimationFrame(this.#tick);
    this.#emit('ready', this.getState());
    return this;
  }

  #partName(ob) {
    for (let p = ob; p; p = p.parent) {
      const label = /^(knob_volume|knob_channel|btn_speaker)_label$/.exec(p.name);   // printed label = its control
      if (label) return label[1];
      if (/^(key_|btn_)/.test(p.name) || p.name === 'knob_volume' || p.name === 'knob_channel') return p.name;
      if (p.name === 'radio') return null;
    }
    return null;
  }

  #resize() {
    const r = this.#canvas.getBoundingClientRect(); const pr = this.#o.pixelRatio;
    const w = Math.max(1, Math.round(r.width * pr)), h = Math.max(1, Math.round(r.height * pr));
    this.#renderer.setPixelRatio(1); this.#renderer.setSize(w, h, false);
    if (this.#ctx2d) { this.#canvas.width = w; this.#canvas.height = h; }
    this.#camera.aspect = w / h; this.#frame(); this.#dirty = true;
  }

  #frame() {      // fit the radio in the canvas (corner: straight on, flat; inspect: 3/4 orbit target)
    const cam = this.#camera; const box = this.#box0;
    const s = box.getSize(new THREE.Vector3()); const fov = THREE.MathUtils.degToRad(cam.fov);
    // corner: the canvas bottom edge sits 1 cm under the last key row and the grille runs off it (held up from below),
    // so the screen and keys read larger; every key stays on screen
    const cut = this.#o.layout !== 'inspect';
    const y0 = cut ? Math.max(box.min.y, this.#keysBottom - 0.010) : box.min.y, y1 = box.max.y, yc = (y0 + y1) / 2, hv = y1 - y0;
    const fitH = (hv * 0.5) / Math.tan(fov / 2), fitW = (Math.max(s.x, s.z) * 0.62) / (Math.tan(fov / 2) * cam.aspect);
    const d = Math.max(fitH, fitW) * (cut ? 1.0 : 1.06);
    if (cut) cam.position.set(0, yc, d); else cam.position.set(-d * 0.10, yc + d * 0.06, d);
    cam.lookAt(0, yc, 0); cam.near = d * 0.2; cam.far = d * 4; cam.updateProjectionMatrix(); cam.updateMatrixWorld();
    if (this.#controls) { this.#controls.target.set(0, yc, 0); this.#controls.update(); }
    const b = this.#bodyBox, ym = (b.min.y + b.max.y) / 2, p = (x, y) => new THREE.Vector3(x, y, b.max.z).project(cam);
    this.#foot = { xl: p(b.min.x, ym).x, xr: p(b.max.x, ym).x, yt: p(0, b.max.y).y };   // front face on screen, neutral (NDC)
  }

  setLayout(mode) {
    this.#o.layout = mode;
    if (mode === 'inspect' && !this.#controls) {
      this.#controls = new OrbitControls(this.#camera, this.#canvas);
      this.#controls.enablePan = false; this.#controls.enableDamping = true; this.#controls.addEventListener('change', () => (this.#dirty = true));
    }
    if (this.#controls) this.#controls.enabled = mode === 'inspect';
    this.#frame(); this.#lookAt(this.#look.px, this.#look.py); this.#dirty = true;
  }

  // ------------------------------------------------------------------ public API (framework -> radio)
  getState() { return { ...this.state, channelName: this.#o.channelNames[this.state.channel] || '', frequency: this.#o.frequency(this.state.channel) }; }
  setChannelNames(map) { this.#o.channelNames = { ...map }; this.#redraw(); }
  setChannelRange(min, max) { this.#o.minChannel = min; this.#o.maxChannel = max; this.setChannel(this.state.channel, { silent: true }); }
  setSignal(n) { this.state.signal = Math.max(0, Math.min(4, n | 0)); this.#redraw(); }
  setBattery(n) { this.state.battery = Math.max(0, Math.min(4, n | 0)); this.#redraw(); }
  setReceiving(on, name = '') {
    this.state.rx = !!on && this.state.power; this.state.rxName = this.state.rx ? String(name || '') : '';
    if (this.state.rx && name) { this.#subKind = 'rx'; this.#subUntil = Infinity; } else if (this.#subKind === 'rx') { this.#subKind = 'freq'; this.#subUntil = 0; }
    this.#led(); this.#redraw();
  }
  togglePower() { this.setPower(!this.state.power); }
  setPower(on, { silent = false, instant = false } = {}) {
    on = !!on; if (on === this.state.power) return;
    this.state.power = on;
    if (!on) Object.assign(this.state, { tx: false, rx: false, rxName: '', light: false, speaker: false, entry: '' });
    if (on && !instant) { this.#mode = 'boot'; this.#modeUntil = performance.now() + 650; } else this.#mode = on ? 'main' : 'off';
    this.#applyPower();
    if (this.#hover === 'knob_volume') this.#emit('hover', { part: 'knob_volume', label: this.#labelFor('knob_volume') });
    if (!silent) { this.#sound(on ? 'on' : 'off'); this.#emit('power', { on }); this.#change(); }
  }
  setChannel(n, { silent = false } = {}) {
    const { minChannel: lo, maxChannel: hi } = this.#o; const span = hi - lo + 1;
    n = ((((Math.round(n) - lo) % span) + span) % span) + lo;
    const changed = n !== this.state.channel; let dlt = n - this.state.channel;
    if (dlt > span / 2) dlt -= span; else if (dlt < -span / 2) dlt += span;
    this.state.channel = n; this.state.entry = '';
    this.#knobTo('knob_channel', this.#knobAngle.knob_channel + dlt * (Math.PI * 2 / 16));   // up: front face moves right
    if (this.state.power && this.#subKind !== 'rx') { this.#subKind = 'freq'; this.#subUntil = 0; }
    this.#redraw();
    if (changed && !silent) { this.#sound('click'); this.#emit('channel', { channel: n, name: this.#o.channelNames[n] || '', frequency: this.#o.frequency(n) }); this.#change(); }
  }
  channelUp() { this.setChannel(this.state.channel + 1); }
  channelDown() { this.setChannel(this.state.channel - 1); }
  setVolume(v, { silent = false } = {}) {
    v = Math.max(0, Math.min(10, Math.round(v))); const changed = v !== this.state.volume; this.state.volume = v;
    this.#knobTo('knob_volume', this.#volAngle());
    if (this.state.power) { this.#subKind = 'vol'; this.#subUntil = performance.now() + 1600; }
    this.#redraw();
    if (changed && !silent) { this.#sound('vol'); this.#emit('volume', { volume: v }); this.#change(); }
  }
  /** Push-to-talk. Driven by the side button; a game keybind can call it too ({ silent: true } = no 'ptt' event back). */
  setTransmitting(on, { silent = false } = {}) {
    on = !!on && this.state.power; if (on === this.state.tx) return;
    this.state.tx = on; this.#press('btn_ptt', on); this.#led(); this.#redraw();
    this.#sound(on ? 'txon' : 'txoff');
    if (!silent) { this.#emit('ptt', { active: on, channel: this.state.channel }); this.#change(); }
  }
  setLight(on, { silent = false } = {}) {
    on = !!on && this.state.power; this.state.light = on; this.#lightUntil = on ? performance.now() + 8000 : 0;
    this.#applyPower(); if (!silent) { this.#emit('light', { on }); this.#change(); }
  }
  /** Loudspeaker, like a phone on speaker: while on, nearby players hear this radio (the framework does the audio).
   *  It is not louder for the owner. The top button toggles it; { silent: true } = no 'speaker' event, sound or message. */
  setSpeaker(on, { silent = false } = {}) {
    on = !!on && this.state.power; if (on === this.state.speaker) return;
    this.state.speaker = on; this.#lightSpeaker();
    if (!silent) {
      this.#msg = on ? 'SPK ON' : 'SPKOFF'; this.#modeUntil = performance.now() + 1300; this.#sound(on ? 'spkon' : 'spkoff');
      this.#emit('speaker', { on, channel: this.state.channel }); this.#change();
    }
    this.#redraw();
  }
  /** Screen position (client px) of a part's centre, e.g. to place a tooltip or drive tests: partScreenPosition('btn_ptt') */
  partScreenPosition(name) {
    const ob = this.#parts[name] || this.#root.getObjectByName(name); if (!ob) return null;
    this.#scene.updateMatrixWorld(true);
    const v = new THREE.Box3().setFromObject(ob).getCenter(new THREE.Vector3()).project(this.#camera);
    const r = this.#canvas.getBoundingClientRect();
    return { x: r.left + (v.x + 1) / 2 * r.width, y: r.top + (1 - v.y) / 2 * r.height };
  }
  /** whip (9 Oct 2026, a controller works the radio): press a part as a click does, with the same sounds
   *  (unlocked as a click unlocks them), the key moving and the same events. A knob's press is its click
   *  (the volume knob: power). press(part, false) lets go (the side bar: talking stops). */
  press(part, down = true) {
    if (!this.#parts[part]) return;
    if (down) this.#unlockAudio();
    if (part.startsWith('knob')) { if (down) this.#knobClick(part); return; }
    this.#activate(part, down);
  }
  /** whip (9 Oct 2026): turn a knob `steps` clicks (negative: down), as the scroll wheel does. */
  turn(part, steps) {
    if (!part.startsWith('knob') || !this.#parts[part]) return;
    this.#unlockAudio(); this.#knobStep(part, steps);
  }
  open() {
    this.#open = true; this.#dirty = true;
    this.#lookAt(this.#look.px, this.#look.py);       // whip: the pointer was not followed while put away
    this.#wake(); return new Promise((res) => setTimeout(res, 380));
  }
  close() { this.#open = false; this.#dirty = true; this.setTransmitting(false); return new Promise((res) => setTimeout(res, 380)); }
  /** whip (7 Oct 2026): the loop stops once the radio is put away and drawn blank (#loop); open() starts it again. */
  #wake() { if (!this.#raf && this.#tick) this.#raf = requestAnimationFrame(this.#tick); }
  dispose() {
    cancelAnimationFrame(this.#raf); this.#raf = 0; this.#ro?.disconnect(); this.#controls?.dispose();
    for (const [el, ev, fn, opt] of this.#listeners) el.removeEventListener(ev, fn, opt);
    // whip: the video memory too (geometry, materials, textures, the lighting), and the context itself,
    // rather than leaving them until the browser collects the canvas
    const seen = new Set(), free = (o) => { if (o && !seen.has(o)) { seen.add(o); o.dispose?.(); } };
    this.#scene?.traverse((ob) => {
      free(ob.geometry);
      for (const m of [].concat(ob.material || [])) {
        for (const v of Object.values(m)) if (v?.isTexture) free(v);
        free(m);
      }
    });
    free(this.#scene?.environment); free(this.#lcdTex);
    this.#renderer.dispose(); this.#renderer.forceContextLoss(); this.#audio?.close?.();
  }

  // ------------------------------------------------------------------ input (radio controls)
  #on(el, ev, fn, opt) { el.addEventListener(ev, fn, opt); this.#listeners.push([el, ev, fn, opt]); }
  #pick(e) { return this.#pickAt(e.clientX, e.clientY); }
  #pickAt(x, y) {
    const r = this.#canvas.getBoundingClientRect();
    if (x < r.left || x > r.right || y < r.top || y > r.bottom) return null;
    this.#ptr.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    this.#raycaster.setFromCamera(this.#ptr, this.#camera);
    const hit = this.#raycaster.intersectObjects(this.#pickables, false)[0];
    return hit ? hit.object.userData.part : null;
  }
  #bindInput() {
    const cv = this.#canvas;
    this.#on(window, 'pointermove', (e) => this.#lookAt(e.clientX, e.clientY), { passive: true });
    this.#on(document.documentElement, 'pointerleave', () => this.#lookAt(null, null));
    this.#on(cv, 'pointermove', (e) => {
      if (this.#down?.knob) return this.#dragKnob(e);
      this.#setHover(this.#pick(e));
    });
    this.#on(cv, 'pointerdown', (e) => {
      const part = this.#pick(e); if (!part) return;
      this.#unlockAudio(); e.preventDefault(); cv.setPointerCapture?.(e.pointerId);
      if (this.#controls) this.#controls.enabled = false;
      if (part.startsWith('knob')) { this.#down = { part, knob: true, x: e.clientX, y: e.clientY, acc: 0, moved: false }; return; }
      this.#down = { part }; this.#activate(part, true);
    });
    const up = (e) => {
      if (!this.#down) return;
      const d = this.#down; this.#down = null; this.#lookAt(this.#look.px, this.#look.py);
      if (this.#controls) this.#controls.enabled = this.#o.layout === 'inspect';
      if (d.knob) { if (!d.moved) this.#knobClick(d.part); return; }
      this.#activate(d.part, false);
    };
    this.#on(cv, 'pointerup', up); this.#on(cv, 'pointercancel', up);
    this.#on(cv, 'pointerleave', () => { if (!this.#down) this.#setHover(null); });
    this.#on(cv, 'wheel', (e) => {
      const part = this.#pick(e); if (!part?.startsWith('knob')) return;
      e.preventDefault(); this.#unlockAudio(); this.#knobStep(part, e.deltaY < 0 ? 1 : -1);
    }, { passive: false });
    if (this.#o.keyboard) {
      const map = { ArrowUp: 'key_up', ArrowDown: 'key_down', m: 'key_menu', Enter: 'key_hash', Backspace: 'key_star', l: 'btn_side', s: 'btn_speaker', ' ': 'btn_ptt' };
      this.#keydown = (e) => {
        if (e.target.closest?.('input, textarea, select')) return;
        if (e.key === 'p') { this.togglePower(); return; }
        if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { this.#unlockAudio(); this.setVolume(this.state.volume + (e.key === 'ArrowRight' ? 1 : -1)); e.preventDefault(); return; }
        const part = /^[0-9]$/.test(e.key) ? 'key_' + e.key : map[e.key]; if (!part || e.repeat) return;
        e.preventDefault(); this.#unlockAudio(); this.#activate(part, true);
      };
      this.#keyup = (e) => {
        const part = /^[0-9]$/.test(e.key) ? 'key_' + e.key : map[e.key]; if (!part) return;
        this.#activate(part, false);
      };
      this.#on(window, 'keydown', this.#keydown); this.#on(window, 'keyup', this.#keyup);
    }
  }
  #setHover(part) {
    if (part === this.#hover) return;
    if (this.#hover) this.#tint(this.#hover, false);
    this.#hover = part; if (part) this.#tint(part, true);
    this.#canvas.style.cursor = part ? 'pointer' : '';
    this.#emit('hover', { part, label: part ? this.#labelFor(part) : '' });
  }
  #labelFor(part) {
    if (part === 'knob_volume' && !this.state.power) return 'Power on (click)';
    return LABELS[part] || part;
  }
  /** Corner layout: the radio faces you flat. With the pointer past its left / right / top edge (measured against the
   *  flat pose, so the turn never chases the pointer) it turns that side toward you; moving back turns it flat again. */
  #lookAt(px, py) {
    const L = this.#look; L.px = px; L.py = py;
    if (this.#down || !this.#open) return;            // whip: put away, nothing to turn (open() catches up)
    let yaw = 0, pitch = 0;
    const f = this.#foot;
    if (px !== null && f && this.#o.look && this.#o.layout !== 'inspect') {
      const r = this.#canvas.getBoundingClientRect();
      const nx = ((px - r.left) / r.width) * 2 - 1, ny = 1 - ((py - r.top) / r.height) * 2;
      const u = (nx - f.xl) / (f.xr - f.xl);                              // 0 = left edge of the face, 1 = right edge
      const v = ((ny - f.yt) * r.height) / ((f.xr - f.xl) * r.width);     // above the top edge, in face widths
      const ss = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
      const zone = ss(-1.1, -0.75, u) * ss(2.1, 1.75, u) * ss(2.6, 2.2, v);
      yaw = (ss(0.10, -0.03, u) * 0.62 - ss(0.90, 1.03, u) * 0.42) * zone;
      pitch = ss(-0.07, 0.10, v) * 0.40 * zone;
    }
    if (yaw !== L.tYaw || pitch !== L.tPitch) { L.tYaw = yaw; L.tPitch = pitch; this.#dirty = true; }
  }
  #tint(part, on) {
    this.#parts[part]?.traverse((ob) => {
      const base = this.#mats.get(ob); if (!base) return;
      if (ob.material.emissiveMap) ob.material.emissiveIntensity = this.#keyGlow() + (on ? (this.state.power ? 0.6 : 0.25) : 0);
      else ob.material.emissive.copy(on ? new THREE.Color(0x24282e) : base.emissive);
    });
    this.#labels[part]?.material.color.setScalar(on ? 1.3 : 1);
    if (part === 'btn_speaker') this.#lightSpeaker(on);
    this.#dirty = true;
  }
  #lightSpeaker(hovered = this.#hover === 'btn_speaker') {
    const m = this.#parts.btn_speaker?.material; if (!m) return;
    if (this.state.speaker) m.emissive.setRGB(0.55, 1.0, 0.45).multiplyScalar(hovered ? 0.7 : 0.45);
    else m.emissive.set(hovered ? 0x24282e : 0x000000);
    this.#dirty = true;
  }
  #knobClick(part) { if (part === 'knob_volume') this.togglePower(); else this.#knobStep(part, 1); }
  #dragKnob(e) {
    const d = this.#down; const dx = e.clientX - d.x, dy = e.clientY - d.y; d.x = e.clientX; d.y = e.clientY;
    d.acc += dx - dy; if (Math.abs(d.acc) > 3) d.moved = true;
    while (Math.abs(d.acc) >= 18) { const s = Math.sign(d.acc); d.acc -= s * 18; this.#knobStep(d.part, s); }
  }
  #knobStep(part, s) { if (part === 'knob_volume') this.setVolume(this.state.volume + s); else this.setChannel(this.state.channel + s); }

  #activate(part, down) {             // a key / button pressed (down) or released
    if (part === 'btn_ptt') { if (down) this.#press(part, true); this.setTransmitting(down); if (!down) this.#press(part, false); return; }
    this.#press(part, down); if (!down) return;
    const st = this.state;
    if (!st.power) { this.#sound('dead'); this.#emit('key', { key: part, ignored: true }); return; }
    this.#sound('key'); this.#emit('key', { key: part });
    if (part === 'btn_side') return this.setLight(!st.light);
    if (part === 'btn_speaker') return this.setSpeaker(!st.speaker);
    if (part === 'key_up') return this.channelUp();
    if (part === 'key_down') return this.channelDown();
    if (part === 'key_menu') {
      st.beeps = !st.beeps; this.#msg = st.beeps ? 'BEEP' : 'QUIET'; this.#modeUntil = performance.now() + 1300;
      this.#emit('setting', { beeps: st.beeps }); this.#change(); return this.#redraw();
    }
    if (part === 'key_star') { st.entry = ''; this.#msg = ''; return this.#redraw(); }
    if (part === 'key_hash') {
      const n = parseInt(st.entry, 10);
      if (st.entry && n >= this.#o.minChannel && n <= this.#o.maxChannel) this.setChannel(n);
      else if (st.entry) { st.entry = ''; this.#msg = 'ERROR'; this.#modeUntil = performance.now() + 1100; this.#sound('err'); }
      return this.#redraw();
    }
    const m = /^key_(\d)$/.exec(part);
    if (m) { st.entry = (st.entry + m[1]).slice(-String(this.#o.maxChannel).length); this.#subUntil = 0; this.#redraw(); }
  }

  // ------------------------------------------------------------------ visuals
  #press(part, down) {
    const ob = this.#parts[part]; if (!ob) return;
    const rest = ob.userData.rest; const travel = PRESS[part] ?? PRESS.key;
    const to = rest.pos.clone();
    if (part.startsWith('key_')) to.z -= down ? travel : 0;                 // glTF: front is +Z
    else if (part === 'btn_ptt' || part === 'btn_side') to.x += down ? travel : 0;
    else if (part === 'btn_speaker') to.y -= down ? travel : 0;
    this.#tween(ob.position, to, down ? 45 : 90);
  }
  #knobTo(part, angle) {
    const ob = this.#parts[part]; if (!ob) return;
    this.#knobAngle[part] = angle; const rest = ob.userData.rest?.rot || ob.rotation;
    const target = new THREE.Euler(rest.x, rest.y + angle, rest.z);
    this.#tween(ob.rotation, target, 120);
  }
  #tween(obj, to, ms) {
    this.#anim = this.#anim.filter((a) => a.obj !== obj);
    const from = obj.clone();
    this.#anim.push({ obj, from, to, t0: performance.now(), ms }); this.#dirty = true;
  }
  #volAngle() { return -2.3 + (this.state.volume / 10) * 4.6 - (this.state.power ? 0 : 0.35); }   // louder: front face moves right
  #keyGlow() { return this.state.power ? (this.state.light ? 1.1 : 0.42) : 0; }
  #applyPower() {
    const st = this.state;
    this.#keyMat.emissiveIntensity = this.#keyGlow();
    for (const [ob] of this.#mats) if (ob.material.emissiveMap) ob.material.emissiveIntensity = this.#keyGlow() + (this.#hover && ob.userData.part === this.#hover ? 0.6 : 0);
    this.#knobTo('knob_volume', this.#volAngle());
    this.#lightSpeaker(); this.#led(); this.#redraw();
  }
  #led() {
    const st = this.state; const m = this.#ledMat;
    let c = 0x000000;
    if (st.power) c = st.tx ? 0xff2a14 : st.rx ? 0x18ff5a : 0x000000;
    m.emissive.set(c); m.emissiveIntensity = c ? 3.0 : 0; this.#dirty = true;
  }
  #lcdView() {
    const st = this.state, o = this.#o, now = performance.now();
    if (this.#mode === 'boot' && now > this.#modeUntil) { this.#mode = 'splash'; this.#modeUntil = now + 750; }
    else if (this.#mode === 'splash' && now > this.#modeUntil) { this.#mode = 'main'; this.#sound('ready'); }
    if (!st.power) return { mode: 'off' };
    if (this.#mode === 'boot') return { mode: 'boot' };
    if (this.#mode === 'splash') return { mode: 'splash', big: o.bootLogo, boost: st.light };
    if (st.light && now > this.#lightUntil) { st.light = false; this.#applyPower(); this.#emit('light', { on: false }); }
    if (this.#subUntil && now > this.#subUntil && this.#subKind !== 'rx') { this.#subKind = 'freq'; this.#subUntil = 0; }
    let big = (o.channelNames[st.channel] || ('CH-' + String(st.channel).padStart(2, '0'))).toUpperCase();
    let sub = this.#o.frequency(st.channel), subKind = this.#subKind;
    if (st.entry) { big = 'CH-' + st.entry + (this.#blink ? '_' : ' '); subKind = 'entry'; sub = 'ENTER'; }
    else if (this.#msg && now < this.#modeUntil) big = this.#msg;
    else this.#msg = '';
    if (subKind === 'rx') sub = (st.rxName || 'RX').toUpperCase().slice(0, 10);
    if (subKind === 'vol') sub = '';
    return { mode: 'main', boost: st.light, big, sub, subKind, tx: st.tx, rx: st.rx, scan: false, signal: st.rx ? Math.max(1, st.signal) : st.signal,
             battery: st.battery, vol: st.volume, blink: this.#blink, spk: st.speaker };
  }
  #redraw() { this.#lcdDirty = true; this.#dirty = true; }
  #lcdDirty = true;

  #loop(now) {
    this.#raf = requestAnimationFrame(this.#tick);
    const blink = Math.floor(now / 380) % 2 === 0;
    if (blink !== this.#blink) {
      this.#blink = blink;
      const st = this.state;
      if (st.power && (st.entry || st.tx || this.#mode !== 'main' || this.#subUntil || st.light || this.#msg)) this.#redraw();
    }
    let animating = false;
    for (const a of this.#anim) {
      const k = Math.min(1, (now - a.t0) / a.ms), e = 1 - Math.pow(1 - k, 3);
      if (a.obj.isVector3) a.obj.lerpVectors(a.from, a.to, e);
      else a.obj.set(a.from.x + (a.to.x - a.from.x) * e, a.from.y + (a.to.y - a.from.y) * e, a.from.z + (a.to.z - a.from.z) * e);
      if (k < 1) animating = true;
    }
    this.#anim = this.#anim.filter((a) => now - a.t0 < a.ms);
    // open / close slide
    const tgt = this.#open ? 1 : 0;
    if (this.#openT !== tgt) { this.#openT += Math.sign(tgt - this.#openT) * Math.min(Math.abs(tgt - this.#openT), 16 / 340); animating = true; }
    const ease = 1 - Math.pow(1 - this.#openT, 3);
    const idle = this.#o.idle && this.#o.layout !== 'inspect';
    const t = (now - this.#t0) / 1000;
    // look: ease toward the pointer-driven turn; the front edge on the turning side stays put, the side opens beside it
    const L = this.#look, dt = Math.min(0.05, (now - (L.t || now)) / 1000), k = 1 - Math.exp(-dt / 0.11); L.t = now;
    L.yaw += (L.tYaw - L.yaw) * k; L.pitch += (L.tPitch - L.pitch) * k;
    if (Math.abs(L.tYaw - L.yaw) + Math.abs(L.tPitch - L.pitch) > 2e-4) animating = true; else { L.yaw = L.tYaw; L.pitch = L.tPitch; }
    const pv = this.#pivot, b = this.#bodyBox;
    pv.rotation.set(L.pitch, L.yaw + (1 - ease) * 0.5 + (idle ? Math.sin(t * 0.55) * 0.02 : 0), idle ? Math.sin(t * 0.7) * 0.008 : 0, 'YXZ');
    this.#anchor.set(L.yaw >= 0 ? b.min.x : b.max.x, b.max.y, b.max.z);
    pv.position.copy(this.#anchor).sub(this.#turned.copy(this.#anchor).applyEuler(pv.rotation));
    pv.position.y += (1 - ease) * -0.32 + (idle ? Math.sin(t * 0.9) * 0.0012 : 0);
    // power hint: while off, the ⏻ under the volume knob breathes (on, it is backlit like the keys: #applyPower)
    const lab = this.#labels.knob_volume, hint = !!lab && this.#o.powerHint && !this.state.power;
    if (hint) { lab.material.emissive.setRGB(0.2, 1.0, 0.15); lab.material.emissiveIntensity = 0.4 + 2.4 * (0.5 + 0.5 * Math.sin(t * 3.2)); }
    else if (lab) lab.material.emissive.setRGB(0.55, 1.0, 0.45);             // on: backlit like the keys
    if (this.#halo) { this.#halo.visible = hint; if (hint) this.#halo.material.opacity = 0.15 + 0.85 * (0.5 + 0.5 * Math.sin(t * 3.2)); }
    if (this.#controls?.enabled) this.#controls.update();
    this.#pivot.visible = this.#openT > 0.001;
    if (!this.#pivot.visible) {
      if (!this.#closedDrawn) { this.#renderer.render(this.#scene, this.#camera); if (this.#ctx2d) this.#ctx2d.clearRect(0, 0, this.#canvas.width, this.#canvas.height); this.#closedDrawn = true; }
      // whip (7 Oct 2026): put away and drawn blank, the loop stops — it ran every frame for good, with
      // nothing to draw (60 a second measured). open() wakes it; state set meanwhile is drawn then.
      cancelAnimationFrame(this.#raf); this.#raf = 0;
      return;
    }
    this.#closedDrawn = false;
    const idleFrame = (idle || hint) && now - this.#last > 33;
    if (!(this.#dirty || animating || idleFrame)) return;
    if (this.#lcdDirty) { drawLCD(this.#lcdCanvas, this.#lcdView()); this.#lcdTex.needsUpdate = true; this.#lcdDirty = this.#mode === 'boot' || this.#mode === 'splash'; }
    this.#screenMat.color.setScalar(this.state.power ? 1 : 0.8);
    this.#renderer.render(this.#scene, this.#camera);
    if (this.#ctx2d) { const c = this.#canvas; this.#ctx2d.clearRect(0, 0, c.width, c.height); if (this.#openT > 0.001) this.#ctx2d.drawImage(this.#gl, 0, 0); }
    this.#last = now; this.#dirty = false;
    if (animating && L.px !== null && !this.#down) this.#setHover(this.#pickAt(L.px, L.py));   // parts moved under the pointer
  }

  // ------------------------------------------------------------------ sound (WebAudio, after the first click)
  #unlockAudio() {
    if (!this.#o.sounds || this.#audio) return;
    try { this.#audio = new (window.AudioContext || window.webkitAudioContext)(); } catch { this.#audio = null; }
  }
  #beep(f, dur, at = 0, gain = 0.06, type = 'square') {
    const a = this.#audio; if (!a) return;
    const t = a.currentTime + at, o = a.createOscillator(), g = a.createGain(), lp = a.createBiquadFilter();
    lp.type = 'lowpass'; lp.frequency.value = 3200;
    o.type = type; o.frequency.setValueAtTime(f, t);
    const v = gain * Math.max(0.15, this.state.volume / 10);
    // (2026-10-09) the hold point never before the attack: a tick shorter than 10 ms at audio time 0 (a context that
    // has not started yet, e.g. gamepad input with no click) gave a negative time and threw, breaking the control
    const hold = Math.max(t + 0.005, t + dur - 0.01), end = Math.max(hold + 0.002, t + dur);
    try {
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v, t + 0.004); g.gain.setValueAtTime(v, hold); g.gain.linearRampToValueAtTime(0, end);
      o.connect(lp).connect(g).connect(a.destination); o.start(t); o.stop(end + 0.02);
    } catch { /* a sound must never break a control */ }
  }
  #sound(kind) {
    const st = this.state; if (!this.#audio || !this.#o.sounds) return;
    const beeps = st.beeps && st.volume > 0;
    switch (kind) {
      case 'on': this.#beep(880, 0.07); this.#beep(1320, 0.09, 0.09); break;
      case 'off': this.#beep(990, 0.06); this.#beep(560, 0.09, 0.08); break;
      case 'ready': if (beeps) this.#beep(1760, 0.05, 0, 0.04); break;
      case 'key': if (beeps) this.#beep(1650, 0.035, 0, 0.045); break;
      case 'dead': this.#beep(180, 0.02, 0, 0.05, 'triangle'); break;
      case 'click': this.#beep(2600, 0.008, 0, 0.05, 'triangle'); if (st.power && beeps) this.#beep(1500, 0.03, 0.01, 0.03); break;
      case 'vol': if (st.power) this.#beep(1200, 0.04, 0, 0.05); break;
      case 'txon': if (beeps) this.#beep(1250, 0.05, 0, 0.05); break;
      case 'txoff': if (beeps) { this.#beep(1900, 0.06, 0, 0.05); this.#beep(1450, 0.06, 0.07, 0.05); } break;
      case 'err': this.#beep(420, 0.18, 0, 0.06); break;
      case 'spkon': this.#beep(900, 0.05, 0, 0.05); this.#beep(1350, 0.07, 0.06, 0.05); break;
      case 'spkoff': this.#beep(1350, 0.05, 0, 0.05); this.#beep(900, 0.07, 0.06, 0.05); break;
    }
  }

  #emit(type, detail) { this.dispatchEvent(new CustomEvent(type, { detail })); }
  #change() { this.#emit('change', this.getState()); }
}
