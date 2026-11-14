// ============================================
// whip_voice — the built-in voice server (server side)
// ============================================
//
// With no whip_voice_url in server.cfg, whip_voice runs its own voice server, on this machine, with nothing to set up:
//
//   1. LIVEKIT, the voice server. Downloaded once into whip_voice/bin (the official release, checked against its
//      published checksum), started with this FiveM server and stopped with it, with new random keys every start. The
//      keys go to the Lua side by event and are never written to disk.
//   2. THE SIGNALLING RELAY. A player's game only opens SECURE connections (wss://, a certificate), and a certificate
//      is what made a voice server hard to set up. So players' games never connect to LiveKit's signalling port: the
//      voice page (html/js/relay.js) hands each signalling message to the game, the game to this server
//      (server/builtin.lua, a SecureEvent), and this file passes it to LiveKit on 127.0.0.1, and the answers back the
//      same way. Only the AUDIO goes from each game to LiveKit directly, over UDP 7882-7893 (TCP 7881 when UDP is
//      blocked): those are the ports to open, like 30120.
//   3. THE VOICE BOT (lore characters phoning players, server/bots.lua): its own Node.js and the bot
//      (service/voicebot), set up into bin in the background and started like LiveKit. Voice does not wait for it.
//
// In JavaScript because it starts programs and holds sockets, which FiveM's Lua cannot. It talks to the Lua side
// (server/builtin.lua) by local events only:
//
//   whip_voice:builtin:start  { bot }                    Lua -> here: start (asked again: says how it stands)
//   whip_voice:builtin:state  { phase, why, ... }        here -> Lua: how it stands; the keys once LiveKit has run
//   whip_voice:relay:fromGame (src, sock, op, data)      Lua -> here: a piece of a player's signalling
//
// and to players' games: whip_voice:client:sig (sock, op, data), read by client/main.lua.
//
// server.cfg, all optional (see docs/SETUP.md):
//   whip_voice_udp     the UDP ports for voices          (default 7882-7893)
//   whip_voice_tcp     the TCP port when UDP is blocked  (default 7881)
//   whip_voice_ip      the public IPv4 players' games send voices to (default: found by asking the internet)
//   whip_voice_api     where LiveKit's signalling and API listen, on this machine (default http://127.0.0.1:7880)
//   whip_voice_bot     false: no voice bot (lore characters cannot phone players)
//   whip_voicebot_url  where the voice bot listens, on this machine (default http://127.0.0.1:7899)

'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

const RESOURCE = GetCurrentResourceName();
const HERE = path.resolve(GetResourcePath(RESOURCE));
const BIN = path.join(HERE, 'bin');
const LOGS = path.join(BIN, 'logs');
const WIN = process.platform === 'win32';
const EXE = WIN ? '.exe' : '';
const PLATFORM = `${process.platform}-${process.arch}`;
const SYSTEM32 = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32');

// ---- Pinned downloads: change a version, its files and their checksums together ----------------------------------
// (SHA-256 from the release's own checksums.txt / SHASUMS256.txt.)
const LIVEKIT_VERSION = '1.13.7';
const LIVEKIT_FILES = {
    'win32-x64': { file: `livekit_${LIVEKIT_VERSION}_windows_amd64.zip`, sha256: 'e539e7d2f75807b9c9202cd2a0bf2cb3d52fc4c52978a6953e0f47bc339fe77f' },
    'linux-x64': { file: `livekit_${LIVEKIT_VERSION}_linux_amd64.tar.gz`, sha256: '6634aeeb2fb1366b6723708ae4320b9d5408106a4c63457c5e845ae3979c90e2' },
};
const NODE_VERSION = '22.19.0';
const NODE_FILES = {
    'win32-x64': { file: `node-v${NODE_VERSION}-win-x64.zip`, dir: `node-v${NODE_VERSION}-win-x64`, sha256: 'ea3fad0e67a991d8477d8c01344b56e69c676ccb733f065b22436994b1253f86' },
    'linux-x64': { file: `node-v${NODE_VERSION}-linux-x64.tar.gz`, dir: `node-v${NODE_VERSION}-linux-x64`, sha256: 'd36e56998220085782c0ca965f9d51b7726335aed2f5fc7321c6c0ad233aa96d' },
};

const LK_DIR = path.join(BIN, 'livekit');
const LK_EXE = path.join(LK_DIR, 'livekit-server' + EXE);   // one path for every version: Windows' firewall answers stay
const LK_PID = path.join(BIN, 'livekit.pid');
const NODE_DIR = path.join(BIN, 'node');
const NODE_EXE = WIN ? path.join(NODE_DIR, 'node.exe') : path.join(NODE_DIR, 'bin', 'node');
const NPM_CLI = WIN ? path.join(NODE_DIR, 'node_modules', 'npm', 'bin', 'npm-cli.js')
    : path.join(NODE_DIR, 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js');
const BOT_SRC = path.join(HERE, 'service', 'voicebot');
const BOT_DIR = path.join(BIN, 'voicebot');
const BOT_APP = path.join(BOT_DIR, 'app');
const BOT_CONFIG = path.join(BOT_DIR, 'config.json');
const BOT_PID = path.join(BIN, 'voicebot.pid');

const say = (line) => console.log(`[whip_voice] ${line}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ============================================
// How it stands, told to the Lua side
// ============================================

const state = {
    phase: 'off',        // off, starting, downloading, ready, restarting, failed
    why: null,           // in words, while not ready
    gen: 0,              // +1 each time LiveKit (re)starts and answers: the Lua side opens a fresh room
    version: LIVEKIT_VERSION,
    api: null, key: null, secret: null, udp: null, tcp: null, ip: null,
    firewall: null,      // Windows: { on, open, blocked, ... } (service/firewall.ps1)
    firewallN: 0,        // +1 each time it was read on request (/voicecheck waits for it)
    bot: { phase: 'off', why: null, url: null, token: null },
};

function publish() {
    emit('whip_voice:builtin:state', {
        phase: state.phase, why: state.why, gen: state.gen, version: state.version, api: state.api, key: state.key,
        secret: state.secret, udp: state.udp, tcp: state.tcp, ip: state.ip, firewall: state.firewall,
        firewallN: state.firewallN, bot: { ...state.bot },
    });
}

function setPhase(phase, why) {
    state.phase = phase;
    state.why = why || null;
    publish();
}

function setBot(phase, why, extra) {
    state.bot = { phase, why: why || null, url: null, token: null, ...(extra || {}) };
    publish();
}

// ============================================
// Settings (server.cfg)
// ============================================

function settings() {
    const api = GetConvar('whip_voice_api', 'http://127.0.0.1:7880').replace(/\/+$/, '');
    const am = /^http:\/\/(?:127\.0\.0\.1|localhost):(\d{1,5})$/.exec(api);
    if (!am) throw new Error(`whip_voice_api is "${api}": the built-in voice server needs http://127.0.0.1:<port> (or no whip_voice_api at all)`);
    const udp = GetConvar('whip_voice_udp', '7882-7893').trim();
    if (!/^\d{1,5}(-\d{1,5})?$/.test(udp)) throw new Error(`whip_voice_udp is "${udp}": a port (7882) or a range (7882-7893)`);
    const tcp = Number(GetConvar('whip_voice_tcp', '7881'));
    if (!Number.isInteger(tcp) || tcp < 1 || tcp > 65535) throw new Error('whip_voice_tcp must be a port number (7881)');
    const ip = GetConvar('whip_voice_ip', '').trim();
    if (ip && !/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) throw new Error(`whip_voice_ip is "${ip}": an IPv4 address, or leave it out`);
    const botUrl = GetConvar('whip_voicebot_url', 'http://127.0.0.1:7899').replace(/\/+$/, '');
    const bm = /^http:\/\/(?:127\.0\.0\.1|localhost):(\d{1,5})$/.exec(botUrl);
    if (!bm) throw new Error(`whip_voicebot_url is "${botUrl}": the built-in voice bot needs http://127.0.0.1:<port>`);
    return {
        apiPort: Number(am[1]), api: `http://127.0.0.1:${am[1]}`, udp, tcp, ip,
        bot: GetConvar('whip_voice_bot', 'true').toLowerCase() !== 'false', botPort: Number(bm[1]),
    };
}

// ============================================
// Small tools: files, programs, downloads
// ============================================

function readText(file) {
    try { return fs.readFileSync(file, 'utf8').trim(); } catch (_) { return ''; }
}

function exists(file) {
    try { fs.accessSync(file); return true; } catch (_) { return false; }
}

async function freshDir(dir) {
    await fsp.rm(dir, { recursive: true, force: true });
    await fsp.mkdir(dir, { recursive: true });
    return dir;
}

/** Run a program to its end: { code, out } (stdout and stderr together, the last 64 KB). */
function run(exe, args, opts) {
    return new Promise((resolve) => {
        let out = '';
        let child;
        try {
            child = spawn(exe, args, { windowsHide: true, ...(opts || {}) });
        } catch (e) {
            resolve({ code: -1, out: String(e && e.message || e) });
            return;
        }
        const take = (d) => { out = (out + d.toString()).slice(-65536); };
        if (child.stdout) child.stdout.on('data', take);
        if (child.stderr) child.stderr.on('data', take);
        child.on('error', (e) => resolve({ code: -1, out: out + String(e && e.message || e) }));
        child.on('close', (code) => resolve({ code: code === null ? -1 : code, out }));
    });
}

/** Download `url` to `dest`, refusing it unless its SHA-256 is `sha256`. */
async function download(url, sha256, dest) {
    const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(10 * 60 * 1000) });
    if (!res.ok) throw new Error(`${url} answered ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    const got = crypto.createHash('sha256').update(buf).digest('hex');
    if (got !== sha256) throw new Error(`${path.basename(url)} does not match its published checksum, so it was not used`);
    await fsp.writeFile(dest, buf);
}

/** Unpack a .zip (Windows' own tar reads them) or a .tar.gz into `dir`. */
async function unpack(archive, dir) {
    const tar = WIN ? path.join(SYSTEM32, 'tar.exe') : 'tar';
    const r = await run(tar, ['-xf', archive, '-C', dir]);
    if (r.code !== 0) throw new Error(`could not unpack ${path.basename(archive)}: ${r.out.trim().slice(-300)}`);
}

/** The full path of a running process's program, or null. */
async function programOf(pid) {
    if (WIN) {
        const r = await run(path.join(SYSTEM32, 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
            ['-NoProfile', '-NonInteractive', '-Command', `(Get-Process -Id ${pid} -ErrorAction SilentlyContinue).Path`]);
        return r.out.trim() || null;
    }
    try { return await fsp.readlink(`/proc/${pid}/exe`); } catch (_) { return null; }
}

function alive(pid) {
    try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

/** A program of ours an earlier start left running (the FiveM server was killed, not stopped): stopped, so its ports
 *  and files are free. Only when the pid file's process really is that program. */
async function stopLeftover(pidFile, program) {
    const pid = parseInt(readText(pidFile), 10);
    if (pid > 0 && alive(pid)) {
        const p = await programOf(pid);
        if (p && path.resolve(p).toLowerCase() === path.resolve(program).toLowerCase()) {
            try { process.kill(pid); } catch (_) { /* gone */ }
            for (let i = 0; i < 25 && alive(pid); i++) await sleep(200);
            say(`stopped ${path.basename(program)} left running by an earlier start (pid ${pid})`);
        }
    }
    await fsp.rm(pidFile, { force: true });
}

/** A log file in bin/logs, started afresh when it passed 10 MB (the old one kept as .old). */
function logFile(name) {
    fs.mkdirSync(LOGS, { recursive: true });
    const file = path.join(LOGS, name);
    try {
        if (fs.statSync(file).size > 10 * 1024 * 1024) fs.renameSync(file, file + '.old');
    } catch (_) { /* none yet */ }
    return fs.createWriteStream(file, { flags: 'a' });
}

/** Each whole line a stream writes, to `fn`. */
function eachLine(stream, fn) {
    let rest = '';
    stream.on('data', (d) => {
        const lines = (rest + d.toString()).split(/\r?\n/);
        rest = lines.pop();
        for (const l of lines) fn(l);
    });
}

const randomHex = (bytes) => crypto.randomBytes(bytes).toString('hex');

// FXServer lets a resource's JavaScript start programs only when server.cfg allows that resource, and LiveKit, the voice
// bot, Windows' tar and PowerShell are all programs. The one line it takes, and why, in words for the console.
const PERMISSION_LINE = `add_unsafe_child_process_permission ${RESOURCE}`;
const NO_PERMISSION = `FXServer lets a resource start programs only when server.cfg allows it, and the voice server is a program. `
    + `Add this line to server.cfg, above "ensure ${RESOURCE}", then restart the server:  ${PERMISSION_LINE}  `
    + '(Or use a voice server of your own: whip_voice/docs/SETUP.md)';

const deniedSpawn = (e) => !!e && (e.code === 'ERR_ACCESS_DENIED' || /allow-child-process|API has been restricted/i.test(String(e.message)));

/** May this resource start programs? (A program that does nothing, started to find out.) */
function spawnAllowed() {
    try {
        const c = spawn(WIN ? path.join(SYSTEM32, 'cmd.exe') : '/bin/sh', WIN ? ['/c', 'exit'] : ['-c', 'exit 0'],
            { windowsHide: true, stdio: 'ignore' });
        c.on('error', () => { /* not found or the like: the real start says */ });
        return true;
    } catch (e) {
        return !deniedSpawn(e);
    }
}

// ============================================
// A program kept running: started, restarted when it stops by itself, stopped with the resource
// ============================================

const BACKOFF_S = [2, 5, 10, 30, 60];

class Kept {
    /**
     * @param {object} o  name, exe, args, env, cwd, log (file name), pidFile, onLine(line), ready() -> Promise<bool>,
     *                    onReady(), onDown(why), onGiveUp(why)
     */
    constructor(o) {
        this.o = o;
        this.child = null;
        this.stopping = false;
        this.fails = 0;
        this.tail = [];            // the last lines it printed, for saying why it stopped
    }

    async start() {
        if (this.stopping) return;
        const o = this.o;
        const log = logFile(o.log);
        log.on('error', () => { /* a log that cannot be written never stops the program */ });
        log.write(`\n---- ${new Date().toISOString()} starting ${o.name}\n`);
        let child;
        try {
            child = spawn(o.exe, o.args || [], { cwd: o.cwd, env: o.env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
        } catch (e) {
            if (deniedSpawn(e)) { this.fails = BACKOFF_S.length; this.down(NO_PERMISSION); return; }   // no use trying again
            this.down(`${o.name} could not start: ${e && e.message || e}`);
            return;
        }
        this.child = child;
        this.tail = [];
        const startedAt = Date.now();
        const line = (l) => {
            log.write(l + '\n');
            if (!l.trim()) return;
            this.tail.push(l);
            if (this.tail.length > 30) this.tail.shift();
            if (o.onLine) o.onLine(l);
        };
        eachLine(child.stdout, line);
        eachLine(child.stderr, line);
        child.on('error', (e) => line(`(${o.name}: ${e && e.message || e})`));
        // 'close': it has exited AND everything it printed has been read.
        child.on('close', (code) => {
            log.end(`---- ${new Date().toISOString()} ${o.name} stopped (exit ${code})\n`);
            if (this.child !== child) return;         // stopped on purpose, or given up on as it never answered
            this.child = null;
            fs.rm(o.pidFile, { force: true }, () => {});
            if (this.stopping) return;
            if (Date.now() - startedAt > 120000) this.fails = 0;     // ran a good while: start counting again
            this.down(`${o.name} stopped (exit ${code})${this.reason() ? ': ' + this.reason() : ''}`);
        });
        if (child.pid) fs.writeFile(o.pidFile, String(child.pid), () => {});

        if (await o.ready(child)) {
            if (this.child !== child) return;
            o.onReady();
        } else if (this.child === child) {
            const why = `${o.name} did not answer${this.reason() ? ': ' + this.reason() : ''}`;
            this.child = null;                        // this one goes; down() decides whether another starts
            try { child.kill(); } catch (_) { /* gone */ }
            this.down(why);
        }
    }

    /** It stopped, or never answered: try again after a while, or give up after five tries in a row. */
    down(why) {
        if (this.stopping) return;
        this.fails += 1;
        if (this.fails > BACKOFF_S.length) {
            this.o.onGiveUp(why);
            return;
        }
        const wait = BACKOFF_S[this.fails - 1];
        this.o.onDown(`${why} (starting it again in ${wait} s)`);
        setTimeout(() => this.start(), wait * 1000);
    }

    /** The most telling line it printed: a FATAL or ERROR line, else its last. */
    reason() {
        const bad = this.tail.filter((l) => /\b(FATAL|ERROR|error|Error)\b/.test(l) && !NOISE.test(l));
        const l = (bad.length ? bad[bad.length - 1] : this.tail[this.tail.length - 1]) || '';
        return l.replace(/^\S+\t\S+\t\S+\t\S+\t/, '').trim().slice(0, 300);
    }

    stop() {
        this.stopping = true;
        const child = this.child;
        this.child = null;
        if (child) { try { child.kill(); } catch (_) { /* gone */ } }
        fs.rm(this.o.pidFile, { force: true }, () => {});
    }
}

// LiveKit lines never worth a server owner's attention: Windows has no CPU monitor (it says so with a stack trace), and
// a participant leaving cuts its data channels short (three warnings each time a player or the voice bot leaves).
const NOISE = /CPU monitoring unsupported|cpu_null\.go|error reading data channel/;

// ============================================
// LiveKit
// ============================================

async function ensureLiveKit() {
    if (readText(path.join(LK_DIR, 'version.txt')) === LIVEKIT_VERSION && exists(LK_EXE)) return;
    const asset = LIVEKIT_FILES[PLATFORM];
    setPhase('downloading', `downloading LiveKit ${LIVEKIT_VERSION}`);
    say(`built-in voice server: downloading LiveKit ${LIVEKIT_VERSION}, the voice server (once, about 20 MB)...`);
    const tmp = await freshDir(path.join(BIN, 'tmp', 'livekit'));
    const archive = path.join(tmp, asset.file);
    await download(`https://github.com/livekit/livekit/releases/download/v${LIVEKIT_VERSION}/${asset.file}`, asset.sha256, archive);
    const out = await freshDir(path.join(tmp, 'x'));
    await unpack(archive, out);
    const exe = path.join(out, 'livekit-server' + EXE);
    if (!exists(exe)) throw new Error(`${asset.file} has no livekit-server${EXE} in it`);
    await fsp.mkdir(LK_DIR, { recursive: true });
    await fsp.copyFile(exe, LK_EXE);
    if (!WIN) await fsp.chmod(LK_EXE, 0o755);
    if (exists(path.join(out, 'LICENSE'))) await fsp.copyFile(path.join(out, 'LICENSE'), path.join(LK_DIR, 'LICENSE'));
    await fsp.writeFile(path.join(LK_DIR, 'version.txt'), LIVEKIT_VERSION);
    await fsp.rm(tmp, { recursive: true, force: true });
    say(`built-in voice server: LiveKit ${LIVEKIT_VERSION} downloaded (it matches the official release)`);
}

/** LiveKit's settings (LIVEKIT_CONFIG): signalling and its API on this machine only; voices on the UDP ports. */
function liveKitConfig(s) {
    const lines = [
        `port: ${s.apiPort}`,
        'bind_addresses:',
        '  - 127.0.0.1',
        'rtc:',
        `  udp_port: ${s.udp}`,
        `  tcp_port: ${s.tcp}`,
    ];
    // The address players' games send their voices to: the one given, else found by asking the internet (STUN), and
    // used as found. LiveKit would otherwise first check it by sending itself a packet through it, which fails while
    // the ports are still shut (the host's firewall, Windows asking about it on the first start), and then it offers
    // only the machine's own addresses until it is restarted. 127.0.0.1 is offered too: a game or the voice bot on this
    // machine always connects.
    if (s.ip) lines.push(`  node_ip: ${s.ip}`, '  use_external_ip: false');
    else lines.push('  use_external_ip: true', '  skip_external_ip_validation: true');
    lines.push('  enable_loopback_candidate: true');
    lines.push(
        'room:',
        '  auto_create: false',          // only this FiveM server makes rooms
        '  empty_timeout: 300',
        '  departure_timeout: 20',
        'logging:',
        '  level: info',
    );
    return lines.join('\n') + '\n';
}

/** Something already answers where LiveKit would listen? (The setup wizard's LiveKit service, say.) */
async function answering(port) {
    try {
        const r = await fetch(`http://127.0.0.1:${port}/`, { signal: AbortSignal.timeout(1500) });
        return r.status > 0;
    } catch (_) { return false; }
}

let liveKit = null;
let echoed = [];   // when LiveKit lines were last echoed to the console (at most 10 a minute)

function echoLiveKit(l) {
    const m = /^\S+\t(WARN|ERROR|FATAL|DPANIC|PANIC)\t\S+\t\S+\t(.*)$/.exec(l);
    if (!m || NOISE.test(l)) return;
    const now = Date.now();
    echoed = echoed.filter((t) => now - t < 60000);
    if (echoed.length >= 10) return;
    echoed.push(now);
    say(`voice server ${m[1].toLowerCase()}: ${m[2].slice(0, 300)}`);
}

async function startLiveKit(s) {
    // Windows Firewall is read BEFORE LiveKit starts: from the moment it does, Windows may ask whether to let it through,
    // and blocks it until someone answers, which would read as "blocked" here.
    const firewall = checkFirewall(s).catch((e) => say(`Windows Firewall: could not check it (${e && e.message || e})`));
    await stopLeftover(LK_PID, LK_EXE);
    await ensureLiveKit();
    await firewall;
    if (await answering(s.apiPort)) {
        throw new Error(`something already answers on 127.0.0.1:${s.apiPort}, where the built-in voice server listens. `
            + 'The setup wizard\'s "LiveKit" service? Either use it (put the lines the wizard writes into server.cfg), or stop '
            + 'and uninstall it ("Setup voice server.bat" -Uninstall), or give the built-in one other ports (docs/SETUP.md)');
    }
    state.key = 'whip' + randomHex(6);
    state.secret = randomHex(32);
    state.api = s.api;
    state.udp = s.udp;
    state.tcp = s.tcp;
    state.ip = s.ip || null;

    liveKit = new Kept({
        name: 'the voice server (LiveKit)',
        exe: LK_EXE,
        cwd: LK_DIR,
        env: { ...process.env, LIVEKIT_CONFIG: liveKitConfig(s), LIVEKIT_KEYS: `${state.key}: ${state.secret}` },
        log: 'livekit.log',
        pidFile: LK_PID,
        onLine: echoLiveKit,
        ready: async (child) => {
            for (let i = 0; i < 50; i++) {
                if (child.exitCode !== null) return false;
                try {
                    const r = await fetch(`${s.api}/`, { signal: AbortSignal.timeout(1500) });
                    if (r.ok && (await r.text()).trim() === 'OK') return true;
                } catch (_) { /* not yet */ }
                await sleep(400);
            }
            return false;
        },
        onReady: () => {
            const first = state.gen === 0;
            state.gen += 1;
            setPhase('ready');
            say(first
                ? `built-in voice server: LiveKit ${LIVEKIT_VERSION} is running. Players' games send voices to UDP ${s.udp} `
                  + `(TCP ${s.tcp} when UDP is blocked): open those ports inbound, as you did 30120`
                : 'built-in voice server: running again');
        },
        onDown: (why) => { setPhase('restarting', why); say(`built-in voice server: ${why}`); },
        onGiveUp: (why) => {
            setPhase('failed', why);
            if (why === NO_PERMISSION) { say(`built-in voice server: ${why}`); return; }
            say(`built-in voice server: ${why}. It stopped five times in a row, so it is left stopped: whip_voice/bin/logs/livekit.log `
                + 'says why. Restart whip_voice to try again');
        },
    });
    await liveKit.start();
}

// ============================================
// Windows Firewall (service/firewall.ps1, also behind "Open voice ports.bat")
// ============================================

/** Read Windows Firewall, and open the voice ports if this FiveM server runs as administrator. `quiet`: only read
 *  (for /voicecheck, which says it in its own words). */
async function checkFirewall(s, quiet) {
    if (!WIN) return;
    const r = await run(path.join(SYSTEM32, 'WindowsPowerShell', 'v1.0', 'powershell.exe'), [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(HERE, 'service', 'firewall.ps1'),
        '-Exe', LK_EXE, '-Udp', s.udp, '-Tcp', String(s.tcp), '-Fix', '-Json',
    ]);
    let f = null;
    try { f = JSON.parse(r.out.trim().split(/\r?\n/).pop()); } catch (_) { /* below */ }
    if (!f) {
        state.firewall = null;
        if (!quiet) say(`Windows Firewall: could not read it (${r.out.trim().slice(-200) || 'no answer'}); /voicecheck shows whether players get through`);
        return;
    }
    state.firewall = f;
    publish();
    if (!f.on || quiet) return;
    if (f.fixed) {
        say(`Windows Firewall: opened UDP ${s.udp} and TCP ${s.tcp} for voice${f.unblocked ? ', and took away Windows\' block on the voice server' : ''}`);
    } else if (f.blocked) {
        say('Windows Firewall BLOCKS the voice server (someone answered Cancel when Windows asked about it), so players will not '
            + 'hear each other. On this machine, double-click whip_voice\\service\\Open voice ports.bat (it asks for '
            + 'administrator rights). No restart needed');
    } else if (!f.open) {
        say(`Windows Firewall: the voice ports are not open yet. If Windows asks whether to let livekit-server.exe through, `
            + 'click Allow. Or, and on a server nobody is logged into, double-click whip_voice\\service\\Open voice ports.bat '
            + '(it asks for administrator rights). No restart needed');
    }
}

// ============================================
// The voice bot
// ============================================

let bot = null;

async function ensureNode() {
    if (readText(path.join(NODE_DIR, 'version.txt')) === NODE_VERSION && exists(NODE_EXE)) return;
    const asset = NODE_FILES[PLATFORM];
    say(`voice bot: downloading Node.js ${NODE_VERSION} for it (once, about 30 MB)...`);
    const tmp = await freshDir(path.join(BIN, 'tmp', 'node'));
    const archive = path.join(tmp, asset.file);
    await download(`https://nodejs.org/dist/v${NODE_VERSION}/${asset.file}`, asset.sha256, archive);
    await unpack(archive, tmp);
    await fsp.rm(NODE_DIR, { recursive: true, force: true });
    await fsp.rename(path.join(tmp, asset.dir), NODE_DIR);
    await fsp.writeFile(path.join(NODE_DIR, 'version.txt'), NODE_VERSION);
    await fsp.rm(tmp, { recursive: true, force: true });
}

/** The bot's files in service/voicebot: bot.mjs, its package files, and everything in agent/. */
async function botFiles() {
    const files = ['bot.mjs', 'package.json', 'package-lock.json'];
    const walk = async (rel) => {
        for (const e of await fsp.readdir(path.join(BOT_SRC, rel), { withFileTypes: true })) {
            const r = path.join(rel, e.name);
            if (e.isDirectory()) await walk(r); else files.push(r);
        }
    };
    if (exists(path.join(BOT_SRC, 'agent'))) await walk('agent');
    return files;
}

/** The bot and its packages in bin/voicebot/app, set up again whenever whip_voice's copy changes. */
async function ensureBotApp() {
    const files = await botFiles();
    const hash = crypto.createHash('sha256');
    for (const f of files) hash.update(f.replace(/\\/g, '/')).update('\0').update(await fsp.readFile(path.join(BOT_SRC, f)));
    const stamp = `${NODE_VERSION} ${hash.digest('hex')}`;
    const stampFile = path.join(BOT_APP, '.whip-stamp');
    if (readText(stampFile) === stamp && exists(path.join(BOT_APP, 'node_modules'))) return;

    say('voice bot: installing it and its packages (once, about 70 MB; voice works meanwhile)...');
    await freshDir(BOT_APP);
    for (const f of files) {
        await fsp.mkdir(path.dirname(path.join(BOT_APP, f)), { recursive: true });
        await fsp.copyFile(path.join(BOT_SRC, f), path.join(BOT_APP, f));
    }
    // Exactly as package-lock.json pins them, and no package's install scripts run.
    const r = await run(NODE_EXE, [NPM_CLI, 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], {
        cwd: BOT_APP,
        env: { ...process.env, PATH: path.dirname(NODE_EXE) + path.delimiter + (process.env.PATH || ''),
               npm_config_cache: path.join(BIN, 'npm-cache'), npm_config_update_notifier: 'false' },
    });
    fs.mkdirSync(LOGS, { recursive: true });
    fs.writeFileSync(path.join(LOGS, 'voicebot-install.log'), r.out);
    if (r.code !== 0) {
        throw new Error('its packages could not be installed (this machine needs to reach registry.npmjs.org): '
            + 'whip_voice/bin/logs/voicebot-install.log says why');
    }
    await fsp.writeFile(stampFile, stamp);
}

/** The bot's settings from config.lua (Config.VoiceBot), passed in by the Lua side. */
function botConfig(s, opts, token) {
    const o = opts || {};
    const links = Array.isArray(o.audioLinks) ? o.audioLinks.filter((l) => typeof l === 'string') : null;
    const num = (v, lo, hi, d) => (Number.isFinite(Number(v)) ? Math.max(lo, Math.min(hi, Number(v))) : d);
    return {
        listen: `127.0.0.1:${s.botPort}`,
        token,
        maxCalls: num(o.maxCalls, 1, 200, 30),
        audioLinks: links && links.length ? links : ['https://r2.fivemanage.com/'],
        maxSeconds: num(o.maxSeconds, 1, 600, 120),
        maxBytes: Math.round(num(o.maxMB, 0.1, 64, 15) * 1024 * 1024),
        cacheBytes: 200 * 1024 * 1024,
    };
}

async function startBot(s, opts) {
    if (!s.bot) { setBot('off', 'switched off in server.cfg (whip_voice_bot false)'); return; }
    if (!NODE_FILES[PLATFORM]) { setBot('failed', `there is no Node.js for ${PLATFORM} here`); return; }
    try {
        setBot('installing', 'still being set up (the first start downloads it)');
        await stopLeftover(BOT_PID, NODE_EXE);
        await ensureNode();
        await ensureBotApp();
    } catch (e) {
        setBot('failed', String(e && e.message || e));
        say(`voice bot: ${state.bot.why}. Lore characters cannot phone players; voice itself is fine`);
        return;
    }
    const token = crypto.randomBytes(36).toString('base64url');
    await fsp.writeFile(BOT_CONFIG, JSON.stringify(botConfig(s, opts, token), null, 2));
    const url = `http://127.0.0.1:${s.botPort}`;
    bot = new Kept({
        name: 'the voice bot',
        exe: NODE_EXE,
        args: [path.join(BOT_APP, 'bot.mjs')],
        cwd: BOT_APP,
        env: { ...process.env, WHIP_VOICEBOT_CONFIG: BOT_CONFIG },
        log: 'voicebot.log',
        pidFile: BOT_PID,
        ready: async (child) => {
            for (let i = 0; i < 40; i++) {
                if (child.exitCode !== null) return false;
                try {
                    const r = await fetch(`${url}/health`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(1500) });
                    if (r.ok) return true;
                } catch (_) { /* not yet */ }
                await sleep(500);
            }
            return false;
        },
        onReady: () => {
            const first = state.bot.phase !== 'restarting';
            setBot('ready', null, { url, token });
            if (first) say('voice bot: running (lore characters can phone players)');
        },
        onDown: (why) => { setBot('restarting', why); say(`voice bot: ${why}`); },
        onGiveUp: (why) => {
            setBot('failed', why);
            if (why === NO_PERMISSION) return;      // said once already, for the voice server
            say(`voice bot: ${why}. Left stopped (whip_voice/bin/logs/voicebot.log says why); voice itself is fine`);
        },
    });
    await bot.start();
}

// ============================================
// Starting and stopping
// ============================================

let started = false;
let current = null;        // the settings it started with

// /voicecheck: Windows Firewall read again (it may have been opened since the start).
on('whip_voice:builtin:firewall', () => {
    const done = () => { state.firewallN += 1; publish(); };
    if (!current) { done(); return; }
    checkFirewall(current, true).catch(() => { state.firewall = null; }).finally(done);
});

on('whip_voice:builtin:start', (opts) => {
    if (GetConvar('whip_voice_url', '') !== '') return;     // your own voice server: nothing for this file to do
    if (started) { publish(); return; }
    started = true;
    (async () => {
        let s;
        try {
            if (typeof WebSocket !== 'function' || typeof fetch !== 'function') {
                throw new Error('this FiveM server\'s JavaScript is too old (no WebSocket): update FXServer');
            }
            if (!LIVEKIT_FILES[PLATFORM]) {
                throw new Error(`it runs on Windows and Linux (x64), not ${PLATFORM}: use a voice server of your own (docs/SETUP.md)`);
            }
            if (!spawnAllowed()) throw new Error(NO_PERMISSION);
            s = settings();
            current = s;
            setPhase('starting', 'starting');
            await startLiveKit(s);
        } catch (e) {
            setPhase('failed', String(e && e.message || e));
            say(`built-in voice server: ${state.why}`);
            return;
        }
        startBot(s, opts && opts.bot).catch((e) => setBot('failed', String(e && e.message || e)));
    })();
});

on('onResourceStop', (name) => {
    if (name !== RESOURCE) return;
    for (const s of sockets.values()) { try { s.ws.close(); } catch (_) { /* gone */ } }
    sockets.clear();
    if (bot) bot.stop();
    if (liveKit) liveKit.stop();
});

// ============================================
// The signalling relay
// ============================================
//
// A player's game opens a "connection" (op open, with the path and query its LiveKit client asked for), sends
// messages (base64, cut into pieces: op more, more, ..., data), and closes it (op close). Each is passed to a real
// WebSocket to LiveKit on this machine, and LiveKit's messages go back as more/data, and its close as close. LiveKit
// itself checks each connection's token (signed by server/token.lua for that player), so nothing here can let a game
// into the room that its token does not.

const CHUNK = 12000;               // base64 characters per event, as server/builtin.lua's SecureEvent takes
const MAX_MESSAGE = 1024 * 1024;   // one signalling message (base64), at most
const PER_PLAYER = 3;              // connections one game may hold (a reconnect overlaps the old one briefly)
const sockets = new Map();         // `${src}:${sock}` -> { ws, src, sock, key, parts, size, pending }

function toGame(src, sock, op, data) {
    emitNet('whip_voice:client:sig', src, sock, op, data || '');
}

function closedToGame(src, sock, code, reason) {
    toGame(src, sock, 'close', JSON.stringify({ code, reason: reason || '' }));
}

/** A message from LiveKit to the game, cut into pieces. */
function messageToGame(src, sock, buf) {
    const b64 = buf.toString('base64');
    if (b64.length === 0) { toGame(src, sock, 'data', ''); return; }
    for (let i = 0; i < b64.length; i += CHUNK) {
        toGame(src, sock, i + CHUNK >= b64.length ? 'data' : 'more', b64.slice(i, i + CHUNK));
    }
}

function forget(s, code, reason) {
    if (sockets.get(s.key) === s) sockets.delete(s.key);
    try { s.ws.close(); } catch (_) { /* gone */ }
    if (code) closedToGame(s.src, s.sock, code, reason);
}

function open(src, sock, key, target) {
    if (state.phase !== 'ready') { closedToGame(src, sock, 1013, state.why || 'the voice server is starting'); return; }
    // Only LiveKit's signalling: /rtc (or /rtc/v1) and its query (the token, the client's details).
    if (!/^\/rtc(\/v1)?(\?[^#\s]*)?$/.test(target)) { closedToGame(src, sock, 1008, 'not a voice server address'); return; }
    const old = sockets.get(key);
    if (old) forget(old);
    const mine = [...sockets.values()].filter((x) => x.src === src);
    while (mine.length >= PER_PLAYER) forget(mine.shift(), 1000, 'replaced by a newer connection');

    let ws;
    try {
        ws = new WebSocket(`ws://127.0.0.1:${new URL(state.api).port}${target}`);
    } catch (e) {
        closedToGame(src, sock, 1011, String(e && e.message || e));
        return;
    }
    ws.binaryType = 'arraybuffer';
    const s = { ws, src, sock, key, parts: [], size: 0, pending: [] };
    sockets.set(key, s);
    ws.addEventListener('open', () => {
        if (sockets.get(key) !== s) return;
        toGame(src, sock, 'open', '');
        for (const b of s.pending) ws.send(b);
        s.pending = [];
    });
    ws.addEventListener('message', (ev) => {
        if (sockets.get(key) !== s) return;
        messageToGame(src, sock, typeof ev.data === 'string' ? Buffer.from(ev.data, 'utf8') : Buffer.from(ev.data));
    });
    ws.addEventListener('close', (ev) => {
        if (sockets.get(key) !== s) return;
        sockets.delete(key);
        closedToGame(src, sock, ev.code || 1006, ev.reason);
    });
    ws.addEventListener('error', () => { /* a close follows */ });
}

on('whip_voice:relay:fromGame', (src, sock, op, data) => {
    src = Number(src);
    sock = Number(sock);
    data = typeof data === 'string' ? data : '';
    if (!Number.isInteger(src) || !Number.isInteger(sock)) return;
    const key = `${src}:${sock}`;
    if (op === 'open') { open(src, sock, key, data); return; }
    const s = sockets.get(key);
    if (!s) {
        if (op !== 'close') closedToGame(src, sock, 1006, 'that voice connection is gone');
        return;
    }
    if (op === 'close') { forget(s, 1000, ''); return; }
    s.parts.push(data);
    s.size += data.length;
    if (s.size > MAX_MESSAGE) { forget(s, 1009, 'message too big'); return; }
    if (op === 'more') return;
    const buf = Buffer.from(s.parts.join(''), 'base64');
    s.parts = [];
    s.size = 0;
    if (s.ws.readyState === 1) s.ws.send(buf);
    else if (s.ws.readyState === 0) s.pending.push(buf);
});

on('playerDropped', () => {
    const src = Number(global.source);
    for (const s of [...sockets.values()]) if (s.src === src) forget(s);
});
