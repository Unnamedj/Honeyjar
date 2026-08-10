import { Router } from "express";
import { one, query } from "../db.js";
import { requireUser } from "../lib/auth.js";

export const dashRouter = Router();
dashRouter.use(requireUser);

// Una cuenta cuenta como online si mando beat hace poco. El margen es generoso
// (3 beats) para que un hiccup de red no la apague y vuelva a prender en la UI.
const ONLINE_WINDOW = "45 seconds";

const RANGES = {
    "6h":  { span: "6 hours",  bucket: "15 minutes" },
    "24h": { span: "24 hours", bucket: "1 hour" },
    "7d":  { span: "7 days",   bucket: "6 hours" },
};

const COMMANDS = {
    enabled: (v) => (v === "on" || v === "off" ? v : null),
    autohop: (v) => (v === "on" || v === "off" ? v : null),
    smart:   (v) => (v === "on" || v === "off" ? v : null),
    method:  (v) => (v === "Grapple" || v === "Carpet" ? v : null),
    speed:   (v) => {
        const n = Math.floor(Number(v));
        return Number.isFinite(n) && n >= 50 && n <= 1000 ? String(n) : null;
    },
    hop:     () => "",
};

function tzOffsetMinutes(req) {
    const n = Math.floor(Number(req.query?.tz));
    // Los offsets reales van de -12h a +14h; fuera de eso es basura y se ignora.
    return Number.isFinite(n) && n >= -720 && n <= 840 ? n : 0;
}

dashRouter.get("/overview", async (req, res) => {
    const userId = req.user.id;
    const range = RANGES[req.query?.range] ? req.query.range : "24h";
    const { span, bucket } = RANGES[range];
    const tz = tzOffsetMinutes(req);

    const [accounts, series, perAccount, spark, days, best] = await Promise.all([
        // Una fila por cuenta con su sesion viva (la del beat mas reciente).
        query(
            `SELECT a.id,
                    a.roblox_user_id,
                    a.username,
                    a.display_name,
                    a.avatar_url,
                    a.total_honey,
                    a.total_hops,
                    a.first_seen,
                    a.last_seen,
                    s.status,
                    s.status_kind,
                    s.method,
                    s.speed,
                    s.auto_hop,
                    s.smart_tp,
                    s.enabled,
                    s.job_id,
                    s.server_players,
                    s.started_at,
                    s.last_beat_at,
                    s.last_jar_at,
                    s.last_honey  AS session_honey,
                    s.last_hops   AS session_hops,
                    (s.last_beat_at > now() - INTERVAL '${ONLINE_WINDOW}') AS online,
                    (SELECT count(*)::int FROM commands c
                      WHERE c.account_id = a.id AND c.acked_at IS NULL) AS pending_commands
               FROM accounts a
               LEFT JOIN LATERAL (
                    SELECT * FROM sessions
                     WHERE account_id = a.id
                     ORDER BY last_beat_at DESC
                     LIMIT 1
               ) s ON true
              WHERE a.user_id = $1
              ORDER BY a.total_honey DESC, a.username ASC`,
            [userId]
        ),

        // Serie del equipo. generate_series primero para que las cubetas sin
        // datos salgan en 0 y el grafico no invente una linea recta entre dos
        // momentos separados por horas de inactividad.
        query(
            `WITH grid AS (
                 SELECT generate_series(
                     date_bin($2::interval, now() - $3::interval, TIMESTAMPTZ 'epoch'),
                     date_bin($2::interval, now(), TIMESTAMPTZ 'epoch'),
                     $2::interval
                 ) AS t
             )
             SELECT g.t,
                    COALESCE(sum(s.honey), 0)::int AS honey,
                    COALESCE(sum(s.hops), 0)::int  AS hops
               FROM grid g
               LEFT JOIN samples s
                 ON date_bin($2::interval, s.bucket, TIMESTAMPTZ 'epoch') = g.t
                AND s.account_id IN (SELECT id FROM accounts WHERE user_id = $1)
              GROUP BY g.t
              ORDER BY g.t`,
            [userId, bucket, span]
        ),

        // La misma grilla por cuenta, para el modo enfasis del grafico.
        query(
            `SELECT s.account_id,
                    date_bin($2::interval, s.bucket, TIMESTAMPTZ 'epoch') AS t,
                    sum(s.honey)::int AS honey
               FROM samples s
               JOIN accounts a ON a.id = s.account_id
              WHERE a.user_id = $1
                AND s.bucket > now() - $3::interval
              GROUP BY s.account_id, t
              ORDER BY t`,
            [userId, bucket, span]
        ),

        // Sparkline de cada tarjeta: 12 cubetas de 15 min (las ultimas 3 horas).
        query(
            `WITH grid AS (
                 SELECT generate_series(
                     date_bin('15 minutes', now() - INTERVAL '3 hours', TIMESTAMPTZ 'epoch'),
                     date_bin('15 minutes', now(), TIMESTAMPTZ 'epoch'),
                     INTERVAL '15 minutes'
                 ) AS t
             )
             SELECT a.id AS account_id, g.t, COALESCE(sum(s.honey), 0)::int AS honey
               FROM accounts a
               CROSS JOIN grid g
               LEFT JOIN samples s
                 ON s.account_id = a.id
                AND date_bin('15 minutes', s.bucket, TIMESTAMPTZ 'epoch') = g.t
              WHERE a.user_id = $1
              GROUP BY a.id, g.t
              ORDER BY a.id, g.t`,
            [userId]
        ),

        // Dias con actividad, en la zona horaria del navegador — para la racha.
        query(
            // to_char y no ::date: el driver devuelve DATE como objeto Date de
            // JS y compararlo con la clave ISO de abajo requiere formatearlo
            // igual de los dos lados. Que Postgres lo mande ya como texto
            // YYYY-MM-DD saca el problema de raiz.
            `SELECT to_char(date_trunc('day', s.bucket + make_interval(mins => $2::int)), 'YYYY-MM-DD') AS day,
                    sum(s.honey)::int AS honey
               FROM samples s
               JOIN accounts a ON a.id = s.account_id
              WHERE a.user_id = $1
              GROUP BY day
             HAVING sum(s.honey) > 0
              ORDER BY day DESC
              LIMIT 400`,
            [userId, tz]
        ),

        // Mejor hora del dia y sesion mas larga.
        Promise.all([
            one(
                `SELECT EXTRACT(hour FROM s.bucket + make_interval(mins => $2::int))::int AS hour,
                        sum(s.honey)::int AS honey
                   FROM samples s
                   JOIN accounts a ON a.id = s.account_id
                  WHERE a.user_id = $1
                  GROUP BY hour
                  ORDER BY honey DESC
                  LIMIT 1`,
                [userId, tz]
            ),
            one(
                `SELECT EXTRACT(epoch FROM (COALESCE(s.ended_at, s.last_beat_at) - s.started_at))::int AS secs,
                        a.username
                   FROM sessions s
                   JOIN accounts a ON a.id = s.account_id
                  WHERE a.user_id = $1
                  ORDER BY secs DESC
                  LIMIT 1`,
                [userId]
            ),
        ]),
    ]);

    // Racha: dias consecutivos con al menos un jar, contando hacia atras desde
    // hoy. Si hoy todavia no hubo nada pero ayer si, la racha sigue viva — se
    // corta recien cuando pasa un dia entero en cero.
    const dayKeys = days.rows.map((r) => String(r.day).slice(0, 10));
    const daySet = new Set(dayKeys);
    const today = new Date(Date.now() + tz * 60_000);
    let streak = 0;
    for (let i = 0; i < 400; i++) {
        const d = new Date(today);
        d.setUTCDate(d.getUTCDate() - i);
        const key = d.toISOString().slice(0, 10);
        if (daySet.has(key)) streak++;
        else if (i > 0) break;
    }

    const sparkByAccount = new Map();
    for (const row of spark.rows) {
        if (!sparkByAccount.has(row.account_id)) sparkByAccount.set(row.account_id, []);
        sparkByAccount.get(row.account_id).push(row.honey);
    }

    const seriesByAccount = new Map();
    for (const row of perAccount.rows) {
        if (!seriesByAccount.has(row.account_id)) seriesByAccount.set(row.account_id, new Map());
        seriesByAccount.get(row.account_id).set(new Date(row.t).getTime(), row.honey);
    }

    const stamps = series.rows.map((r) => new Date(r.t).getTime());
    const [bestHour, longestSession] = best;

    const online = accounts.rows.filter((a) => a.online).length;
    const totalHoney = accounts.rows.reduce((n, a) => n + Number(a.total_honey), 0);
    const totalHops = accounts.rows.reduce((n, a) => n + Number(a.total_hops), 0);

    // Ritmo actual: lo recolectado en la ultima hora. Es el numero que dice si
    // la operacion esta rindiendo AHORA, no el promedio historico.
    const lastHour = await one(
        `SELECT COALESCE(sum(s.honey), 0)::int AS honey
           FROM samples s
           JOIN accounts a ON a.id = s.account_id
          WHERE a.user_id = $1 AND s.bucket > now() - INTERVAL '1 hour'`,
        [userId]
    );

    res.json({
        ok: true,
        now: Date.now(),
        range,
        totals: {
            honey: totalHoney,
            hops: totalHops,
            accounts: accounts.rows.length,
            online,
            perHour: lastHour?.honey ?? 0,
            streak,
            bestHour: bestHour ? { hour: bestHour.hour, honey: bestHour.honey } : null,
            longestSession: longestSession
                ? { secs: longestSession.secs, username: longestSession.username }
                : null,
        },
        series: {
            t: stamps,
            honey: series.rows.map((r) => r.honey),
            hops: series.rows.map((r) => r.hops),
        },
        accounts: accounts.rows.map((a) => ({
            id: a.id,
            robloxId: String(a.roblox_user_id),
            username: a.username,
            displayName: a.display_name,
            avatarUrl: a.avatar_url,
            honey: Number(a.total_honey),
            hops: Number(a.total_hops),
            sessionHoney: a.session_honey ?? 0,
            sessionHops: a.session_hops ?? 0,
            online: Boolean(a.online),
            status: a.status ?? "Sin datos",
            statusKind: a.status_kind ?? "idle",
            method: a.method,
            speed: a.speed,
            autoHop: Boolean(a.auto_hop),
            smartTp: Boolean(a.smart_tp),
            enabled: Boolean(a.enabled),
            jobId: a.job_id,
            players: a.server_players,
            startedAt: a.started_at ? new Date(a.started_at).getTime() : null,
            lastBeatAt: a.last_beat_at ? new Date(a.last_beat_at).getTime() : null,
            lastJarAt: a.last_jar_at ? new Date(a.last_jar_at).getTime() : null,
            firstSeen: new Date(a.first_seen).getTime(),
            pendingCommands: a.pending_commands,
            spark: sparkByAccount.get(a.id) ?? [],
            series: stamps.map((t) => seriesByAccount.get(a.id)?.get(t) ?? 0),
        })),
    });
});

dashRouter.post("/accounts/:id/command", async (req, res) => {
    const accountId = Math.floor(Number(req.params.id));
    if (!Number.isFinite(accountId)) return res.status(400).json({ error: "id_invalido" });

    const kind = String(req.body?.kind ?? "");
    const validator = COMMANDS[kind];
    if (!validator) return res.status(400).json({ error: "comando_desconocido" });

    const value = validator(req.body?.value === undefined ? "" : String(req.body.value));
    if (value === null) return res.status(400).json({ error: "valor_invalido" });

    // La pertenencia se chequea en el WHERE, no antes: asi no hay ventana entre
    // "verifico que es tuya" y "escribo el comando".
    const owned = await one(
        "SELECT id FROM accounts WHERE id = $1 AND user_id = $2",
        [accountId, req.user.id]
    );
    if (!owned) return res.status(404).json({ error: "cuenta_no_encontrada" });

    // Un comando del mismo tipo sin entregar queda obsoleto apenas llega otro:
    // si tocaste velocidad tres veces, al bot le llega la ultima.
    await query(
        `UPDATE commands SET delivered_at = now(), acked_at = now()
          WHERE account_id = $1 AND kind = $2 AND delivered_at IS NULL`,
        [accountId, kind]
    );

    const cmd = await one(
        `INSERT INTO commands (account_id, kind, value) VALUES ($1, $2, $3)
         RETURNING id, kind, value, created_at`,
        [accountId, kind, value]
    );

    res.json({ ok: true, command: cmd });
});

dashRouter.delete("/accounts/:id", async (req, res) => {
    const accountId = Math.floor(Number(req.params.id));
    if (!Number.isFinite(accountId)) return res.status(400).json({ error: "id_invalido" });

    const { rowCount } = await query(
        "DELETE FROM accounts WHERE id = $1 AND user_id = $2",
        [accountId, req.user.id]
    );
    if (!rowCount) return res.status(404).json({ error: "cuenta_no_encontrada" });
    res.json({ ok: true });
});
