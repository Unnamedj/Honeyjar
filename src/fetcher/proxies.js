import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Raiz del repo (dos niveles arriba de src/fetcher/), no el cwd del proceso:
// asi el archivo se encuentra sin importar desde donde te arranque Railway.
const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * Pool de proxies para el scraper de servers.
 *
 * El formato que usa Nettify (y casi todos los proveedores residenciales) mete
 * la configuracion adentro del usuario, no en la URL:
 *
 *     0fphvc-country-SG-session-aub815-time-1:x7526zfdu9fd@eu.nettify.xyz:8080
 *      ^user  ^pais      ^sesion sticky ^min  ^password     ^host          ^port
 *
 * `session-<id>` es lo que fija la IP de salida: mientras el id no cambie, el
 * proveedor te devuelve siempre la misma IP (durante `time-<minutos>`). Para un
 * scraper eso es exactamente lo que NO queremos: si repetimos el mismo session
 * id, todas las requests salen de una sola IP y games.roblox.com nos tira 429
 * igual que sin proxy. Por eso, por defecto, cada request rota el session id ->
 * IP nueva -> el rate-limit nunca llega a acumularse.
 */

const RANDOM_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

// `session-xxxx` o `sessid-xxxx`, con `-` o `_` de separador (cada proveedor lo
// escribe distinto). Se captura la clave para poder reescribir solo el valor.
const SESSION_RE = /((?:^|[-_])(?:session|sessid|sid))([-_])([A-Za-z0-9]+)/gi;

function randomId(len = 8) {
    const bytes = crypto.randomBytes(len);
    let out = "";
    for (let i = 0; i < len; i += 1) out += RANDOM_ALPHABET[bytes[i] % RANDOM_ALPHABET.length];
    return out;
}

/** true si el usuario del proxy trae un id de sesion sticky que podemos rotar. */
export function hasSession(username) {
    SESSION_RE.lastIndex = 0;
    return Boolean(username) && SESSION_RE.test(username);
}

/** Reemplaza el id de sesion por uno nuevo: misma cuenta, IP de salida distinta. */
export function rotateSession(username) {
    if (!username) return username;
    return username.replace(SESSION_RE, (_m, key, sep) => `${key}${sep}${randomId()}`);
}

/**
 * Acepta los formatos habituales en los que se pegan proxies:
 *   http://user:pass@host:port   user:pass@host:port
 *   host:port:user:pass          user:pass:host:port
 *   host:port
 */
export function parseProxy(raw) {
    if (!raw) return null;
    const s = String(raw).trim();
    if (!s || s.startsWith("#")) return null;

    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(s)) {
        try {
            const u = new URL(s);
            if (!u.hostname) return null;
            return {
                host: u.hostname,
                port: Number(u.port) || 8080,
                username: u.username ? decodeURIComponent(u.username) : null,
                password: u.password ? decodeURIComponent(u.password) : null,
            };
        } catch {
            return null;
        }
    }

    if (s.includes("@")) {
        const at = s.lastIndexOf("@");
        const creds = s.slice(0, at);
        const [host, portStr] = s.slice(at + 1).split(":");
        const colon = creds.indexOf(":");
        if (!host || !portStr || colon === -1) return null;
        return {
            host,
            port: Number(portStr) || 8080,
            username: creds.slice(0, colon) || null,
            password: creds.slice(colon + 1) || null,
        };
    }

    const parts = s.split(":");
    if (parts.length === 2) {
        const [host, port] = parts;
        return host ? { host, port: Number(port) || 8080, username: null, password: null } : null;
    }
    if (parts.length === 4) {
        // Desambigua host:port:user:pass de user:pass:host:port por cual de los
        // dos campos parece un puerto.
        const secondIsPort = /^\d{2,5}$/.test(parts[1]);
        const [a, b, c, d] = parts;
        return secondIsPort
            ? { host: a, port: Number(b), username: c || null, password: d || null }
            : { host: c, port: Number(d) || 8080, username: a || null, password: b || null };
    }

    return null;
}

/**
 * Si PROXY_ROTATE_SESSION=0, nunca se inventa un session-id nuevo: la linea
 * se usa tal cual llego. Tiene sentido apagarlo cuando cada linea YA es una
 * sesion distinta y real (por ejemplo, varios miles de lineas compradas o
 * generadas en el panel del proveedor) -- ahi no hace falta rotar nada
 * nosotros, y si el proveedor exige que el session-id sea uno de los que ya
 * asigno, pisarlo con uno inventado puede terminar cayendo a una IP por
 * defecto en vez de fallar limpio, que es dificil de distinguir de un
 * rate-limit real. Por defecto queda prendido: es lo que conviene cuando hay
 * pocas lineas (o una sola) y se necesitan muchas IPs distintas de ahi.
 */
function rotationEnabled() {
    const v = String(process.env.PROXY_ROTATE_SESSION ?? "1").trim().toLowerCase();
    return v !== "0" && v !== "false" && v !== "off";
}

/** URL http:// lista para HttpsProxyAgent, con el session id ya rotado si toca. */
export function proxyUrl(proxy, { rotate = rotationEnabled() } = {}) {
    const user = rotate ? rotateSession(proxy.username) : proxy.username;
    const auth = user
        ? `${encodeURIComponent(user)}:${encodeURIComponent(proxy.password ?? "")}@`
        : "";
    return `http://${auth}${proxy.host}:${proxy.port}`;
}

// ── El pool ───────────────────────────────────────────────────────────────────

const proxies = [];
const backoff = new Map(); // clave del proxy -> timestamp hasta el que se saltea
let cursor = 0;

function key(proxy) {
    return `${proxy.host}:${proxy.port}:${proxy.username ?? ""}`;
}

function envList() {
    const out = [];
    // PROXIES admite coma o salto de linea: pegar la lista entera en Railway sin
    // tener que reformatearla.
    for (const chunk of String(process.env.PROXIES ?? "").split(/[,\n]/)) {
        if (chunk.trim()) out.push(chunk.trim());
    }
    // Carga archivos de proxies: proxies.txt, proxies1.txt, proxies2.txt, etc.
    // Util cuando hay muchas lineas (10k+) y el textarea de Railway tiene limite.
    // Se busca tanto al lado del repo (cwd) como en la raiz real del modulo,
    // por si Railway arranca el proceso desde otro directorio.
    const names = ["proxies.txt"];
    for (let i = 1; i <= 10; i += 1) names.push(`proxies${i}.txt`);

    const explicit = process.env.PROXY_FILE;
    const candidates = explicit
        ? [explicit, path.join(REPO_ROOT, explicit)]
        : names.flatMap((n) => [n, path.join(REPO_ROOT, n)]);

    const seen = new Set();
    for (const file of candidates) {
        const resolved = path.resolve(file);
        if (seen.has(resolved)) continue;
        seen.add(resolved);
        if (fs.existsSync(resolved)) {
            let n = 0;
            for (const raw of fs.readFileSync(resolved, "utf8").split("\n")) {
                const line = raw.trim();
                if (line && !line.startsWith("#")) { out.push(line); n += 1; }
            }
            console.log(`[fetcher] ${n} lineas leidas de ${resolved}`);
        }
    }
    return out;
}

export function loadProxies() {
    proxies.length = 0;
    backoff.clear();
    cursor = 0;

    let malos = 0;
    for (const raw of envList()) {
        const parsed = parseProxy(raw);
        if (parsed) proxies.push(parsed);
        else malos += 1;
    }

    // Con session id rotativo un solo proxy alcanza para muchas IPs; sin el, la
    // cantidad de proxies es el techo real de paralelismo.
    const rotativos = proxies.filter((p) => hasSession(p.username)).length;
    if (proxies.length) {
        console.log(
            `[fetcher] ${proxies.length} proxies cargados` +
            (rotativos ? ` (${rotativos} con sesion rotativa)` : "") +
            (malos ? ` -- ${malos} lineas ilegibles ignoradas` : "")
        );
    } else if (malos) {
        console.warn(`[fetcher] ninguna de las ${malos} lineas de PROXIES se pudo parsear`);
    }
    return proxies.length;
}

export function proxyCount() {
    return proxies.length;
}

export function rotatingCount() {
    return proxies.filter((p) => hasSession(p.username)).length;
}

/**
 * Siguiente proxy del round-robin, salteando los que estan penalizados. Si
 * todos lo estan devuelve null: el llamador sale directo (mejor una request
 * lenta desde la IP de Railway que ninguna).
 */
export function nextProxy() {
    if (!proxies.length) return null;
    const now = Date.now();
    for (let i = 0; i < proxies.length; i += 1) {
        const proxy = proxies[cursor % proxies.length];
        cursor = (cursor + 1) % proxies.length;
        const until = backoff.get(key(proxy)) ?? 0;
        if (until <= now) return proxy;
    }
    return null;
}

/** Saca un proxy de la rotacion un rato (murio el socket, 407, timeouts). */
export function penalize(proxy, ms = 30_000) {
    if (!proxy) return;
    backoff.set(key(proxy), Date.now() + ms);
}

export function penalizedCount() {
    const now = Date.now();
    let n = 0;
    for (const until of backoff.values()) if (until > now) n += 1;
    return n;
}
