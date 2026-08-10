import { Router } from "express";
import { one, query } from "../db.js";
import { avatarIsFresh, fetchAvatar } from "../lib/roblox.js";

export const botRouter = Router();

const BUCKET_MS = 5 * 60 * 1000;
const STATUS_KINDS = new Set(["idle", "collecting", "waiting", "hopping", "stopped"]);

function beatInterval() {
    const raw = Number(process.env.BEAT_INTERVAL_MS);
    return Number.isFinite(raw) && raw >= 1000 ? Math.floor(raw) : 5000;
}

function clampInt(value, min, max, fallback = 0) {
    const n = Math.floor(Number(value));
    if (!Number.isFinite(n)) return fallback;
    return Math.min(max, Math.max(min, n));
}

function text(value, max = 120) {
    if (value === null || value === undefined) return null;
    const s = String(value).trim();
    return s ? s.slice(0, max) : null;
}

/** El token del bot va en Authorization: Bearer, y se acepta en el body como respaldo. */
async function resolveUser(req) {
    const header = req.get("authorization") ?? "";
    const bearer = header.startsWith("Bearer ") ? header.slice(7).trim() : null;
    const token = bearer || text(req.body?.token, 80);
    if (!token) return null;
    return one("SELECT id FROM users WHERE api_token = $1", [token]);
}

/**
 * Resuelve (y crea si hace falta) la cuenta de Roblox dentro del usuario dueno
 * del token. El ON CONFLICT es sobre (user_id, roblox_user_id): la misma cuenta
 * de Roblox reportando con el token de otra persona crea una fila aparte, que es
 * justo lo que evita que se mezclen los contadores entre usuarios.
 */
async function upsertAccount(userId, roblox) {
    const robloxId = clampInt(roblox?.id, 1, Number.MAX_SAFE_INTEGER, 0);
    if (!robloxId) return null;

    const username = text(roblox?.name, 64) ?? `user_${robloxId}`;
    const display = text(roblox?.display, 64);

    const account = await one(
        `INSERT INTO accounts (user_id, roblox_user_id, username, display_name)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id, roblox_user_id) DO UPDATE
             SET username     = EXCLUDED.username,
                 display_name = COALESCE(EXCLUDED.display_name, accounts.display_name),
                 last_seen    = now()
         RETURNING *`,
        [userId, robloxId, username, display]
    );

    // La miniatura se resuelve en segundo plano: si Roblox tarda o falla, el
    // beat ya contesto y la tarjeta se queda con la foto anterior.
    if (!avatarIsFresh(account.avatar_url, account.avatar_at)) {
        fetchAvatar(robloxId)
            .then((url) => {
                if (!url) return;
                return query(
                    "UPDATE accounts SET avatar_url = $1, avatar_at = now() WHERE id = $2",
                    [url, account.id]
                );
            })
            .catch(() => {});
    }

    return account;
}

async function pendingCommands(accountId) {
    const { rows } = await query(
        `UPDATE commands
            SET delivered_at = now()
          WHERE id IN (
              SELECT id FROM commands
               WHERE account_id = $1 AND delivered_at IS NULL
               ORDER BY created_at
               LIMIT 20
          )
      RETURNING id, kind, value`,
        [accountId]
    );
    return rows.map((r) => ({ id: r.id, kind: r.kind, value: r.value }));
}

// ── hello: arranque del script ────────────────────────────────────────────────
botRouter.post("/hello", async (req, res) => {
    const user = await resolveUser(req);
    if (!user) return res.status(401).json({ error: "token_invalido" });

    const account = await upsertAccount(user.id, req.body?.roblox);
    if (!account) return res.status(400).json({ error: "roblox_id_faltante" });

    const clientId = text(req.body?.client, 64);
    if (!clientId) return res.status(400).json({ error: "client_faltante" });

    // Una corrida anterior de la misma cuenta que quedo abierta ya no reporta:
    // cerrarla evita dos sesiones "vivas" y un contador de online inflado.
    await query(
        `UPDATE sessions SET ended_at = now()
          WHERE account_id = $1 AND client_id <> $2 AND ended_at IS NULL`,
        [account.id, clientId]
    );

    const session = await one(
        `INSERT INTO sessions (account_id, client_id, job_id, place_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (account_id, client_id) DO UPDATE
             SET last_beat_at = now(),
                 ended_at     = NULL,
                 job_id       = EXCLUDED.job_id,
                 place_id     = EXCLUDED.place_id
         RETURNING id`,
        [
            account.id,
            clientId,
            text(req.body?.jobId, 64),
            clampInt(req.body?.placeId, 0, Number.MAX_SAFE_INTEGER, 0) || null,
        ]
    );

    res.json({
        ok: true,
        accountId: account.id,
        sessionId: session.id,
        beatMs: beatInterval(),
        commands: await pendingCommands(account.id),
    });
});

// ── beat: heartbeat periodico ─────────────────────────────────────────────────
botRouter.post("/beat", async (req, res) => {
    const user = await resolveUser(req);
    if (!user) return res.status(401).json({ error: "token_invalido" });

    const account = await upsertAccount(user.id, req.body?.roblox);
    if (!account) return res.status(400).json({ error: "roblox_id_faltante" });

    const clientId = text(req.body?.client, 64);
    if (!clientId) return res.status(400).json({ error: "client_faltante" });

    const session = await one(
        `INSERT INTO sessions (account_id, client_id)
         VALUES ($1, $2)
         ON CONFLICT (account_id, client_id) DO UPDATE SET last_beat_at = now()
         RETURNING id, last_honey`,
        [account.id, clientId]
    );

    const honey = clampInt(req.body?.honey, 0, 10_000_000, 0);
    const jobId = text(req.body?.jobId, 64);

    // El contador del script es acumulado y arranca en 0 en cada corrida, asi
    // que lo que se guarda es el delta contra el ultimo beat de ESTA sesion. Si
    // el numero baja (el usuario recargo el script sin cambiar de client id),
    // se toma el valor entero como delta nuevo en vez de restar y quedar en
    // negativo.
    const dHoney = honey >= session.last_honey ? honey - session.last_honey : honey;

    // Los hops se derivan del cambio de server, no del script: el teleport corta
    // la ejecucion antes de que un contador en Lua alcance a reportarse. El
    // primer jobId que vemos de una cuenta no cuenta como salto.
    const dHops = jobId && account.last_job_id && jobId !== account.last_job_id ? 1 : 0;

    const statusKind = STATUS_KINDS.has(req.body?.statusKind) ? req.body.statusKind : "idle";

    await query(
        `UPDATE sessions
            SET last_beat_at   = now(),
                ended_at       = NULL,
                last_honey     = $2,
                last_hops      = last_hops + $3,
                status         = COALESCE($4, status),
                status_kind    = $5,
                method         = COALESCE($6, method),
                speed          = COALESCE($7, speed),
                auto_hop       = $8,
                smart_tp       = $9,
                enabled        = $10,
                job_id         = COALESCE($11, job_id),
                place_id       = COALESCE($12, place_id),
                server_players = COALESCE($13, server_players),
                last_jar_at    = CASE WHEN $14 > 0 THEN now() ELSE last_jar_at END
          WHERE id = $1`,
        [
            session.id,
            honey,
            dHops,
            text(req.body?.status, 80),
            statusKind,
            text(req.body?.method, 16),
            clampInt(req.body?.speed, 0, 5000, 0) || null,
            Boolean(req.body?.autoHop),
            Boolean(req.body?.smartTP),
            Boolean(req.body?.enabled),
            jobId,
            clampInt(req.body?.placeId, 0, Number.MAX_SAFE_INTEGER, 0) || null,
            clampInt(req.body?.players, 0, 200, 0) || null,
            dHoney,
        ]
    );

    if (dHoney > 0 || dHops > 0) {
        const bucket = new Date(Math.floor(Date.now() / BUCKET_MS) * BUCKET_MS);
        await query(
            `INSERT INTO samples (account_id, bucket, honey, hops)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (account_id, bucket) DO UPDATE
                 SET honey = samples.honey + EXCLUDED.honey,
                     hops  = samples.hops  + EXCLUDED.hops`,
            [account.id, bucket, dHoney, dHops]
        );
    }

    await query(
        `UPDATE accounts
            SET total_honey  = total_honey + $2,
                total_hops   = total_hops  + $3,
                last_job_id  = COALESCE($4, last_job_id),
                last_seen    = now()
          WHERE id = $1`,
        [account.id, dHoney, dHops, jobId]
    );

    // Los ids que el bot devuelve son comandos que ya aplico.
    const acked = Array.isArray(req.body?.ack)
        ? req.body.ack.map((id) => clampInt(id, 1, 2 ** 31 - 1, 0)).filter(Boolean).slice(0, 20)
        : [];
    if (acked.length) {
        await query(
            `UPDATE commands SET acked_at = now()
              WHERE account_id = $1 AND id = ANY($2::int[]) AND acked_at IS NULL`,
            [account.id, acked]
        );
    }

    res.json({
        ok: true,
        beatMs: beatInterval(),
        commands: await pendingCommands(account.id),
    });
});

// ── bye: cierre limpio (el script se apago a proposito) ──────────────────────
botRouter.post("/bye", async (req, res) => {
    const user = await resolveUser(req);
    if (!user) return res.status(401).json({ error: "token_invalido" });

    const clientId = text(req.body?.client, 64);
    if (!clientId) return res.status(400).json({ error: "client_faltante" });

    await query(
        `UPDATE sessions s
            SET ended_at = now()
           FROM accounts a
          WHERE s.account_id = a.id
            AND a.user_id = $1
            AND s.client_id = $2
            AND s.ended_at IS NULL`,
        [user.id, clientId]
    );
    res.json({ ok: true });
});
