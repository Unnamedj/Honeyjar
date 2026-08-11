import { Router } from "express";
import { one, query } from "../db.js";
import { adminUserId, requireAdmin, requireUser } from "../lib/auth.js";

export const adminRouter = Router();
adminRouter.use(requireUser, requireAdmin);

// Mismo margen que el dashboard: tres beats perdidos antes de darla por caida.
const ONLINE_WINDOW = "45 seconds";

// ── /api/admin/overview: quien hay, que tiene corriendo y quien pasa ─────────
adminRouter.get("/overview", async (req, res) => {
    // Una fila por usuario con sus cuentas resumidas. El LATERAL de adentro
    // agarra la sesion mas reciente de cada cuenta (la misma idea que el
    // overview del dashboard) para saber si esa cuenta esta viva y si el
    // collector esta prendido, no solo si el script existe.
    const { rows } = await query(
        `SELECT u.id,
                u.username,
                u.created_at,
                u.approved,
                COALESCE(st.accounts, 0)::int  AS accounts,
                COALESCE(st.online,   0)::int  AS online,
                COALESCE(st.running,  0)::int  AS running,
                COALESCE(st.honey,    0)::bigint AS honey,
                COALESCE(st.hops,     0)::bigint AS hops,
                st.last_seen
           FROM users u
           LEFT JOIN LATERAL (
                SELECT count(*)                                            AS accounts,
                       count(*) FILTER (WHERE live.online)                 AS online,
                       count(*) FILTER (WHERE live.online AND live.enabled) AS running,
                       sum(a.total_honey)                                  AS honey,
                       sum(a.total_hops)                                   AS hops,
                       max(a.last_seen)                                    AS last_seen
                  FROM accounts a
                  LEFT JOIN LATERAL (
                       SELECT (s.last_beat_at > now() - INTERVAL '${ONLINE_WINDOW}') AS online,
                              s.enabled
                         FROM sessions s
                        WHERE s.account_id = a.id
                        ORDER BY s.last_beat_at DESC
                        LIMIT 1
                  ) live ON true
                 WHERE a.user_id = u.id
           ) st ON true
          ORDER BY u.id`
    );

    const adminId = await adminUserId();
    const users = rows.map((r) => ({
        id: r.id,
        username: r.username,
        // El admin se muestra siempre como habilitado: su fila puede decir
        // cualquier cosa, el resto del server lo trata como aprobado igual.
        approved: r.approved || r.id === adminId,
        admin: r.id === adminId,
        accounts: r.accounts,
        online: r.online,
        running: r.running,
        honey: Number(r.honey),
        hops: Number(r.hops),
        createdAt: new Date(r.created_at).getTime(),
        lastSeen: r.last_seen ? new Date(r.last_seen).getTime() : null,
    }));

    res.json({
        ok: true,
        now: Date.now(),
        totals: {
            users: users.length,
            approved: users.filter((u) => u.approved).length,
            pending: users.filter((u) => !u.approved).length,
            accounts: users.reduce((n, u) => n + u.accounts, 0),
            online: users.reduce((n, u) => n + u.online, 0),
            running: users.reduce((n, u) => n + u.running, 0),
            honey: users.reduce((n, u) => n + u.honey, 0),
        },
        users,
    });
});

// ── /api/admin/users/:id/access: dar o sacar el acceso al loader ─────────────
adminRouter.post("/users/:id/access", async (req, res) => {
    const id = Math.floor(Number(req.params.id));
    if (!Number.isFinite(id)) return res.status(400).json({ error: "id_invalido" });

    if (typeof req.body?.approved !== "boolean") {
        return res.status(400).json({ error: "approved_faltante" });
    }

    // El admin no se puede bloquear a si mismo: seria dejar el panel sin nadie
    // que pueda volver a abrir la puerta.
    if (id === req.user.id) return res.status(400).json({ error: "admin_no_se_bloquea" });

    const user = await one(
        "UPDATE users SET approved = $2 WHERE id = $1 RETURNING id, username, approved",
        [id, req.body.approved]
    );
    if (!user) return res.status(404).json({ error: "usuario_no_encontrado" });

    // Sacar el acceso no espera al proximo login: el token deja de servir en el
    // beat siguiente porque /api/bot/* mira approved en cada request.
    res.json({ ok: true, user: { id: user.id, username: user.username, approved: user.approved } });
});
