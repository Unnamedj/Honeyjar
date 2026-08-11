-- ============================================================
-- HONEY HUB — esquema
-- ------------------------------------------------------------
-- La regla que ordena todo el archivo: NADA cruza el borde de user_id.
-- Cada cuenta de Roblox cuelga de un usuario del hub, y cada consulta del
-- dashboard filtra por el usuario logueado. Dos personas pueden tener la misma
-- cuenta de Roblox reportando y no se pisan: la clave unica es (user_id,
-- roblox_user_id), no roblox_user_id solo.
-- ============================================================

-- El PRIMER usuario (el id mas chico) es el admin: ve a todos los demas y es
-- quien habilita el acceso. No hay flag para eso a proposito -- un flag se
-- puede apagar sin querer y dejar el panel sin nadie que pueda encenderlo.
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    username      TEXT        NOT NULL,
    username_ci   TEXT        NOT NULL UNIQUE,   -- username en minusculas, para el login case-insensitive
    password_hash TEXT        NOT NULL,
    api_token     TEXT        NOT NULL UNIQUE,   -- lo que se pega en el script de cada cuenta
    -- Sin esto el usuario entra al panel pero no ve el loader ni su token, y
    -- /api/bot/* le rechaza los beats. Arranca apagado: registrarse no alcanza,
    -- lo tiene que habilitar el admin. El admin siempre cuenta como aprobado.
    approved      BOOLEAN     NOT NULL DEFAULT false,
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
    -- El honey que muestra el juego. NO se acumula sumando lo que reporta el
    -- bot: el bot lee el contador de la GUI, que YA es el total de la cuenta.
    -- Se pisa con la ultima lectura, asi correr el script de nuevo (o hopear,
    -- que reinicia el script) no vuelve a sumar un total que ya estaba contado.
    total_honey     BIGINT      NOT NULL DEFAULT 0,
    -- Ultima lectura de ese contador. Es el ancla para sacar cuanto se gano
    -- entre dos beats (lo que alimenta samples). Vive en la cuenta y no en la
    -- sesion a proposito: la sesion muere en cada teleport, la cuenta no.
    -- NULL = todavia no se leyo nada, asi que el primer beat solo ancla y no
    -- cuenta ganancia (si no, la primera lectura entraria entera al grafico).
    honey_anchor    BIGINT,
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
    -- Cuanto SUMO la cuenta desde que arranco esta corrida (no la lectura cruda
    -- del contador del juego: eso es un total historico y no dice nada de la
    -- sesion). Se acumula con la ganancia de cada beat, igual que last_hops.
    last_honey     INTEGER     NOT NULL DEFAULT 0,
    last_hops      INTEGER     NOT NULL DEFAULT 0,
    status         TEXT        NOT NULL DEFAULT 'Idle',
    status_kind    TEXT        NOT NULL DEFAULT 'idle',   -- idle | collecting | waiting | hopping | stopped
    method         TEXT,
    speed          INTEGER,
    auto_hop       BOOLEAN     NOT NULL DEFAULT false,
    smart_tp       BOOLEAN     NOT NULL DEFAULT false,
    enabled        BOOLEAN     NOT NULL DEFAULT false,
    -- Estado del evento Bee visto por ESA cuenta, y si el bot esta configurado
    -- para esperarlo. Van juntos a proposito: una cuenta quieta con
    -- event_active=false y wait_event=true no esta rota, esta esperando.
    event_active   BOOLEAN     NOT NULL DEFAULT false,
    wait_event     BOOLEAN     NOT NULL DEFAULT false,
    anti_afk       BOOLEAN     NOT NULL DEFAULT false,
    -- Orden de recoleccion: true = barrido planeado de una (un solo trazo),
    -- false = la jarra mas cercana recalculada en cada paso.
    sweep_route    BOOLEAN     NOT NULL DEFAULT true,
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

-- Ancla del contador de honey. En las bases que ya existian queda en NULL: el
-- primer beat de cada cuenta la llena y de paso pisa el total_honey inflado que
-- dejo el modelo viejo (sumaba el total del juego entero en cada corrida).
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS honey_anchor BIGINT;

-- Aprobacion. El DEFAULT true del ADD COLUMN es a proposito y corre UNA sola
-- vez (despues el IF NOT EXISTS lo saltea): a los que ya estaban usando el
-- panel no se les corta el acceso de golpe por un deploy. El SET DEFAULT de
-- abajo deja el default real en false para los que se registren de ahora en
-- mas, que es el punto de todo esto.
ALTER TABLE users ADD COLUMN IF NOT EXISTS approved BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE users ALTER COLUMN approved SET DEFAULT false;

-- Tracker del evento. En las sesiones que ya existian arrancan en false y el
-- primer beat del script las pone al dia.
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS event_active BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS wait_event   BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS anti_afk     BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS sweep_route  BOOLEAN NOT NULL DEFAULT true;
