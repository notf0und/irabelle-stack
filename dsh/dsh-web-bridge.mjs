#!/usr/bin/env node
/**
 * dsh-web-bridge — puts `dsh web` behind Traefik/Authentik for LAN + Tailscale use.
 *
 * Why this exists
 * ---------------
 * `dsh web` can only bind loopback (`--host 0.0.0.0` is refused on purpose,
 * because the GUI is remote code execution). Traefik runs in a container and
 * cannot reach the host's 127.0.0.1, so this bridge listens on the Docker
 * gateway address (172.17.0.1, which is what `host.docker.internal` resolves
 * to inside Traefik) and forwards to 127.0.0.1:3080.
 *
 * On top of plain forwarding it does three jobs:
 *   1. On-demand lifecycle: starts `dsh web` on the first request (showing a
 *      small waiting page) and stops it once nothing is active any more.
 *   2. Token injection: `dsh web` only lets a browser in through a one-time
 *      `/?token=…` URL; this bridge reads that token from the child's stdout
 *      and replays it automatically whenever the browser has no auth cookie,
 *      so opening dsh.test always just works (including after restarts, cookie
 *      expiry, or on a brand new device).
 *   3. Cookie fix: dsh mints its session cookie with `SameSite=Strict`, which
 *      browsers withhold on the cross-site redirect back from Authentik's login
 *      page. Rewriting it to `Lax` makes that redirect land on a logged-in app
 *      instead of a 401.
 *
 * Idle-stop safety
 * ----------------
 * dsh is only stopped when ALL of these hold for IDLE_MINUTES:
 *   - no proxied HTTP request in flight and no open WebSocket/SSE connection,
 *   - no session log written (nothing is being appended under $DSH_HOME/sessions),
 *   - the dsh process has no descendant processes (no tool/command still running).
 * Set IDLE_MINUTES=0 to keep it running forever once started, or touch
 * $DSH_HOME/web-bridge.keepalive to pin it while the file exists.
 *
 * Version management
 * ------------------
 * dsh is always launched from a local cached copy, never through an `npx`
 * wrapper (npx does not exec-replace itself, so the real dsh would be a
 * grandchild that survives the bridge's SIGTERM and keeps holding the port).
 * While running, the bridge refreshes the tracked dist-tag in the background at
 * most once per UPDATE_HOURS; the newer copy is picked up on the next cold
 * start. A version that never reaches ready is marked broken and the bridge
 * falls back to the last version that actually served (state in
 * $DSH_HOME/web-bridge-state.json), so a bad release cannot lock you out.
 *
 * PWA manifest
 * ------------
 * dsh's manifest lists only an SVG icon, which Chrome parses as 0x0 and then
 * refuses to install (upstream: deepseek-harness discussion #3736 — it
 * reproduces even on 127.0.0.1). When the icons/ directory next to this script
 * holds the PNGs, the bridge serves them and adds them to
 * /manifest.webmanifest. Upstream bytes pass through untouched whenever dsh
 * already ships raster icons, so the shim disables itself once that is fixed.
 *
 * Configuration (environment):
 *   LISTEN_HOST       default 172.17.0.1   address Traefik connects to
 *   LISTEN_PORT       default 3080
 *   UPSTREAM_HOST     default 127.0.0.1    where dsh listens
 *   UPSTREAM_PORT     default LISTEN_PORT
 *   PUBLIC_HOST       default dsh.test     passed to dsh as --trusted-host
 *   DSH_CMD           default unset         set it to pin an exact command and
 *                                           disable version management entirely
 *   DSH_UPDATE_TAG    default latest        dist-tag to track (latest/next/alpha)
 *   UPDATE_HOURS      default 24            how often to check; 0 disables
 *   DSH_REFRESH_ON_START   default unset    1/true: resolve and fetch the tracked
 *                                           tag before every cold start, so each
 *                                           instance runs the newest release
 *   READY_TIMEOUT_S   default 150           seconds before a launch is rolled back
 *   DSH_NPX_CACHE     default ~/.npm/_npx   where cached copies are searched
 *   DSH_ICON_DIR      default ./icons       PNG icons injected into the manifest
 *   DSH_HOME          default ~/.dsh
 *   DSH_CWD           default $HOME
 *   IDLE_MINUTES      default 30           minutes of inactivity before stopping
 *   START_TIMEOUT_S   default 180          seconds before the wait page shows logs
 *
 * No dependencies: Node standard library only.
 */

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { spawn, execFile } from 'node:child_process';

// ── configuration ──────────────────────────────────────────────────────────

const env = process.env;
const LISTEN_HOST = env.LISTEN_HOST || '172.17.0.1';
const LISTEN_PORT = Number(env.LISTEN_PORT || 3080);
const UPSTREAM_HOST = env.UPSTREAM_HOST || '127.0.0.1';
const UPSTREAM_PORT = Number(env.UPSTREAM_PORT || LISTEN_PORT);
const PUBLIC_HOST = env.PUBLIC_HOST || 'dsh.test';
const DSH_HOME = env.DSH_HOME || path.join(os.homedir(), '.dsh');
const DSH_CWD = env.DSH_CWD || os.homedir();
const IDLE_MINUTES = Number(env.IDLE_MINUTES ?? 30);
const START_TIMEOUT_MS = Number(env.START_TIMEOUT_S || 180) * 1000;
const UPDATE_HOURS = Number(env.UPDATE_HOURS ?? 24);
const DSH_UPDATE_TAG = env.DSH_UPDATE_TAG || 'latest';
const READY_TIMEOUT_S = Number(env.READY_TIMEOUT_S || 150);
const KEEPALIVE_FILE = path.join(DSH_HOME, 'web-bridge.keepalive');
const STATE_FILE = path.join(DSH_HOME, 'web-bridge-state.json');
const COOKIE_PREFIX = 'dsh-auth-'; // dsh names its cookie `dsh-auth-<authority>`
const PINNED_CMD = env.DSH_CMD || null; // an explicit DSH_CMD turns version management off
const NPX_CACHE = env.DSH_NPX_CACHE || path.join(os.homedir(), '.npm', '_npx');

// dsh picks its directory picker once per boot: with a graphical session
// (DISPLAY or WAYLAND_DISPLAY set) and zenity/kdialog on PATH it mounts the
// *native* chooser, which opens on this host's screen. Behind the bridge that
// is never where the user is — the browser is on Traefik, on another device —
// so "add workspace" would spawn a dialog nobody can see and appear to do
// nothing. Its probe treats an empty value as unset, so clearing these two for
// the child resolves it to the in-app browse picker, which works everywhere.
// Set DSH_NATIVE_PICKER=1 to keep the native chooser (a browser on this host).
const NATIVE_PICKER = /^(1|true|yes)$/i.test(env.DSH_NATIVE_PICKER || '');
const PICKER_ENV = NATIVE_PICKER ? {} : { DISPLAY: '', WAYLAND_DISPLAY: '' };

// A bridge restart is when a changed bridge file starts running, and a browser
// can keep reusing the bundle it cached from the previous one — its cache entry
// decides, not a validator, so a plain refresh can still run the old code and a
// freshly installed PWA inherits the same cache. Sending
// `Clear-Site-Data: "cache"` on the first document served after the restart
// makes every client drop that cache on its next load, so the new bundle is
// fetched instead of the stale one. Once per bridge boot, not per request, and
// only the HTTP cache — never storage, which holds the app's own state.
const CACHE_CLEAR_ON_BOOT = !/^(0|false|no)$/i.test(env.DSH_CACHE_CLEAR || '');
let cacheClearArmed = CACHE_CLEAR_ON_BOOT;

// When set, every cold start resolves and downloads the tracked tag *before*
// choosing a copy, so the instance that comes up is the newest release rather
// than whatever a background refresh happened to fetch during the previous
// run. Off by default: the stock behaviour (check in the background, apply on
// the next cold start) never makes startup wait on the registry. The wait is
// bounded; if the registry is slow or unreachable the cached copy still runs.
const REFRESH_ON_START = /^(1|true|yes)$/i.test(env.DSH_REFRESH_ON_START || '');
const REFRESH_ON_START_TIMEOUT_MS = Number(env.DSH_REFRESH_ON_START_TIMEOUT_S || 120) * 1000;

// dsh's manifest lists only an SVG icon, which Chrome parses as 0x0 and refuses
// to install (upstream: deepseek-harness discussion #3736 — it reproduces even
// on 127.0.0.1). The bridge therefore serves its own raster icons and injects
// them into the manifest, which also survives dsh upgrades. Needs no dsh patch.
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ICON_DIR = env.DSH_ICON_DIR || path.join(SCRIPT_DIR, 'icons');
const MANIFEST_PATH = '/manifest.webmanifest';
const PWA_ICONS = [
  { src: '/__bridge/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
  { src: '/__bridge/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
  { src: '/__bridge/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
];
const ICON_BY_PATH = new Map(PWA_ICONS.map((icon) => [icon.src, path.basename(icon.src)]));
const iconsAvailable = [...ICON_BY_PATH.values()].every((name) => fs.existsSync(path.join(ICON_DIR, name)));

// ── package version management ─────────────────────────────────────────────
//
// dsh is always started from a local copy, never through an `npx` wrapper: npx
// does not exec-replace itself, so the real dsh would be a grandchild that
// survives the bridge's SIGTERM, keeps holding the port, and makes the bridge
// report a port conflict forever. Instead the bridge keeps its own view of
// which cached copy to run, refreshes the tag in the background at most once
// per UPDATE_HOURS, applies it on the next cold start, and falls back to the
// last version that actually reached ready so a bad release cannot lock you out.

/** Every @deepseek-ai/dsh copy in the npx cache, most recently installed first. */
function scanCachedInstalls() {
  let entries;
  try { entries = fs.readdirSync(NPX_CACHE); } catch { return []; }
  const found = [];
  for (const entry of entries) {
    const dir = path.join(NPX_CACHE, entry, 'node_modules', '@deepseek-ai', 'dsh');
    const binPath = path.join(dir, 'lib', 'bin.js');
    try {
      if (!fs.existsSync(binPath)) continue;
      const meta = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
      if (typeof meta.version !== 'string') continue;
      found.push({
        version: meta.version,
        cmd: `${JSON.stringify(process.execPath)} ${JSON.stringify(binPath)}`,
        mtime: fs.statSync(binPath).mtimeMs,
      });
    } catch { /* a half-written or removed copy — skip it */ }
  }
  return found.sort((a, b) => b.mtime - a.mtime);
}

/** Update bookkeeping persisted across restarts (mode 600, under DSH_HOME). */
function loadState() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    return {
      targetVersion: typeof parsed.targetVersion === 'string' ? parsed.targetVersion : null,
      lastGoodVersion: typeof parsed.lastGoodVersion === 'string' ? parsed.lastGoodVersion : null,
      lastCheckAt: Number.isFinite(parsed.lastCheckAt) ? parsed.lastCheckAt : 0,
      badVersions: Array.isArray(parsed.badVersions) ? parsed.badVersions.filter((v) => typeof v === 'string') : [],
    };
  } catch {
    return { targetVersion: null, lastGoodVersion: null, lastCheckAt: 0, badVersions: [] };
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    const temp = `${STATE_FILE}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temp, STATE_FILE);
  } catch (error) {
    log(`could not persist update state: ${error.message}`);
  }
}

/** Run a short helper command and resolve its exit code and output. */
function run(cmd, args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, env, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
      resolve({
        code: error === null ? 0 : (typeof error.code === 'number' ? error.code : 1),
        stdout: String(stdout),
        stderr: String(stderr),
      });
    });
  });
}

/** The concrete version a dist-tag currently points at, or null. */
async function resolveTaggedVersion(tag) {
  const { code, stdout, stderr } = await run('npm', ['view', `@deepseek-ai/dsh@${tag}`, 'version', '--json'], 60_000);
  if (code !== 0) {
    log(`update check failed (npm view @deepseek-ai/dsh@${tag}): ${stderr.trim().split('\n')[0] || 'unknown error'}`);
    return null;
  }
  try {
    const parsed = JSON.parse(stdout);
    if (typeof parsed === 'string') return parsed;
    if (Array.isArray(parsed) && typeof parsed[parsed.length - 1] === 'string') return parsed[parsed.length - 1];
  } catch { /* not JSON — fall through to the raw text */ }
  const plain = stdout.trim();
  return plain === '' ? null : plain;
}

/** Download a concrete version into the npx cache (still no wrapper at start). */
async function fetchVersion(version) {
  log(`downloading @deepseek-ai/dsh@${version} into the local cache…`);
  const { code, stderr } = await run('npx', ['-y', `@deepseek-ai/dsh@${version}`, '--version'], 300_000);
  if (code !== 0) {
    log(`download of ${version} failed: ${stderr.trim().split('\n')[0] || 'unknown error'}`);
    return false;
  }
  return true;
}

let refreshing = false;

/**
 * Refresh the tracked tag. Throttled to once per UPDATE_HOURS unless `force`,
 * which is what a cold start uses when DSH_REFRESH_ON_START is on. The new
 * version is recorded in the state file, so the very next chooseInstall() —
 * whether that is this cold start or the next one — runs it.
 */
async function refreshPackage(force = false) {
  if (PINNED_CMD !== null || refreshing) return;
  refreshing = true;
  try {
    const state = loadState();
    if (!force && (UPDATE_HOURS <= 0 || Date.now() - state.lastCheckAt < UPDATE_HOURS * 3600 * 1000)) return;
    state.lastCheckAt = Date.now();
    saveState(state);
    const version = await resolveTaggedVersion(DSH_UPDATE_TAG);
    if (version === null) return;
    if (!scanCachedInstalls().some((i) => i.version === version)) {
      if (!(await fetchVersion(version))) return;
    }
    if (!scanCachedInstalls().some((i) => i.version === version)) return;
    const next = loadState();
    next.targetVersion = version;
    saveState(next);
    const running = attemptVersion ?? loadState().lastGoodVersion;
    if (running === version) log(`already on the newest ${DSH_UPDATE_TAG} (${version})`);
    else if (force) log(`using ${version} (tag ${DSH_UPDATE_TAG}) — refreshed before this start`);
    else log(`update ready: ${version} (tag ${DSH_UPDATE_TAG}) — it will be used on the next cold start`);
  } catch (error) {
    log(`update check error: ${error.message}`);
  } finally {
    refreshing = false;
  }
}

/** Which cached copy to run: the target, else the last known-good, else newest usable. */
function selectInstall(state) {
  const installs = scanCachedInstalls();
  if (installs.length === 0) return null;
  const usable = installs.filter((i) => !state.badVersions.includes(i.version));
  const pool = usable.length > 0 ? usable : installs;
  return pool.find((i) => i.version === state.targetVersion)
    ?? pool.find((i) => i.version === state.lastGoodVersion)
    ?? pool[0];
}

/** Resolve the command to run, bootstrapping the cache when it is completely empty. */
async function chooseInstall() {
  if (PINNED_CMD !== null) return { cmd: PINNED_CMD, version: null };
  let install = selectInstall(loadState());
  if (install === null) {
    log('no cached dsh package — fetching one now');
    const version = await resolveTaggedVersion(DSH_UPDATE_TAG);
    if (version !== null && (await fetchVersion(version))) {
      const next = loadState();
      next.targetVersion = version;
      saveState(next);
      install = selectInstall(next);
    }
  }
  if (install === null) {
    log('still no local copy — running through npx as a last resort (signals will not be tracked)');
    return { cmd: `npx -y @deepseek-ai/dsh@${DSH_UPDATE_TAG}`, version: null };
  }
  return { cmd: install.cmd, version: install.version };
}

/** Record the version that actually served, and clear any bad mark on it. */
function markGood(version) {
  if (version === null) return;
  const state = loadState();
  state.lastGoodVersion = version;
  state.targetVersion = version;
  state.badVersions = state.badVersions.filter((v) => v !== version);
  saveState(state);
}

/** Remember a version that never reached ready, so the previous one is used instead. */
function markFailed(version) {
  if (version === null) return;
  const state = loadState();
  if (!state.badVersions.includes(version)) state.badVersions.push(version);
  if (state.targetVersion === version) state.targetVersion = null;
  saveState(state);
}

// ── logging ────────────────────────────────────────────────────────────────

function log(...args) {
  console.log(new Date().toISOString(), '[bridge]', ...args);
}
function logDsh(line) {
  console.log(new Date().toISOString(), '[dsh]', line);
}

// ── dsh child supervision ──────────────────────────────────────────────────

/** @type {import('node:child_process').ChildProcess | null} */
let child = null;
let childStartedAt = 0;
let token = null;            // one-time launch token from `dsh web: …?token=…`
let ready = false;           // true once the token line has been seen
let stopping = false;        // true while an intentional stop is in progress
let lastExit = null;         // { code, signal, at }
let starting = false;        // a port probe or package download is in flight
let portBusy = false;        // something else (a manual dsh) owns the port
let crashCount = 0;          // consecutive unexpected exits, for backoff
let attemptVersion = null;   // dsh version currently being launched
let readyTimer = null;       // fires when a launch never reaches ready
const recentLog = [];        // ring buffer of child output, for the wait page

function pushLog(line) {
  recentLog.push(line);
  if (recentLog.length > 40) recentLog.shift();
}

/** Is another process already listening on the upstream port (a manual dsh)? */
function probeUpstream() {
  return new Promise((resolve) => {
    const socket = net.connect({ host: UPSTREAM_HOST, port: UPSTREAM_PORT });
    const done = (inUse) => { socket.destroy(); resolve(inUse); };
    socket.setTimeout(700, () => done(false)); // nothing answered -> port is free
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

/**
 * Start dsh, unless another process already owns the port — almost always a
 * manually launched `dsh web`. Probing first is what stops the bridge from
 * spawning a competitor on every request and burning CPU on boots that cannot
 * possibly succeed. The package is resolved here, on every cold start, so an
 * update fetched in the background is picked up without restarting the service.
 */
function ensureChild() {
  if (child !== null || starting) return child;
  starting = true;
  void (async () => {
    try {
      const inUse = await probeUpstream();
      if (child !== null) return;
      if (inUse) {
        if (!portBusy) {
          portBusy = true;
          log(`not starting: ${UPSTREAM_HOST}:${UPSTREAM_PORT} is already in use by another process (a manually started "dsh web"?) — waiting for it to exit`);
        }
        return;
      }
      portBusy = false;
      // On a host that should always run the newest release, resolve the
      // tracked tag here — before choosing — so this cold start runs it. The
      // wait is bounded and never fatal: a slow registry just means the cached
      // copy comes up, and the fetch that is still running is applied next time.
      if (REFRESH_ON_START) {
        await Promise.race([
          refreshPackage(true),
          new Promise((resolve) => {
            const timer = setTimeout(resolve, REFRESH_ON_START_TIMEOUT_MS);
            timer.unref();
          }),
        ]);
      }
      const chosen = await chooseInstall();
      if (child !== null) return;
      startChild(chosen);
    } catch (error) {
      log(`could not start dsh: ${error.message}`);
    } finally {
      starting = false;
    }
  })();
  return child;
}

function startChild(chosen) {
  if (child !== null) return child;
  const args = [
    'web',
    '--no-open',
    '--port', String(UPSTREAM_PORT),
    '--trusted-host', PUBLIC_HOST,
  ];
  const command = `exec ${chosen.cmd} ${args.map((a) => JSON.stringify(a)).join(' ')}`;
  log(chosen.version === null ? `starting: ${command}` : `starting dsh ${chosen.version}`);
  attemptVersion = chosen.version;
  ready = false;
  token = null;
  stopping = false;
  childStartedAt = Date.now();
  recentLog.length = 0;

  const proc = spawn('/bin/sh', ['-c', command], {
    cwd: DSH_CWD,
    env: { ...env, DSH_HOME, ...PICKER_ENV },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child = proc;

  // A version that never reaches ready is rolled back to the previous one.
  if (attemptVersion !== null) {
    readyTimer = setTimeout(() => {
      if (child === proc && !ready) {
        log(`dsh ${attemptVersion} did not become ready within ${READY_TIMEOUT_S}s — treating it as broken and rolling back`);
        markFailed(attemptVersion);
        try { proc.kill('SIGTERM'); } catch { /* already gone */ }
      }
    }, READY_TIMEOUT_S * 1000);
    readyTimer.unref();
  }

  // Refresh the tracked tag in the background; it applies on the next cold start.
  void refreshPackage();

  let buffer = '';
  const onData = (chunk) => {
    buffer += chunk.toString('utf8');
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index).replace(/\r$/, '');
      buffer = buffer.slice(index + 1);
      handleChildLine(line);
    }
  };
  proc.stdout.on('data', onData);
  proc.stderr.on('data', onData);

  proc.on('error', (error) => {
    log(`spawn failed: ${error.message}`);
    pushLog(`spawn failed: ${error.message}`);
    child = null;
    ready = false;
  });

  proc.on('exit', (code, signal) => {
    const wasStopping = stopping;
    if (readyTimer !== null) { clearTimeout(readyTimer); readyTimer = null; }
    log(`dsh exited (code=${code} signal=${signal}${wasStopping ? ', intentional' : ''})`);
    pushLog(`dsh exited (code=${code} signal=${signal})`);
    lastExit = { code, signal, at: Date.now() };
    child = null;
    ready = false;
    token = null;
    stopping = false;
    if (wasStopping) return;
    // Port owned by someone else: nothing can succeed until it goes away, and
    // the next request will re-probe. Never spin here.
    if (portBusy) return;
    // A version that never managed to serve is marked broken, so the selection
    // falls back to the last known-good copy instead of retrying it forever.
    if (attemptVersion !== null && loadState().lastGoodVersion !== attemptVersion) {
      log(`dsh ${attemptVersion} exited before becoming ready — marking it broken; the previous version will be used`);
      markFailed(attemptVersion);
      crashCount = 0; // retry the fallback straight away, without a backoff penalty
    }
    if (Date.now() - lastRequestAt >= 5 * 60 * 1000) return; // idle: wait for a request
    crashCount = Math.min(crashCount + 1, 6);
    const delay = Math.min(3000 * 2 ** (crashCount - 1), 60_000);
    log(`restarting after unexpected exit in ${Math.round(delay / 1000)}s`);
    setTimeout(() => { if (child === null) ensureChild(); }, delay).unref();
  });

  return proc;
}

function handleChildLine(line) {
  logDsh(line);
  pushLog(line);
  if (!portBusy && line.includes('EADDRINUSE')) {
    portBusy = true;
    log(`dsh could not bind ${UPSTREAM_HOST}:${UPSTREAM_PORT} — another dsh owns the port; not retrying until it exits`);
  }
  if (ready) return;
  const match = /dsh web:\s+(\S+)/.exec(line);
  if (match === null) return;
  try {
    const url = new URL(match[1]);
    const parsed = url.searchParams.get('token');
    if (parsed !== null && parsed !== '') {
      token = parsed;
      ready = true;
      crashCount = 0;
      portBusy = false;
      if (readyTimer !== null) { clearTimeout(readyTimer); readyTimer = null; }
      markGood(attemptVersion); // this version works — it is the fallback from now on
      const label = attemptVersion === null ? 'dsh' : `dsh ${attemptVersion}`;
      log(`${label} is ready (listening on ${UPSTREAM_HOST}:${UPSTREAM_PORT}; token captured)`);
    }
  } catch {
    /* a non-URL "dsh web: …" line — ignore */
  }
}

function stopChild(reason) {
  const proc = child;
  if (proc === null) return;
  log(`stopping dsh (${reason})`);
  stopping = true;
  ready = false;
  if (readyTimer !== null) { clearTimeout(readyTimer); readyTimer = null; }
  try { proc.kill('SIGTERM'); } catch { /* already gone */ }
  const timer = setTimeout(() => {
    if (child === proc) {
      log('dsh did not exit in 10s; sending SIGKILL');
      try { proc.kill('SIGKILL'); } catch { /* already gone */ }
    }
  }, 10_000);
  timer.unref();
}

// ── activity tracking (for idle-stop) ──────────────────────────────────────

let activeConnections = 0;
let lastRequestAt = Date.now();
let lastSessionScanAt = 0;
let newestSessionMtime = 0;

/** Newest mtime of a session log under $DSH_HOME/sessions (throttled). */
function refreshSessionMtime() {
  const now = Date.now();
  if (now - lastSessionScanAt < 15_000) return newestSessionMtime;
  lastSessionScanAt = now;
  let newest = 0;
  const walk = (dir) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.name.endsWith('.jsonl.zstd') || entry.name.endsWith('.jsonl')) {
        try {
          const stat = fs.statSync(full);
          if (stat.mtimeMs > newest) newest = stat.mtimeMs;
        } catch { /* raced with cleanup */ }
      }
    }
  };
  walk(path.join(DSH_HOME, 'sessions'));
  newestSessionMtime = newest;
  return newest;
}

/** Does the dsh process still have any live descendant (a running tool/command)? */
function hasDescendants(rootPid) {
  const parentOf = new Map();
  let names;
  try { names = fs.readdirSync('/proc'); } catch { return false; }
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${name}/stat`, 'utf8');
      const close = stat.lastIndexOf(')');
      if (close < 0) continue;
      const parts = stat.slice(close + 2).split(' ');
      parentOf.set(Number(name), Number(parts[1]));
    } catch { /* process vanished */ }
  }
  for (const pid of parentOf.keys()) {
    let current = parentOf.get(pid);
    for (let hops = 0; current !== undefined && hops < 64; hops += 1) {
      if (current === rootPid) return true;
      current = parentOf.get(current);
    }
  }
  return false;
}

function idleStopDue() {
  if (IDLE_MINUTES <= 0) return false;
  if (child === null || !ready) return false;
  if (activeConnections > 0) return false;
  if (fs.existsSync(KEEPALIVE_FILE)) return false;
  const idleMs = IDLE_MINUTES * 60 * 1000;
  const lastActivity = Math.max(lastRequestAt, refreshSessionMtime());
  if (Date.now() - lastActivity < idleMs) return false;
  if (hasDescendants(child.pid)) {
    log('idle, but a tool/command is still running — keeping dsh up');
    return false;
  }
  return true;
}

setInterval(() => {
  if (idleStopDue()) {
    stopChild(`idle for ${IDLE_MINUTES} min with no connections or active work`);
  }
}, 30_000).unref();

// ── request helpers ────────────────────────────────────────────────────────

/** Same authority computation dsh uses for the cookie name (`new URL().host`). */
function authorityOf(hostHeader) {
  if (hostHeader === undefined) return undefined;
  try { return new URL(`http://${hostHeader}`).host; } catch { return undefined; }
}

/**
 * dsh's cookie name is deterministic: `dsh-auth-` + base64url(sha256(authority)).
 * (Mirrors `cookieName()` in @deepseek-ai/dsh-client-connection.)
 */
function cookieNameFor(authority) {
  const digest = createHash('sha256').update(authority).digest();
  const encoded = digest.toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
  return `${COOKIE_PREFIX}${encoded}`;
}

/** Read one cookie value the way dsh does (exact name match, no decoding). */
function cookieValueOf(headerValue, name) {
  for (const segment of headerValue.split(';')) {
    const at = segment.indexOf('=');
    if (at === -1 || segment.slice(0, at).trim() !== name) continue;
    return segment.slice(at + 1).trim();
  }
  return undefined;
}

const injectionTimes = new Map(); // clientIp -> number[] (loop guard)

function injectAllowed(ip) {
  const now = Date.now();
  const times = (injectionTimes.get(ip) || []).filter((t) => now - t < 30_000);
  if (times.length >= 5) return false;
  times.push(now);
  injectionTimes.set(ip, times);
  return true;
}

function wantsHtml(req) {
  return req.method === 'GET' && String(req.headers.accept || '').includes('text/html');
}

const WAIT_PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="2">
<title>Starting DeepSeek Harness…</title>
<style>
 :root{color-scheme:dark light}
 body{margin:0;min-height:100vh;display:grid;place-items:center;
      font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
      background:#0d1117;color:#e6edf3}
 .card{max-width:34rem;padding:2rem;text-align:center}
 .spin{width:2.5rem;height:2.5rem;margin:0 auto 1.25rem;border-radius:50%;
       border:.3rem solid #30363d;border-top-color:#58a6ff;animation:s 1s linear infinite}
 @keyframes s{to{transform:rotate(360deg)}}
 h1{font-size:1.15rem;margin:0 0 .5rem}
 p{margin:.35rem 0;color:#8b949e;font-size:.9rem}
 pre{text-align:left;background:#161b22;border:1px solid #30363d;border-radius:.5rem;
     padding:.75rem;margin-top:1.25rem;max-height:14rem;overflow:auto;
     font-size:.75rem;color:#8b949e;white-space:pre-wrap}
</style></head><body><div class="card">
<div class="spin"></div>
<h1>__HEAD__</h1>
<p>__SUB__</p>
__LOG__
</div></body></html>`;

function waitingPage(res, showLog) {
  const logBlock = showLog && recentLog.length > 0
    ? `<pre>${recentLog.slice(-12).map((l) => l.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]))).join('\n')}</pre>`
    : '';
  const head = portBusy
    ? `Another harness already owns port ${UPSTREAM_PORT}`
    : 'Starting DeepSeek Harness…';
  const sub = portBusy
    ? `A "dsh web" started by hand is still listening on 127.0.0.1:${UPSTREAM_PORT}. Stop it (pkill -f 'dsh web --no-open') and this page continues by itself.`
    : 'Cold start takes a few seconds. This page refreshes itself.';
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(
    WAIT_PAGE.replace('__HEAD__', head).replace('__SUB__', sub).replace('__LOG__', logBlock),
  );
}

function fixCookie(header) {
  return header.replace(/SameSite=Strict/gi, 'SameSite=Lax');
}

// ── reverse-proxy trust and header normalization ───────────────────────────
//
// Traefik terminates TLS for PUBLIC_HOST and the bridge forwards to dsh on
// loopback. Several DSH plugins — dshmarket's mutating routes among them —
// require the request's Host to be a *loopback* authority and compare Origin
// against it, which a browser at https://PUBLIC_HOST can never satisfy. The
// bridge therefore makes the trust decision here, where it can: the Host must
// be the public name (or a loopback / the bridge's own listen address), an
// Origin, when present, must match that Host, and a cross-site request is
// refused. Only then does it normalize what the upstream sees — Host to the
// loopback authority and Origin removed — which is what those plugins check.
//
// Doing the check here is not optional: dshmarket's routes have no cookie gate
// of their own, so removing Origin without a bridge-side decision would turn
// the normalization into a CSRF hole. dsh's own /api keeps its signed cookie
// as a second layer.
function authorityHostname(authority) {
  if (authority === undefined || authority === null) return undefined;
  const lower = String(authority).toLowerCase();
  if (lower.startsWith('[')) return lower.slice(0, lower.indexOf(']') + 1);
  return lower.split(':')[0];
}

function isAllowedAuthority(host) {
  const name = authorityHostname(host);
  if (name === undefined || name === '') return false;
  if (name === authorityHostname(PUBLIC_HOST)) return true;
  if (name === 'localhost' || name === '127.0.0.1' || name === '[::1]') return true;
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/u.test(name)) return true;
  // The bridge's own listen address, where /__bridge/status is read from this
  // host or a neighbouring container (never from a browser on the LAN).
  return name === authorityHostname(LISTEN_HOST);
}

/** null when the request may be proxied, else a short reason for the 403. */
function rejectReason(req) {
  const host = req.headers.host;
  if (!isAllowedAuthority(host)) return `Host ${host ?? '(none)'} is not ${PUBLIC_HOST}`;
  // Cross-site is refused only where it could change something. A top-level
  // navigation is *legitimately* cross-site — that is exactly what the
  // redirect back from authentik's login is (`Sec-Fetch-Site: cross-site` and
  // no Origin) — and refusing that answered the installed PWA with
  // "forbidden". dshmarket's mutating routes, the reason this gate exists at
  // all, are POSTs; they also carry a mismatching Origin, which the check
  // below catches, so nothing is loosened for them.
  const method = String(req.method ?? 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD' && method !== 'OPTIONS'
      && String(req.headers['sec-fetch-site'] ?? '').toLowerCase() === 'cross-site') {
    return 'cross-site request';
  }
  const origin = req.headers.origin;
  if (origin !== undefined) {
    let originHost;
    try { originHost = new URL(origin).hostname; } catch { return `unparseable Origin ${origin}`; }
    if (originHost.toLowerCase() !== authorityHostname(host)) return `Origin ${origin} does not match Host ${host}`;
  }
  return null;
}

// The authority dsh is reached on by the bridge. Every upstream request is
// dressed as one that came from a browser talking to dsh directly on loopback.
const UPSTREAM_AUTHORITY = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
const UPSTREAM_ORIGIN = `http://${UPSTREAM_AUTHORITY}`;
// A forwarding trace is itself a refusal: plugins that control the process
// (dshmarket's restart) or export data reject any request carrying one, on the
// grounds that a loopback peer that was proxied is not the user.
const FORWARDING_HEADERS = ['forwarded', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'x-forwarded-port', 'x-real-ip'];

/**
 * Upstream headers, with the authority and origin dsh and its plugins expect.
 *
 * `Origin` is *set* to the loopback authority rather than deleted, because
 * dshmarket's process-control and download guards require an Origin that
 * matches the loopback Host — deleting it passes `sameOrigin` but fails them.
 * dsh's own fence compares Origin to Host too, and matches either way. This
 * loosens nothing: the trust decision was already made by rejectReason above,
 * and this is the request the bridge constructs after passing it.
 */
function upstreamHeaders(req) {
  const headers = { ...req.headers };
  headers.host = UPSTREAM_AUTHORITY;
  headers.origin = UPSTREAM_ORIGIN;
  for (const name of FORWARDING_HEADERS) delete headers[name];
  return headers;
}

// A body the bridge rewrites must never be revalidated. The upstream ETag
// describes the bytes *before* the rewrite, so a browser that cached an
// earlier, unpatched copy sends `If-None-Match`, dsh answers 304, the rewrite
// is skipped, and the stale copy is reused forever — which is exactly how the
// Settings -> Models fix appeared not to work on an instance whose browser had
// cached the bundle from before it was deployed. Those two paths therefore ask
// upstream unconditionally and answer without validators, and `cache-control:
// no-store` keeps the rewritten bytes from being cached at all.
const CONDITIONAL_REQUEST_HEADERS = ['if-match', 'if-none-match', 'if-modified-since', 'if-unmodified-since', 'if-range'];

function unconditionalRequestHeaders(req) {
  const headers = upstreamHeaders(req);
  for (const name of CONDITIONAL_REQUEST_HEADERS) delete headers[name];
  return headers;
}

function rewrittenResponseHeaders(headers) {
  const out = { ...headers };
  delete out['content-length'];
  delete out['content-encoding'];
  delete out.etag;
  delete out['last-modified'];
  return out;
}

/** Serve one of the bridge's own PNG icons (referenced from the patched manifest). */
function serveIcon(res, name) {
  const file = path.join(ICON_DIR, name);
  fs.readFile(file, (error, data) => {
    if (error !== null) {
      log(`PWA icon unreadable: ${file} (${error.message})`);
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('icon not found\n');
      return;
    }
    res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'public, max-age=86400' });
    res.end(data);
  });
}

/** True when the manifest has no raster icon covering both 192 and 512. */
function needsRasterIcons(manifest) {
  const icons = Array.isArray(manifest?.icons) ? manifest.icons : [];
  const covers = (size) => icons.some((icon) =>
    typeof icon?.sizes === 'string' &&
    String(icon.type ?? '').startsWith('image/') &&
    icon.type !== 'image/svg+xml' &&
    icon.sizes.split(/\s+/u).includes(size));
  return !(covers('192x192') && covers('512x512'));
}

/**
 * Fetch the upstream manifest and, only when it cannot satisfy Chrome, add the
 * bridge's PNG icons. Otherwise the original bytes pass through untouched, so
 * this quietly becomes a no-op once dsh ships proper icons itself.
 *
 * The upstream request deliberately drops `Accept-Encoding`: dsh gzips the
 * manifest when asked, and an encoded body cannot be rewritten. (Traefik
 * forwards the browser's Accept-Encoding, so this bit us in production while a
 * plain curl showed a correctly patched manifest.) A compressed body is still
 * decoded defensively in case a server compresses regardless.
 */
function serveManifest(req, res) {
  const requestHeaders = unconditionalRequestHeaders(req);
  delete requestHeaders['accept-encoding'];
  const upstream = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: 'GET',
      path: req.url,
      headers: requestHeaders,
    },
    (upstreamRes) => {
      const chunks = [];
      upstreamRes.on('data', (chunk) => chunks.push(chunk));
      upstreamRes.on('end', () => {
        const raw = Buffer.concat(chunks);
        const headers = { ...upstreamRes.headers };
        const status = upstreamRes.statusCode || 502;
        const encoding = String(headers['content-encoding'] ?? '').toLowerCase();
        let body = raw;
        if (status === 200 && encoding !== '' && encoding !== 'identity') {
          const inflate = {
            gzip: zlib.gunzipSync,
            deflate: zlib.inflateSync,
            br: zlib.brotliDecompressSync,
          }[encoding];
          if (inflate === undefined) {
            log(`manifest arrived with unsupported encoding "${encoding}" — passing through`);
            res.writeHead(status, headers);
            res.end(raw);
            return;
          }
          try {
            body = inflate(raw);
          } catch (error) {
            log(`manifest could not be decompressed (${encoding}): ${error.message} — passing through`);
            res.writeHead(status, headers);
            res.end(raw);
            return;
          }
        }
        let output = body;
        if (status === 200) {
          try {
            const manifest = JSON.parse(body.toString('utf8'));
            if (needsRasterIcons(manifest)) {
              manifest.icons = [...PWA_ICONS, ...(Array.isArray(manifest.icons) ? manifest.icons : [])];
              output = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
              log('serving manifest with added PNG icons (upstream ships an SVG icon only)');
            }
          } catch (error) {
            log(`manifest parse failed, passing upstream bytes through: ${error.message}`);
            res.writeHead(status, headers);
            res.end(raw);
            return;
          }
        }
        // Whatever went in, what goes out is now plain JSON of known length.
        res.writeHead(status, {
          ...rewrittenResponseHeaders(headers),
          'content-type': 'application/manifest+json',
          'content-length': String(output.length),
          'cache-control': 'no-store',
        });
        res.end(output);
      });
    },
  );
  upstream.on('error', (error) => {
    log(`manifest upstream error: ${error.message}`);
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    if (!res.writableEnded) res.end('manifest upstream error\n');
  });
  upstream.end();
}

// ── settings on a non-loopback origin ──────────────────────────────────────
//
// The settings UI refuses to talk to the Host from any page whose address-bar
// hostname is not loopback: @deepseek-ai/dsh-client-ui-settings picks its
// persistence with `ctx.remote.$host.isLoopback ? "host" : "memory"`, and in
// "memory" mode the settings mirror is born `unavailable` and never issues a
// read. That is why Settings -> Models fails with "settings are unavailable
// in this browser" at https://PUBLIC_HOST — and why the Host-header trick
// above cannot help: `isLoopback` is derived in the browser from
// `location.hostname`, never from the request.
//
// The durable fix is to serve that one bundle with the gate forced open. The
// Host-side settings controller has no loopback gate of its own, and the
// request still crosses the same trusted-Host fence, authentik and the signed
// dsh cookie, so this does not widen who can reach the API — it only stops
// the page from disabling itself. Patching here survives dsh upgrades, which
// re-download the package and would wipe an edit inside it.
// Client bundles are not addressed as `/plugins/<id>/client.js`: dsh serves
// them through its combo route, `/plugins/??<id>/client.js[,<id>/client.js…]&rev=…`,
// where the whole plugin list is the *query string* and the pathname is just
// `/plugins/`. So match the full request URL, and accept the settings package
// wherever it appears in that list (the `.map` and the `-models`/`-general`
// siblings must not match: `/client.js` immediately after the package name
// already excludes the siblings, and the lookahead excludes source maps).
const SETTINGS_BUNDLE_RE = /\/plugins\/[^\s]*\bdsh-client-ui-settings\/client\.js(?!\.map)/u;
const PERSISTENCE_GATE_RE = /ctx\.remote\.\$host\.isLoopback\s*\?\s*"host"\s*:\s*"memory"/u;
// dshmarket's one-click restart; the bridge handles it itself (see the request
// handler) rather than letting a detached replacement race its supervision.
const MARKET_RESTART_PATH = '/dsh-market/restart';

function patchSettingsBundle(body) {
  const text = body.toString('utf8');
  if (!PERSISTENCE_GATE_RE.test(text)) return undefined;
  return Buffer.from(text.replace(PERSISTENCE_GATE_RE, '"host"'), 'utf8');
}

function serveSettingsBundle(req, res) {
  const requestHeaders = unconditionalRequestHeaders(req);
  delete requestHeaders['accept-encoding'];
  const upstream = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: 'GET',
      path: req.url,
      headers: requestHeaders,
    },
    (upstreamRes) => {
      const chunks = [];
      upstreamRes.on('data', (chunk) => chunks.push(chunk));
      upstreamRes.on('end', () => {
        const raw = Buffer.concat(chunks);
        const headers = { ...upstreamRes.headers };
        const status = upstreamRes.statusCode || 502;
        const encoding = String(headers['content-encoding'] ?? '').toLowerCase();
        let body = raw;
        if (status === 200 && encoding !== '' && encoding !== 'identity') {
          const inflate = {
            gzip: zlib.gunzipSync,
            deflate: zlib.inflateSync,
            br: zlib.brotliDecompressSync,
          }[encoding];
          if (inflate !== undefined) {
            try { body = inflate(raw); } catch { body = raw; }
          }
        }
        let output = body;
        if (status === 200) {
          const patched = patchSettingsBundle(body);
          if (patched === undefined) {
            log('settings bundle did not match the loopback persistence gate — passing it through unpatched');
          } else {
            output = patched;
            log('serving settings bundle with host persistence forced (non-loopback browser)');
          }
        }
        res.writeHead(status, {
          ...rewrittenResponseHeaders(headers),
          'content-length': String(output.length),
          'cache-control': 'no-store',
        });
        res.end(output);
      });
    },
  );
  upstream.on('error', (error) => {
    log(`settings bundle upstream error: ${error.message}`);
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    if (!res.writableEnded) res.end('dsh web upstream error\n');
  });
  upstream.end();
}

/**
 * Proxy one HTTP request upstream. When dsh answers 401 for the index even
 * though the browser sent a cookie (stale cookie, rotated signing secret, or a
 * restored ~/.dsh), retry once with the launch token so access self-heals
 * instead of stranding the user on dsh's "authentication required" page.
 */
function forward(req, res, upstreamPath, injected, allowRetry) {
  const retryable = allowRetry && req.method === 'GET' &&
    new URL(req.url || '/', 'http://placeholder').pathname === '/';
  const upstream = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: upstreamPath,
      headers: upstreamHeaders(req),
    },
    (upstreamRes) => {
      if (upstreamRes.statusCode === 401 && retryable && !injected && token !== null) {
        log('dsh answered 401 despite a cookie — retrying with a fresh launch token');
        upstreamRes.resume();
        forward(req, res, `/?token=${encodeURIComponent(token)}`, true, false);
        return;
      }
      const headers = { ...upstreamRes.headers };
      if (headers['set-cookie'] !== undefined) {
        headers['set-cookie'] = headers['set-cookie'].map(fixCookie);
      }
      // One document per bridge boot carries this, so a client that cached the
      // previous bundle drops it and fetches the current one.
      if (cacheClearArmed && req.method === 'GET' &&
          new URL(req.url || '/', 'http://placeholder').pathname === '/') {
        cacheClearArmed = false;
        headers['clear-site-data'] = '"cache"';
        log('sent Clear-Site-Data: cache — this client will re-fetch the changed bundle');
      }
      res.writeHead(upstreamRes.statusCode || 502, headers);
      upstreamRes.pipe(res);
    },
  );
  upstream.on('error', (error) => {
    log(`upstream error: ${error.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain' });
    }
    if (!res.writableEnded) res.end('dsh web upstream error\n');
  });
  if (injected && req.method === 'GET') {
    upstream.end(); // a rewritten/retried index request has no body to forward
  } else {
    req.pipe(upstream);
  }
}

function statusPayload() {
  const state = loadState();
  return {
    ready,
    pid: child === null ? null : child.pid,
    version: attemptVersion,
    hasToken: token !== null,
    portBusy,
    activeConnections,
    idleMinutes: IDLE_MINUTES,
    lastRequestAt: new Date(lastRequestAt).toISOString(),
    newestSessionMtime: newestSessionMtime === 0 ? null : new Date(newestSessionMtime).toISOString(),
    keepalive: fs.existsSync(KEEPALIVE_FILE),
    lastExit,
    update: {
      pinned: PINNED_CMD !== null,
      tag: PINNED_CMD === null ? DSH_UPDATE_TAG : null,
      everyHours: UPDATE_HOURS,
      lastCheckedAt: state.lastCheckAt === 0 ? null : new Date(state.lastCheckAt).toISOString(),
      targetVersion: state.targetVersion,
      lastGoodVersion: state.lastGoodVersion,
      badVersions: state.badVersions,
      cached: scanCachedInstalls().map((i) => i.version),
    },
    listen: `${LISTEN_HOST}:${LISTEN_PORT}`,
    upstream: `${UPSTREAM_HOST}:${UPSTREAM_PORT}`,
    publicHost: PUBLIC_HOST,
  };
}

// ── HTTP proxy ─────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  // The trust decision for everything below. A request that did not arrive for
  // PUBLIC_HOST (or, for diagnostics, a loopback or the bridge's own listen
  // address) never reaches dsh — and only after this check does the upstream
  // request get a loopback Host with Origin removed.
  const rejected = rejectReason(req);
  if (rejected !== null) {
    log(`refusing ${req.method ?? '?'} ${req.url ?? '?'}: ${rejected}`);
    res.writeHead(403, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
    res.end('forbidden\n');
    return;
  }

  if (req.url !== undefined && req.url.startsWith('/__bridge/')) {
    const iconName = ICON_BY_PATH.get(req.url.split('?')[0]);
    if (iconName !== undefined) {
      serveIcon(res, iconName);
      return;
    }
    // Diagnostics are not user activity: never let a status poll keep dsh alive.
    if (req.url.startsWith('/__bridge/start')) ensureChild();
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(`${JSON.stringify(statusPayload(), null, 2)}\n`);
    return;
  }
  lastRequestAt = Date.now();

  if (!ready) {
    ensureChild();
    const starting = Date.now() - childStartedAt > START_TIMEOUT_MS;
    if (wantsHtml(req) || !starting) {
      waitingPage(res, starting);
    } else {
      res.writeHead(503, { 'content-type': 'text/plain', 'retry-after': '3' });
      res.end('dsh web is starting\n');
    }
    return;
  }

  // Auto-auth: dsh only admits a browser through its one-time token URL. When
  // the browser has no auth cookie yet, replay the token upstream on its behalf
  // and relay dsh's 303 + Set-Cookie. The token never reaches the address bar.
  // dsh mints the cookie for the authority it sees, which is now the loopback
  // one the bridge forwards, so look for that name first — and for the public
  // one too, so a browser that still holds a pre-normalization cookie is not
  // re-injected on every load.
  const publicAuthority = authorityOf(req.headers.host);
  const upstreamAuthority = authorityOf(`${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  const cookieNames = [...new Set(
    [upstreamAuthority, publicAuthority].filter((a) => a !== undefined).map(cookieNameFor),
  )];
  const cookies = String(req.headers.cookie || '');
  const hasCookie = cookieNames.some((name) => cookieValueOf(cookies, name) !== undefined);
  const url = new URL(req.url || '/', 'http://placeholder');
  let upstreamPath = req.url;
  let injected = false;
  if (
    token !== null && !hasCookie && req.method === 'GET' && url.pathname === '/' &&
    !url.searchParams.has('token') && cookieNames.length > 0 &&
    injectAllowed(req.socket.remoteAddress || '?')
  ) {
    upstreamPath = `/?token=${encodeURIComponent(token)}`;
    injected = true;
    log(`auto-authenticating ${upstreamAuthority ?? '?'} (no dsh-auth cookie yet)`);
  }

  // dsh ships an SVG-only manifest icon, which Chrome parses as 0x0 and refuses
  // to install; swap in real raster icons so "Install app" works.
  if (iconsAvailable && req.method === 'GET' && url.pathname === MANIFEST_PATH) {
    serveManifest(req, res);
    return;
  }

  // Settings -> Models disables itself on a non-loopback origin; serve that one
  // bundle with the gate opened. See the note on patchSettingsBundle above.
  // Matched against the full URL: the bundle is the `??` combo form.
  if (req.method === 'GET' && SETTINGS_BUNDLE_RE.test(req.url ?? '')) {
    serveSettingsBundle(req, res);
    return;
  }

  // The market's one-click restart wants to spawn a detached replacement dsh.
  // Under the bridge that collides with its own supervision — two processes,
  // one port — so the bridge, which owns dsh's lifecycle here, answers the
  // request and restarts its child instead: stop it, and let the next request
  // cold-start it. That is also what loads a freshly updated plugin. The
  // market's client accepts 202 {ok:true} and then polls /dsh-market/status
  // for a new boot id, which the restarted dsh provides.
  if (req.method === 'POST' && url.pathname === MARKET_RESTART_PATH) {
    res.writeHead(202, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(`${JSON.stringify({ ok: true, bridge: true })}\n`);
    log('market restart requested — stopping dsh; the next request cold-starts it');
    setTimeout(() => stopChild('market restart'), 250).unref();
    return;
  }

  activeConnections += 1;
  res.on('close', () => { activeConnections -= 1; });
  forward(req, res, upstreamPath, injected, true);
});

// ── WebSocket / upgrade proxy (/api/remote.mux and friends) ────────────────

server.on('upgrade', (req, socket, head) => {
  lastRequestAt = Date.now();
  // Same trust decision as the HTTP path, and the same normalization: the
  // handshake must reach dsh as a loopback one, with an Origin that matches
  // that loopback Host and no forwarding trace.
  const rejected = rejectReason(req);
  if (rejected !== null) {
    log(`refusing upgrade ${req.url ?? '?'}: ${rejected}`);
    socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    return;
  }
  if (!ready) {
    socket.end('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 3\r\n\r\n');
    return;
  }
  const upstream = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      const lower = String(name).toLowerCase();
      if (lower === 'host') {
        raw += `${name}: ${UPSTREAM_AUTHORITY}\r\n`;
        continue;
      }
      if (lower === 'origin') continue; // added below, matching the authority
      if (FORWARDING_HEADERS.includes(lower)) continue;
      raw += `${name}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += `Origin: ${UPSTREAM_ORIGIN}\r\n\r\n`;
    upstream.write(raw);
    if (head !== undefined && head.length > 0) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  activeConnections += 1;
  const done = () => { activeConnections -= 1; };
  upstream.on('error', () => { try { socket.destroy(); } catch { /* ignore */ } done(); });
  upstream.on('close', done);
  socket.on('error', () => { try { upstream.destroy(); } catch { /* ignore */ } });
  socket.on('close', () => { try { upstream.destroy(); } catch { /* ignore */ } });
});

// ── lifecycle ──────────────────────────────────────────────────────────────

server.on('error', (error) => {
  log(`listen failed on ${LISTEN_HOST}:${LISTEN_PORT}: ${error.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log(`listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  log(`public host: ${PUBLIC_HOST}; idle stop: ${IDLE_MINUTES > 0 ? `${IDLE_MINUTES} min` : 'disabled'}`);
  log(PINNED_CMD === null
    ? `dsh package: auto (tag ${DSH_UPDATE_TAG}, refreshed every ${UPDATE_HOURS > 0 ? `${UPDATE_HOURS}h` : 'never'})`
    : 'dsh package: pinned by DSH_CMD (no version management)');
  log('dsh will start on the first request (on-demand)');
});

function shutdown(signal) {
  log(`received ${signal}; shutting down`);
  if (child !== null) {
    stopping = true;
    try { child.kill('SIGTERM'); } catch { /* ignore */ }
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
