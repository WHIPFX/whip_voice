// THE BUILT-IN VOICE SERVER'S SIGNALLING, through the game.
//
// A player's game only opens SECURE connections from this page (wss://, with a certificate), and the built-in voice
// server has no certificate. So the LiveKit client's connection to it is not a real one: the server gives this page
// the address wss://whip-voice.invalid (server/builtin.lua), and a WebSocket opened to it is this stand-in. It hands
// each message to the game (client/main.lua, NUI 'sig'), which passes it to the FiveM server (server/builtin.js), which
// passes it to the voice server on its own machine; the answers come back the same way (NUI message 'sig'). Only this
// signalling goes that way, a few messages a second at most. The VOICES go straight to the voice server over UDP.
//
// Every other WebSocket is the browser's own. Loaded before voice.js.

'use strict';

(() => {
    const HOST = 'whip-voice.invalid';     // server/builtin.lua VoiceBuiltin.URL
    const CHUNK = 12000;                   // base64 characters per piece: server/builtin.lua's SecureEvent takes this many
    const OPEN_TIMEOUT_MS = 15000;
    const CLOSE_TIMEOUT_MS = 2000;
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'whip_voice';
    const Real = window.WebSocket;

    // ---- To the game: in order, batched (one request in flight; what comes meanwhile goes in the next) ----------
    let queue = [];
    let sending = false;
    function flush() {
        if (sending || queue.length === 0) return;
        sending = true;
        const items = queue;
        queue = [];
        fetch('https://' + RES + '/sig', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ items }),
        }).catch(() => {
            // The game never took them (its script restarting): their connections cannot go on with a gap in them.
            for (const it of items) { const s = sockets.get(it[0]); if (s) s._ended(1006, 'the voice relay lost a message', false); }
        }).finally(() => { sending = false; flush(); });
    }

    // ---- base64 -------------------------------------------------------------------------------------------------
    function bytesOf(d) {
        if (d instanceof ArrayBuffer) return new Uint8Array(d);
        if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
        if (typeof d === 'string') return new TextEncoder().encode(d);
        throw new TypeError('the voice relay sends bytes or text only');   // (text as its bytes: LiveKit's is binary)
    }
    function toB64(u8) {
        let s = '';
        for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        return btoa(s);
    }
    function fromB64(s) {
        const bin = atob(s);
        const u8 = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
        return u8.buffer;
    }

    // ---- The stand-in ---------------------------------------------------------------------------------------------
    const sockets = new Map();                         // sock -> RelaySocket
    let nextSock = 1 + Math.floor(Math.random() * 1e6); // a page that reloads does not reuse its last numbers

    class RelaySocket extends EventTarget {
        constructor(url) {
            super();
            this.url = url;
            this.readyState = 0;
            this.binaryType = 'blob';
            this.protocol = '';
            this.extensions = '';
            this.bufferedAmount = 0;
            this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
            this._sock = nextSock++;
            this._seq = 0;             // each piece to the server one up from the last: it notices one gone missing
            this._parts = [];
            sockets.set(this._sock, this);
            const u = new URL(url);
            this._out('open', u.pathname + u.search);
            this._timer = setTimeout(() => this._ended(1006, 'the voice server did not answer', false), OPEN_TIMEOUT_MS);
        }

        _out(op, data) {
            queue.push([this._sock, op, data || '', ++this._seq]);
            flush();
        }

        _fire(ev) {
            this.dispatchEvent(ev);
            const h = this['on' + ev.type];
            if (typeof h === 'function') { try { h.call(this, ev); } catch (e) { console.error(e); } }
        }

        send(data) {
            if (this.readyState === 0) throw new DOMException('Still in CONNECTING state.', 'InvalidStateError');
            if (this.readyState !== 1) return;      // closing or closed: dropped, as a browser's would be
            const b64 = toB64(bytesOf(data));
            if (b64.length === 0) { this._out('data', ''); return; }
            for (let i = 0; i < b64.length; i += CHUNK) this._out(i + CHUNK >= b64.length ? 'data' : 'more', b64.slice(i, i + CHUNK));
        }

        close(code, reason) {
            if (this.readyState >= 2) return;
            const wasOpen = this.readyState === 1;
            this.readyState = 2;
            this._out('close', '');
            clearTimeout(this._timer);
            // The server answers with its own close; if it never does, closed anyway.
            this._timer = setTimeout(() => this._ended(code || 1000, reason || '', wasOpen), CLOSE_TIMEOUT_MS);
        }

        /** From the server, through the game. */
        _take(op, data) {
            if (op === 'open') {
                if (this.readyState !== 0) return;
                clearTimeout(this._timer);
                this.readyState = 1;
                this._fire(new Event('open'));
            } else if (op === 'more') {
                this._parts.push(data);
            } else if (op === 'data') {
                this._parts.push(data);
                const joined = this._parts.join('');
                this._parts = [];
                if (this.readyState !== 1) return;
                const buf = fromB64(joined);
                this._fire(new MessageEvent('message', { data: this.binaryType === 'arraybuffer' ? buf : new Blob([buf]) }));
            } else if (op === 'close') {
                let c = {};
                try { c = JSON.parse(data || '{}'); } catch (_) { /* none */ }
                const code = Number(c.code) || 1006;
                this._ended(code, String(c.reason || ''), code === 1000);
            }
        }

        _ended(code, reason, clean) {
            if (this.readyState === 3) return;
            clearTimeout(this._timer);
            const failed = this.readyState === 0 || !clean;
            this.readyState = 3;
            sockets.delete(this._sock);
            if (failed) this._fire(new Event('error'));
            this._fire(new CloseEvent('close', { code, reason, wasClean: clean }));
        }
    }
    for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) RelaySocket[k] = Real[k];
    for (const [i, k] of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].entries()) RelaySocket.prototype[k] = i;

    // ---- Every WebSocket: the stand-in for the built-in voice server's address, the browser's own for the rest ----
    function WebSocket(url, protocols) {
        let host = '';
        try { host = new URL(String(url)).hostname; } catch (_) { /* the real one says what is wrong */ }
        if (host === HOST) return new RelaySocket(String(url));
        return protocols === undefined ? new Real(url) : new Real(url, protocols);
    }
    for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) WebSocket[k] = Real[k];
    WebSocket.prototype = Real.prototype;
    window.WebSocket = WebSocket;

    window.addEventListener('message', (event) => {
        const m = event.data;
        if (!m || m.action !== 'sig') return;
        const s = sockets.get(Number(m.sock));
        if (s) s._take(String(m.op), typeof m.data === 'string' ? m.data : '');
    });
})();
