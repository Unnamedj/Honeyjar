import { getJson } from "./http.js";
import { loadProxies, nextProxy, penalizedCount, proxyCount, rotatingCount } from "./proxies.js";

/**
 * FETCHER -- pool de servers frescos para el auto-hop.
 *
 * El problema que resuelve: cada cuenta corriendo el collector pagina
 * games.roblox.com por su cuenta cada vez que quiere saltar. Con varias cuentas
 * eso son decenas de requests por minuto desde la misma IP -> 429 -> el listado
 * empieza a devolver nil -> "ni hace hop". Ademas todas las cuentas ven la misma
 * primera pagina, asi que terminan saltando al mismo server.
 *
 * Aca el panel scrapea el listado UNA vez, en segundo plano, repartido entre
 * proxies con IP rotativa, y guarda los jobIds en un pool. Cada bot pide un
 * jobId y se lleva uno que NADIE mas se llevo (dispensado = reservado un rato).
 * Resultado: cero rate-limit del lado del bot, servers frescos, y dos cuentas
 * nunca reciben el mismo destino.
 */

function envInt(name, fallback, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
    const n = Math.floor(Number(process.env[name]));
    return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

const PLACE_ID = envInt("FETCH_PLACE_ID", 109983668079237, { min: 1 });

// Umbral por defecto de "server chico". El bot puede pedir otro por query.
const MAX_PLAYERS = envInt("FETCH_MAX_PLAYERS", 2, { min: 0, max: 100 });

const MAX_PAGES = envInt("FETCH_MAX_PAGES", 10, { min: 1, max: 50 });
const MAX_SERVERS = envInt("FETCH_MAX_SERVERS", 20_000, { min: 100 });

// Un jobId dispensado se reserva este rato: si el bot llego bien, el server ya
// no esta vacio; si el teleport fallo, vuelve a la rueda solo.
const RECYCLE_MS = envInt("FETCH_RECYCLE_MS", 90_000, { min: 5_000 });

// Un listado de hace mas de esto ya no dice nada del server: en un juego activo
// se llena en minutos. Mandar a un bot ahi es gastarle un teleport.
const STALE_MS = envInt("FETCH_STALE_MS", 8 * 60_000, { min: 30_000 });

const MIN_DELAY = envInt("FETCH_MIN_DELAY_MS", 120, { min: 0 });
const MAX_DELAY = envInt("FETCH_MAX_DELAY_MS", 10_000, { min: 1_000 });

// Cuantos loops de scraping corren en paralelo. Se calcula DESPUES de parsear
// los proxies (no solo mirar si PROXIES esta seteada) porque el numero
// correcto depende de cuantos hay: con un solo proxy, muchos workers
// concurrentes abren varios tuneles CONNECT al mismo gateway al mismo tiempo,
// lo cual genera errores de conexion (visto en produccion: 12 errores, el
// proxy terminaba penalizado seguido). Con pocos proxies el tope se queda
// bajo por eso. Con MUCHOS proxies reales (cientos, miles) ese riesgo
// desaparece -- cada worker sale por una IP distinta, no hay nada que
// saturar -- asi que el tope sube: mas paralelismo scrapeando significa mas
// paginas por segundo, y por lo tanto mas servers "chicos" encontrados antes
// de que se llenen. El techo de 24 no es por cuidar los proxies sino por no
// mandarle a games.roblox.com mas requests por segundo de las que hacen
// falta (el pool ya tiene su propio tope de tamaño en MAX_SERVERS).
function defaultWorkers(proxyN) {
    if (!proxyN) return 2; // sin proxies no hay nada que paralelizar de mas
    return Math.min(24, Math.max(2, proxyN * 3));
}

// ── Estado ────────────────────────────────────────────────────────────────────

/** jobId -> { id, playing, maxPlayers, seenAt, takenAt } */
const servers = new Map();
/** jobIds nunca dispensados y por debajo del umbral: cola FIFO para dispensar en O(1). */
let freshQueue = [];
/** jobIds que un bot reporto como inservibles (lleno, no existe): no se re-cachean. */
const dropped = new Map(); // jobId -> timestamp

const stats = {
    startedAt: Date.now(),
    running: false,
    workers: 0,
    scraped: 0,
    dispensed: 0,
    drops: 0,
    rateLimits: 0,
    errors: 0,
    lastError: null,
    lastScrapeAt: 0,
    delayMs: MIN_DELAY,
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * El ultimo error se muestra en el panel, asi que nunca puede arrastrar la
 * password de un proxy: si el mensaje trae credenciales embebidas en una URL,
 * se tapan antes de guardarlo.
 */
function recordError(message) {
    stats.errors += 1;
    stats.lastError = String(message).replace(/\/\/[^/@\s]+@/g, "//***@").slice(0, 200);
}

// ── Scraping ──────────────────────────────────────────────────────────────────

// Este endpoint toma el PLACE id (109983668079237), no el universe id.
// Comprobado contra la API: con el place da 200 y servers reales; con el
// universe (7709344486) da 400 "The place is invalid.". Es ademas el mismo id
// que el script le pasa a TeleportToPlaceInstance, que es lo que tiene que ser:
// un jobId de otro place no se puede joinear.
const ENDPOINTS = [
    `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Asc`,
    `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Asc`,
    `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Desc`,
];

/**
 * Mete una pagina del listado de Roblox en el pool y devuelve cuantos jobIds
 * eran nuevos. Es el unico camino por el que entran servers, asi que tambien
 * sirve para alimentar el pool desde otra fuente (o desde un test) sin tocar
 * el scraper.
 */
export function ingest(page) {
    if (!page || !Array.isArray(page.data)) return 0;
    const now = Date.now();
    let nuevos = 0;

    for (const raw of page.data) {
        const id = typeof raw?.id === "string" ? raw.id : null;
        if (!id || dropped.has(id)) continue;

        const playing = Number(raw.playing);
        const maxPlayers = Number(raw.maxPlayers);
        if (!Number.isFinite(playing)) continue;
        // Un server lleno no sirve ni como fallback.
        if (Number.isFinite(maxPlayers) && playing >= maxPlayers) continue;

        const known = servers.get(id);
        if (known) {
            // Refresca el conteo: el mismo jobId con menos gente vuelve a ser util.
            known.playing = playing;
            known.seenAt = now;
            continue;
        }

        servers.set(id, {
            id,
            playing,
            maxPlayers: Number.isFinite(maxPlayers) ? maxPlayers : 0,
            seenAt: now,
            takenAt: 0,
        });
        nuevos += 1;
        if (playing <= MAX_PLAYERS) freshQueue.push(id);
    }

    stats.scraped += nuevos;
    if (nuevos) stats.lastScrapeAt = now;
    return nuevos;
}

async function scrapeLoop(workerId) {
    const BASE_COOLDOWN = 2_000;
    const IDLE_COOLDOWN = 10_000;

    while (stats.running) {
        const endpoint = ENDPOINTS[Math.floor(Math.random() * ENDPOINTS.length)];
        let cursor = null;
        let nuevos = 0;
        let pages = 0;

        while (stats.running && pages < MAX_PAGES) {
            const url = cursor ? `${endpoint}&cursor=${encodeURIComponent(cursor)}` : endpoint;
            await sleep(stats.delayMs);

            const proxy = nextProxy();

            // Hay proxies configurados pero TODOS estan en penalizacion ahora
            // mismo: nextProxy() devuelve null igual que cuando no hay proxies,
            // pero acomodar eso como "pedido directo" es lo que causaba el loop
            // visto en produccion -- el unico proxy se penaliza, los workers
            // caen todos juntos a la IP de Railway, Roblox les tira 429 en
            // rafaga, delayMs se va al techo y no hay forma de que se recupere
            // porque el siguiente intento vuelve a caer directo. Mejor esperar
            // a que salga de penalizacion en vez de pedirle nada a Roblox.
            if (!proxy && proxyCount() > 0) {
                await sleep(2_000);
                break;
            }

            const res = await getJson(url, { proxy, timeoutMs: proxy ? 15_000 : 8_000 });

            if (!res.ok) {
                if (res.status === 429) {
                    stats.rateLimits += 1;
                    // Sin proxies esto pasa seguido y la unica salida es ir mas
                    // despacio; con proxies rotativos casi no deberia verse.
                    stats.delayMs = Math.min(MAX_DELAY, stats.delayMs + 250);
                } else {
                    recordError(`${res.status || "net"}: ${res.error}`);
                }
                break;
            }

            // Cada respuesta buena recupera un poco de velocidad.
            if (stats.delayMs > MIN_DELAY) stats.delayMs = Math.max(MIN_DELAY, stats.delayMs - 25);

            const encontrados = ingest(res.data);
            nuevos += encontrados;
            pages += 1;

            // Una pagina entera ya conocida = estamos releyendo lo mismo; cortar
            // y arrancar de nuevo por otro endpoint sale mas barato que seguir.
            if (encontrados === 0 && pages > 1) break;

            cursor = res.data?.nextPageCursor || null;
            if (!cursor) break;
        }

        if (!stats.running) break;
        await sleep(nuevos > 0 ? BASE_COOLDOWN : IDLE_COOLDOWN);
        void workerId;
    }
}

// ── Dispensado ────────────────────────────────────────────────────────────────

function usable(entry, now, maxPlayers) {
    if (!entry) return false;
    if (now - entry.seenAt > STALE_MS) return false;
    if (entry.takenAt && now - entry.takenAt < RECYCLE_MS) return false;
    return entry.playing <= maxPlayers;
}

/**
 * Reserva y devuelve hasta `count` jobIds. Prioriza los que nunca se
 * dispensaron (cola FIFO) y recien despues barre el resto del pool buscando
 * reciclados. Reservar es lo que evita que dos cuentas salten al mismo server.
 */
export function take(count = 1, maxPlayers = MAX_PLAYERS) {
    const now = Date.now();
    const out = [];

    // 1) Frescos: O(1) por candidato.
    while (out.length < count && freshQueue.length) {
        const id = freshQueue.shift();
        const entry = servers.get(id);
        if (!usable(entry, now, maxPlayers)) continue;
        entry.takenAt = now;
        out.push(id);
    }

    // 2) Barrido del resto del pool, ordenando por menos gente y visto mas
    //    recientemente. Entran los reciclados (ya vencio su reserva) y tambien
    //    los que nunca se dispensaron pero quedaron fuera de la cola fresca por
    //    tener mas gente que el umbral por defecto: si ESTE bot pidio un umbral
    //    mas alto, para el si sirven. Los que ya salieron en (1) quedan afuera
    //    solos, porque se les acaba de setear takenAt y usable() los rechaza.
    if (out.length < count) {
        const candidatos = [];
        for (const entry of servers.values()) {
            if (usable(entry, now, maxPlayers)) candidatos.push(entry);
        }
        candidatos.sort((a, b) => a.playing - b.playing || b.seenAt - a.seenAt);
        for (const entry of candidatos) {
            if (out.length >= count) break;
            entry.takenAt = now;
            out.push(entry.id);
        }
    }

    stats.dispensed += out.length;
    return out;
}

/** El bot no pudo entrar (lleno, cerrado): se saca del pool y no vuelve a entrar. */
export function drop(jobId) {
    if (typeof jobId !== "string" || !jobId) return false;
    const existia = servers.delete(jobId);
    dropped.set(jobId, Date.now());
    if (existia) stats.drops += 1;
    return existia;
}

export function poolStats() {
    const now = Date.now();
    let disponibles = 0;
    let reservados = 0;
    let viejos = 0;
    for (const entry of servers.values()) {
        if (now - entry.seenAt > STALE_MS) viejos += 1;
        else if (entry.takenAt && now - entry.takenAt < RECYCLE_MS) reservados += 1;
        else if (entry.playing <= MAX_PLAYERS) disponibles += 1;
    }
    return {
        running: stats.running,
        placeId: PLACE_ID,
        total: servers.size,
        disponibles,
        reservados,
        frescos: freshQueue.length,
        viejos,
        descartados: dropped.size,
        proxies: proxyCount(),
        proxiesRotativos: rotatingCount(),
        proxiesPenalizados: penalizedCount(),
        workers: stats.running ? stats.workers : 0,
        delayMs: stats.delayMs,
        delayBaseMs: MIN_DELAY,
        scrapeados: stats.scraped,
        dispensados: stats.dispensed,
        descartesBot: stats.drops,
        rateLimits: stats.rateLimits,
        errores: stats.errors,
        ultimoError: stats.lastError,
        ultimoScrapeHaceS: stats.lastScrapeAt ? Math.floor((now - stats.lastScrapeAt) / 1000) : null,
        uptimeS: Math.floor((now - stats.startedAt) / 1000),
        maxPlayers: MAX_PLAYERS,
        recycleS: Math.floor(RECYCLE_MS / 1000),
        staleS: Math.floor(STALE_MS / 1000),
    };
}

// ── Mantenimiento ─────────────────────────────────────────────────────────────

function cleanup() {
    const now = Date.now();

    for (const [id, entry] of servers) {
        if (now - entry.seenAt > STALE_MS) servers.delete(id);
    }
    // Un jobId descartado se olvida despues de un rato: los servers se vacian y
    // el mismo id puede volver a servir.
    for (const [id, at] of dropped) {
        if (now - at > 30 * 60_000) dropped.delete(id);
    }

    // La cola de frescos junta ids que ya se dispensaron o vencieron.
    if (freshQueue.length > 1_000) {
        freshQueue = freshQueue.filter((id) => {
            const entry = servers.get(id);
            return entry && entry.takenAt === 0;
        });
    }

    // Tope duro de memoria: se van los mas viejos.
    if (servers.size > MAX_SERVERS) {
        const porEdad = [...servers.values()].sort((a, b) => a.seenAt - b.seenAt);
        for (const entry of porEdad.slice(0, servers.size - MAX_SERVERS)) servers.delete(entry.id);
    }
}

let cleanupTimer = null;

/**
 * Arranca el scraper. Por defecto solo si hay proxies configurados: sin ellos
 * todo sale por la IP de Railway y el 429 es cuestion de minutos. FETCHER=1
 * lo fuerza igual (util para probar en local), FETCHER=0 lo apaga siempre.
 */
export function startFetcher() {
    const proxies = loadProxies();
    const forzado = process.env.FETCHER;

    if (forzado === "0" || forzado === "off" || forzado === "false") {
        console.log("[fetcher] apagado por FETCHER=0");
        return false;
    }
    if (!proxies && forzado !== "1" && forzado !== "on" && forzado !== "true") {
        console.log(
            "[fetcher] sin proxies configurados (PROXIES) -- apagado.\n" +
            "  Los bots siguen hopeando solos contra games.roblox.com, como hasta ahora.\n" +
            "  Para prenderlo sin proxies (se come rate-limits): FETCHER=1"
        );
        return false;
    }

    const workers = envInt("FETCH_WORKERS", defaultWorkers(proxies), { min: 1, max: 32 });
    stats.workers = workers;
    stats.running = true;
    stats.startedAt = Date.now();
    for (let i = 0; i < workers; i += 1) {
        setTimeout(() => {
            scrapeLoop(i).catch((err) => {
                recordError(err.message);
                console.error(`[fetcher] worker ${i} murio:`, err.message);
            });
        }, i * 400);
    }
    cleanupTimer = setInterval(cleanup, 60_000);
    cleanupTimer.unref?.();

    console.log(
        `[fetcher] ${workers} workers scrapeando el place ${PLACE_ID} ` +
        `(${proxies} proxies, umbral <=${MAX_PLAYERS} jugadores)`
    );
    return true;
}

export function stopFetcher() {
    stats.running = false;
    if (cleanupTimer) clearInterval(cleanupTimer);
    cleanupTimer = null;
}
