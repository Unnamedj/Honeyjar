import { Router } from "express";
import { resolveBotUser } from "../lib/auth.js";
import { drop, poolStats, take } from "../fetcher/pool.js";

export const fetchRouter = Router();

/**
 * API del fetcher. Se autentica con el MISMO api_token que ya usa el bot para
 * reportar (Authorization: Bearer hh_...), asi el script no tiene que manejar
 * una credencial mas. El token identifica al usuario, no a la cuenta: el pool
 * de servers es compartido, lo que se reparte son jobIds distintos.
 */
async function requireBot(req, res, next) {
    const user = await resolveBotUser(req);
    if (!user) return res.status(401).json({ error: "token_invalido" });
    req.user = user;
    next();
}

fetchRouter.use(requireBot);

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
