-- ============================================================
-- HONEY HUB — esquema
-- ------------------------------------------------------------
-- La regla que ordena todo el archivo: NADA cruza el borde de user_id.
-- Cada cuenta de Roblox cuelga de un usuario del hub, y cada consulta del
-- dashboard filtra por el usuario logueado. Dos personas pueden tener la misma
-- cuenta de Roblox reportando y no se pisan: la clave unica es (user_id,
-- roblox_user_id), no roblox_user_id solo.
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    username      TEXT        NOT NULL,
    username_ci   TEXT        NOT NULL UNIQUE,   -- username en minusculas, para el login case-insensitive
    password_hash TEXT        NOT NULL,
    api_token     TEXT        NOT NULL UNIQUE,   -- lo que se pega en el script de cada cuenta
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Una fila por cuenta de Roblox. Los totales viven aca (no se recalculan desde
-- samples) porque el dashboard los lee en cada poll y sumar la serie entera
-- cada 4 segundos no escala.
CREATE TABLE IF NOT EXISTS accounts (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    roblox_user_id  BIGINT      NOT NULL,
    username        TEXT        NOT NULL,
    display_name    TEXT,
    avatar_url      TEXT,
    avatar_at       TIMESTAMPTZ,                 -- cuando se resolvio la miniatura (se refresca cada 6h)
    total_honey     BIGINT      NOT NULL DEFAULT 0,
    total_hops      BIGINT      NOT NULL DEFAULT 0,
    -- Ultimo server visto. Los hops se derivan de aca: si el jobId del beat es
    -- distinto al guardado, la cuenta cambio de server. Contarlo en Lua no
    -- sirve — el teleport mata el script antes de que llegue a reportarlo.
    last_job_id     TEXT,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, roblox_user_id)
);

CREATE INDEX IF NOT EXISTS accounts_user_idx ON accounts (user_id);

-- Una sesion = una corrida del script en una cuenta. Guarda el estado vivo que
-- el bot reporta en cada beat, asi el dashboard lee una sola fila por cuenta en
-- vez de reconstruir el estado desde la serie temporal.
CREATE TABLE IF NOT EXISTS sessions (
    id             SERIAL PRIMARY KEY,
    account_id     INTEGER     NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    client_id      TEXT        NOT NULL,         -- uuid que genera el bot al arrancar
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_beat_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Ultimo acumulado que reporto el bot en ESTA sesion. Es el ancla para
    -- calcular deltas: el contador del script arranca en 0 en cada restart, asi
    -- que sin esto un restart se leeria como "perdio 300 jars".
    last_honey     INTEGER     NOT NULL DEFAULT 0,
    last_hops      INTEGER     NOT NULL DEFAULT 0,
    status         TEXT        NOT NULL DEFAULT 'Idle',
    status_kind    TEXT        NOT NULL DEFAULT 'idle',   -- idle | collecting | waiting | hopping | stopped
    method         TEXT,
    speed          INTEGER,
    auto_hop       BOOLEAN     NOT NULL DEFAULT false,
    smart_tp       BOOLEAN     NOT NULL DEFAULT false,
    enabled        BOOLEAN     NOT NULL DEFAULT false,
    job_id         TEXT,
    place_id       BIGINT,
    server_players INTEGER,
    last_jar_at    TIMESTAMPTZ,
    ended_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sessions_account_idx  ON sessions (account_id, last_beat_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_client_idx ON sessions (account_id, client_id);

-- Serie temporal en cubetas de 5 minutos. Guarda el DELTA de la cubeta, no el
-- acumulado: asi el grafico de ritmo es una suma directa y un restart del
-- script no genera un escalon falso.
CREATE TABLE IF NOT EXISTS samples (
    account_id INTEGER     NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    bucket     TIMESTAMPTZ NOT NULL,
    honey      INTEGER     NOT NULL DEFAULT 0,
    hops       INTEGER     NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, bucket)
);

CREATE INDEX IF NOT EXISTS samples_bucket_idx ON samples (bucket DESC);

-- Cola de comandos del dashboard hacia el bot. El bot los levanta en su
-- siguiente beat; delivered_at marca que los recibio (la UI muestra "pendiente"
-- hasta entonces) y acked_at que los aplico.
CREATE TABLE IF NOT EXISTS commands (
    id           SERIAL PRIMARY KEY,
    account_id   INTEGER     NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind         TEXT        NOT NULL,
    value        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    acked_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS commands_pending_idx
    ON commands (account_id, created_at)
    WHERE delivered_at IS NULL;

-- ── Migraciones sobre bases ya creadas ──────────────────────────────────────
-- CREATE TABLE IF NOT EXISTS no toca una tabla que ya existe, asi que las
-- columnas agregadas despues del primer deploy van aca. Todo idempotente: el
-- archivo entero se corre en cada arranque.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS last_job_id TEXT;
