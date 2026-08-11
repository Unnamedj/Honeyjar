/**
 * Limitador de requests por ventana deslizante, en memoria.
 *
 * Sin dependencias y sin Redis a proposito: el hub corre en una sola instancia
 * de Railway, asi que un Map alcanza y se pierde en cada deploy (que es lo
 * peor que puede pasar: alguien recupera sus intentos antes de tiempo). Si
 * algun dia hay mas de una instancia, esto pasa a ser un limite POR INSTANCIA
 * y hay que moverlo a la base o a un Redis.
 *
 * La ventana es deslizante de verdad (se guardan los timestamps, no un
 * contador con reset): con contador, quien agota el cupo espera al borde de la
 * ventana y dispara el doble junto.
 */

/** Cada cuanto se barren las claves muertas. No hace falta que sea fino. */
const SWEEP_MS = 10 * 60 * 1000;

/**
 * @param {object}   options
 * @param {number}   options.windowMs   tamano de la ventana
 * @param {number}   options.max        cuantos requests entran en la ventana
 * @param {string}   options.message    lo que ve el usuario (la UI lo muestra tal cual)
 * @param {string}   [options.error]    codigo de error para el JSON
 * @param {Function} [options.by]       de que se saca la clave (por defecto la IP)
 * @param {Function} [options.countIf]  si devuelve false, ese request no gasta cupo
 */
export function rateLimit({
    windowMs,
    max,
    message,
    error = "demasiados_intentos",
    by = (req) => req.ip ?? "sin-ip",
    countIf = null,
}) {
    /** @type {Map<string, number[]>} clave -> timestamps dentro de la ventana */
    const hits = new Map();
    let lastSweep = Date.now();

    function fresh(key, now) {
        const list = hits.get(key);
        if (!list) return [];
        const alive = list.filter((t) => now - t < windowMs);
        if (alive.length) hits.set(key, alive);
        else hits.delete(key);
        return alive;
    }

    function sweep(now) {
        if (now - lastSweep < SWEEP_MS) return;
        lastSweep = now;
        for (const key of [...hits.keys()]) fresh(key, now);
    }

    return function limiter(req, res, next) {
        const now = Date.now();
        sweep(now);

        const key = String(by(req) ?? "sin-clave");
        const alive = fresh(key, now);

        if (alive.length >= max) {
            const retryMs = windowMs - (now - alive[0]);
            res.setHeader("Retry-After", String(Math.ceil(retryMs / 1000)));
            return res.status(429).json({ error, message, retryAfter: Math.ceil(retryMs / 1000) });
        }

        // El intento se cuenta cuando la respuesta ya salio: asi countIf puede
        // mirar el status y, por ejemplo, no gastarle cupo a quien acerto la
        // contrasena -- el limite es contra el que prueba, no contra el que entra.
        res.on("finish", () => {
            if (countIf && !countIf(res)) return;
            const list = fresh(key, Date.now());
            list.push(Date.now());
            hits.set(key, list);
        });

        next();
    };
}

/** Solo cuenta el intento si la respuesta fue un error. */
export const onlyFailures = (res) => res.statusCode >= 400;
