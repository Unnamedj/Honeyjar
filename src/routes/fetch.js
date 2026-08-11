import { Router } from "express";
import { drop, poolStats, take } from "../fetcher/pool.js";
import { rateLimit } from "../lib/limit.js";

export const fetchRouter = Router();

// Techo alto a proposito: una cuenta pide jobIds cuando va a hopear (cada
// minuto o dos), asi que 600 por minuto deja correr decenas de bots desde la
// misma casa y aun asi frena a un script en loop vaciando el pool con un token
// que se filtro.
fetchRouter.use(
    rateLimit({
        windowMs: 60 * 1000,
        max: 600,
        error: "demasiados_pedidos",
        message: "Demasiados pedidos al pool desde esta IP.",
    })
);

/**
 * API del fetcher. UN SOLO secreto compartido (FETCH_TOKEN), no una cuenta
 * por usuario ni por sesion: el pool es el mismo para todos los bots, asi
 * que alcanza con que el script conozca este token fijo -- va embebido en
 * el .lua que se distribuye, no lo escribe cada cuenta a mano. Si
 * FETCH_TOKEN no esta seteado en el entorno, queda abierto (util en local).
 */
const FETCH_TOKEN = process.env.FETCH_TOKEN || "";

function requireFetchToken(req, res, next) {
    if (!FETCH_TOKEN) return next();
    const header = req.get("authorization") ?? "";
    const bearer = header.startsWith("Bearer ") ? header.slice(7).trim() : null;
    const raw = bearer || req.body?.token || req.query?.token;
    if (raw !== FETCH_TOKEN) return res.status(401).json({ error: "token_invalido" });
    next();
}

fetchRouter.use(requireFetchToken);

// ── /api/fetch/server: dame jobIds a los que saltar ──────────────────────────
fetchRouter.get("/server", (req, res) => {
    const size = Math.min(25, Math.max(1, Math.floor(Number(req.query?.size)) || 1));

    const raw = Math.floor(Number(req.query?.max));
    const maxPlayers = Number.isFinite(raw) && raw >= 0 && raw <= 100 ? raw : undefined;

    const jobIds = take(size, maxPlayers);
    if (!jobIds.length) {
        // 503 y no 200 con lista vacia: el script distingue "el pool no tiene
        // nada ahora" de "el fetcher no existe" y cae al listado de Roblox.
        return res.status(503).json({ error: "pool_vacio", jobIds: [] });
    }
    res.json({ ok: true, jobIds });
});

// ── /api/fetch/drop: ese jobId no sirve (lleno, cerrado, teleport fallido) ───
fetchRouter.post("/drop", (req, res) => {
    const jobId = typeof req.body?.jobId === "string" ? req.body.jobId.slice(0, 64) : "";
    if (!jobId) return res.status(400).json({ error: "jobid_faltante" });

    drop(jobId);
    // Se devuelve el reemplazo en la misma respuesta para que un teleport
    // fallido no cueste dos vueltas de red.
    const [replacement] = take(1);
    res.json({ ok: true, jobIds: replacement ? [replacement] : [] });
});

// ── /api/fetch/stats: estado del pool (debug y panel) ────────────────────────
fetchRouter.get("/stats", (_req, res) => {
    res.json(poolStats());
});
