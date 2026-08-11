import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Raiz del repo (dos niveles arriba de src/fetcher/), no el cwd del proceso:
// asi el archivo se encuentra sin importar desde donde te arranque Railway.
const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * Pool de proxies para el scraper de servers.
 *
 * Los proveedores residenciales (Pulse, Nettify y casi todos) meten la
 * configuracion adentro del usuario, no en la URL:
 *
 *     usuario_session-abc123_lifetime-30:password@gateway.pulseproxy.com:8080
 *      ^user  ^sesion sticky ^minutos     ^password ^host                ^port
 *
 * `session-<id>` FIJA la IP de salida: mientras ese id no cambie, el proveedor
 * te devuelve siempre la misma IP. Para un scraper eso es justo lo contrario de
 * lo que hace falta.
 *
 * La estrategia es la del hopper de referencia, que es la que esta probada en
 * produccion: en vez de inventar un session id nuevo por request, se BORRAN los
 * parametros de sesion y se deja que el gateway rote solo. Es lo que hay que
 * hacer con Pulse — el gateway ya entrega una IP distinta por conexion cuando
 * no le pinneas sesion, y pisarle el id con uno inventado que el no asigno
 * puede terminar cayendo a una IP por defecto en vez de fallar limpio (que es
 * dificil de distinguir de un rate-limit real).
 *
 * Tampoco hay penalizacion de proxies. Al borrar la sesion, mil lineas del
 * mismo gateway colapsan a una sola identidad, asi que sacar "un" proxy de la
 * rotacion por un timeout sacaba de hecho al pool entero y dejaba al scraper
 * girando en falso. El de referencia simplemente reintenta con el siguiente, y
 * el backoff adaptativo del delay es el unico freno.
 */

// Igual que el hopper de referencia (`_session-…`, `_lifetime-…`), pero
// aceptando tambien `-` de separador y los alias que usan otros proveedores,
// porque las lineas de Nettify vienen como `-session-aub815-time-1`.
const SESSION_RE = /[-_](?:session|sessid|sid|lifetime|time|ttl)[-_][A-Za-z0-9]+/gi;

/**
 * Saca los parametros de sesion del usuario/password. Lo que queda es la cuenta
 * "pelada", que es lo que hace que el gateway rote la IP por su cuenta.
 */
export function stripSessionParams(auth) {
    if (!auth) return auth;
    return auth.replace(SESSION_RE, "").replace(/[-_]+$/, "");
}

/** true si la linea trae sesion sticky (o sea: hay algo que borrar para rotar). */
export function hasSession(username) {
    SESSION_RE.lastIndex = 0;
    return Boolean(username) && SESSION_RE.test(username);
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
 * PROXY_STRIP_SESSION=0 usa las lineas tal cual llegaron. Solo tiene sentido si
 * tu proveedor exige la sesion pinneada y vos QUERES la IP fija; para scrapear
 * es lo que no conviene. Por defecto viene prendido.
 */
function stripEnabled() {
    const v = String(process.env.PROXY_STRIP_SESSION ?? "1").trim().toLowerCase();
    return v !== "0" && v !== "false" && v !== "off";
}

/** URL http:// lista para HttpsProxyAgent, ya sin los parametros de sesion. */
export function proxyUrl(proxy, { strip = stripEnabled() } = {}) {
    const user = strip ? stripSessionParams(proxy.username) : proxy.username;
    const pass = strip ? stripSessionParams(proxy.password) : proxy.password;
    const auth = user ? `${encodeURIComponent(user)}:${encodeURIComponent(pass ?? "")}@` : "";
    return `http://${auth}${proxy.host}:${proxy.port}`;
}

// ── El pool ───────────────────────────────────────────────────────────────────

const proxies = [];

// Orden barajado, igual que el de referencia: se recorre una vuelta completa y
// recien ahi se vuelve a barajar. Round-robin puro sobre una lista ordenada
// manda todas las requests del mismo segundo al mismo bloque de IPs.
let order = [];
let orderIndex = 0;
let lastUsed = null;

function shuffle(arr) {
    for (let i = arr.length - 1; i > 0; i -= 1) {
        const j = Math.floor(Math.random() * (i + 1));
        [arr[i], arr[j]] = [arr[j], arr[i]];
    }
}

function resetOrder() {
    order = proxies.slice();
    orderIndex = 0;
    if (!order.length) return;
    shuffle(order);
    // Que la vuelta nueva no arranque con el mismo proxy con el que termino la
    // anterior: seria la unica repeticion inmediata de todo el ciclo.
    if (lastUsed && order.length > 1 && order[0] === lastUsed) {
        for (let i = 1; i < order.length; i += 1) {
            if (order[i] !== lastUsed) {
                [order[0], order[i]] = [order[i], order[0]];
                break;
            }
        }
    }
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
    order = [];
    orderIndex = 0;
    lastUsed = null;

    let malos = 0;
    for (const raw of envList()) {
        const parsed = parseProxy(raw);
        if (parsed) proxies.push(parsed);
        else malos += 1;
    }

    resetOrder();

    const rotativos = rotatingCount();
    const unicos = uniqueCount();
    if (proxies.length) {
        console.log(
            `[fetcher] ${proxies.length} proxies cargados` +
            (rotativos ? ` (${rotativos} con sesion sticky que se borra para rotar)` : "") +
            (unicos < proxies.length ? ` -- ${unicos} identidades distintas tras borrarla` : "") +
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
 * Cuantas credenciales REALMENTE distintas quedan despues de borrar la sesion.
 * Con 10.000 lineas del mismo gateway esto da 1, y esta bien: la rotacion la
 * hace el proveedor, no la lista. Sirve para no leer "10.000 proxies" como si
 * fueran 10.000 IPs simultaneas.
 */
export function uniqueCount() {
    const set = new Set();
    for (const p of proxies) {
        set.add(`${p.host}:${p.port}:${stripSessionParams(p.username) ?? ""}`);
    }
    return set.size;
}

/**
 * Siguiente proxy de la vuelta barajada. Nunca devuelve null habiendo proxies
 * cargados: no hay penalizacion que pueda dejar al scraper sin salida.
 */
export function nextProxy() {
    if (!proxies.length) return null;
    if (orderIndex >= order.length) resetOrder();
    const proxy = order[orderIndex];
    orderIndex += 1;
    lastUsed = proxy;
    return proxy;
}
