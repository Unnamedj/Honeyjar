import { areaChart, rampColor, sparkline } from "/js/charts.js";

const POLL_MS = 2000;

const state = {
    data: null,
    range: "24h",
    sort: "honey",
    selected: null,   // id de cuenta en modo enfasis, o null = equipo
    tableView: false,
    token: null,
    lastOk: 0,
    // Sesion: si es el primer usuario (admin) y si tiene el loader habilitado.
    admin: false,
    approved: false,
    view: "dash",     // dash | admin
    adminData: null,
};

// ── utilidades ────────────────────────────────────────────────

const $ = (id) => document.getElementById(id);

const nf = new Intl.NumberFormat("en");
const fmt = (n) => nf.format(Math.round(n || 0));

function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => (
        { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
}

function ago(stamp) {
    if (!stamp) return "never";
    const secs = Math.max(0, Math.round((Date.now() - stamp) / 1000));
    if (secs < 10) return "just now";
    if (secs < 60) return `${secs}s ago`;
    if (secs < 3600) return `${Math.floor(secs / 60)}min ago`;
    if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
    return `${Math.floor(secs / 86400)}d ago`;
}

function duration(secs) {
    if (!secs || secs < 0) return "—";
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    if (h) return `${h} h ${m} m`;
    if (m) return `${m} m`;
    return `${Math.floor(secs)} s`;
}

// El estado del bot se muestra SIEMPRE con punto + texto: el color repite lo
// que dice la etiqueta, nunca lo reemplaza.
const STATUS = {
    collecting: { tone: "good",     label: "Collecting" },
    waiting:    { tone: "warning",  label: "Waiting for jars" },
    hopping:    { tone: "serious",  label: "Hopping server" },
    stopped:    { tone: "muted",    label: "Stopped" },
    idle:       { tone: "muted",    label: "Idle" },
    // Quieto a proposito: no hay evento Bee y el bot tiene puesto esperarlo.
    // Va en warning y no en critical porque no es una falla.
    waiting_event: { tone: "warning", label: "Waiting for event" },
};

const RING = {
    good: "#0ca30c", warning: "#fab219", serious: "#ec835a",
    critical: "#d03b3b", muted: "#3a3340",
};

function statusOf(account) {
    if (!account.online) return { tone: "critical", label: "Offline" };
    return STATUS[account.statusKind] ?? STATUS.idle;
}

function avatarHtml(account, size = "md") {
    const tone = statusOf(account).tone;
    const initial = escapeHtml((account.username || "?").slice(0, 1).toUpperCase());
    // Sin onerror inline: la CSP no permite handlers en el HTML. El que se
    // rompe se saca en wireAvatarFallback, despues de pintar.
    const photo = account.avatarUrl
        ? `<img src="${escapeHtml(account.avatarUrl)}" alt="" loading="lazy" data-avatar>`
        : "";
    return `<div class="avatar avatar--${size} avatar--ring" style="--ring:${RING[tone]}">${initial}${photo}</div>`;
}

// ── carga ─────────────────────────────────────────────────────

async function load() {
    const tz = -new Date().getTimezoneOffset();
    try {
        const res = await fetch(`/api/overview?range=${state.range}&tz=${tz}`);
        if (res.status === 401) {
            location.replace("/");
            return;
        }
        if (!res.ok) throw new Error("overview");
        state.data = await res.json();
        state.lastOk = Date.now();
        render();
    } catch {
        markStale();
    }
}

function markStale() {
    const stale = Date.now() - state.lastOk > POLL_MS * 3;
    $("pulse").classList.toggle("pulse--stale", stale);
    if (stale) $("pulse-text").textContent = "Offline";
}

// ── render ────────────────────────────────────────────────────

function render() {
    const { totals, accounts } = state.data;

    $("pulse").classList.remove("pulse--stale");
    $("pulse-text").textContent = `${totals.online} live`;

    $("hero-honey").textContent = fmt(totals.honey);
    $("hero-sub").textContent = accounts.length
        ? `Across ${accounts.length} ${accounts.length === 1 ? "account" : "accounts"}`
        : "No accounts connected yet";

    $("kpi-accounts").textContent = `${totals.online}/${totals.accounts}`;
    $("kpi-accounts-foot").textContent = totals.online
        ? `${totals.online} reporting now`
        : "none reporting";
    $("kpi-rate").textContent = fmt(totals.perHour);

    // Cuantas cuentas vivas estan en un server con el evento corriendo. Si
    // ninguna lo esta, el ritmo en cero no es un problema del bot.
    const inEvent = totals.inEvent ?? 0;
    $("kpi-event").textContent = totals.online ? `${inEvent}/${totals.online}` : "—";
    $("kpi-event-foot").textContent = !totals.online
        ? "no accounts live"
        : inEvent
            ? `${inEvent} collecting the event`
            : "nobody in the event yet";
    $("kpi-hops").textContent = fmt(totals.hops);
    $("kpi-streak").textContent = totals.streak;
    $("kpi-streak-foot").textContent = totals.bestHour
        ? `best hour: ${String(totals.bestHour.hour).padStart(2, "0")}:00`
        : "days in a row";

    $("accounts-count").textContent = accounts.length
        ? `${accounts.length} total · ${totals.online} live`
        : "";

    renderChart();
    renderFetcher();
    renderPodium();
    renderAccounts();
    renderRanking();
    wireAvatarFallback();
}

/**
 * Una miniatura de Roblox que no carga deja el hueco con el icono roto encima
 * de la inicial. Antes esto era un onerror= en el HTML; la CSP no deja handlers
 * inline, asi que el listener se engancha aca despues de pintar.
 */
function wireAvatarFallback() {
    for (const img of document.querySelectorAll("img[data-avatar]")) {
        img.removeAttribute("data-avatar");
        // Si ya fallo antes de llegar hasta aca, el evento no vuelve a salir.
        if (img.complete && img.naturalWidth === 0) img.remove();
        else img.addEventListener("error", () => img.remove(), { once: true });
    }
}

function renderChart() {
    const { series, accounts } = state.data;
    const selected = accounts.find((a) => a.id === state.selected);

    // Al seleccionar una cuenta el grafico pasa a enfasis: ella en ambar, el
    // equipo detras en gris punteado. Dos series -> leyenda obligatoria.
    const spec = selected
        ? {
              t: series.t, values: selected.series, label: selected.username,
              context: series.honey, contextLabel: "Whole team", range: state.range,
          }
        : { t: series.t, values: series.honey, label: "Whole team", range: state.range };

    areaChart($("chart"), spec);

    const spanText = { "6h": "last 6 h", "24h": "last 24 h", "7d": "last 7 days" }[state.range];
    const bucketText = { "6h": "per 15 min", "24h": "per hour", "7d": "per 6 h" }[state.range];
    $("chart-title").textContent = selected
        ? `${selected.username} rate`
        : "Collection rate";
    $("chart-sub").textContent = `Jars ${bucketText} · ${spanText}`;

    const legend = $("chart-legend");
    if (selected) {
        legend.innerHTML =
            `<span class="legend__item"><span class="legend__swatch" style="background:#ffab21"></span>${escapeHtml(selected.username)}</span>` +
            `<span class="legend__item"><span class="legend__swatch" style="background:#6a6270"></span>Whole team</span>` +
            `<button class="btn btn--sm btn--ghost" id="clear-selection">Back to team</button>`;
        $("clear-selection").addEventListener("click", () => {
            state.selected = null;
            render();
        });
    } else {
        legend.innerHTML = accounts.length
            ? `<span class="legend__item muted">Tap an account card to see its own curve.</span>`
            : "";
    }
}

// ── Pool de servers (fetcher) ─────────────────────────────────
//
// De donde salen los servers a los que salta "Hop after collect". Sin el
// fetcher cada cuenta pagina Roblox por su cuenta y se come el rate-limit;
// con el, el panel scrapea una vez y reparte jobIds reservados.

function tile(label, value, foot) {
    return `<div class="tile">
        <span class="tile__label">${escapeHtml(label)}</span>
        <span class="tile__value num">${escapeHtml(value)}</span>
        <span class="tile__foot">${escapeHtml(foot)}</span>
    </div>`;
}

// El estado va SIEMPRE como punto + texto, igual que el de las cuentas: el
// color repite lo que dice la etiqueta, no la reemplaza.
function fetcherHealth(f) {
    if (!f.running) return { tone: "muted", label: "Off" };
    if (!f.total) return { tone: "warning", label: "Gathering servers" };
    if (!f.disponibles) return { tone: "serious", label: "Pool drained" };
    return { tone: "good", label: "Active" };
}

// Un aviso a la vez, el mas accionable primero: no sirve enterarse de que hay
// rate-limits si en realidad el fetcher esta apagado.
function fetcherNote(f) {
    if (!f.running) {
        return "The fetcher is off, so every account looks for servers on its own against " +
            "Roblox. To turn it on, put your proxies in the PROXIES variable of the deploy.";
    }
    if (!f.proxies) {
        return "Running with no proxies: every request goes out through the panel IP and Roblox " +
            "will start rate-limiting them. Set PROXIES to spread them out.";
    }
    if (f.rateLimits > 0 && !f.proxiesRotativos) {
        return "None of your proxies rotates the session id, so every request goes out through " +
            "the same IP and that is where the rate limits come from. A proxy with “-session-” in " +
            "the username gives a different IP per request.";
    }
    if (f.proxiesPenalizados >= f.proxies && f.proxies > 0) {
        return "All your proxies are out of rotation after failing (check host, port and " +
            "credentials). The scraper will NOT fall back to direct requests meanwhile — that " +
            "would burn the panel IP — so the pool stops growing until one recovers.";
    }
    if (f.ultimoError) return `Last error: ${f.ultimoError}`;
    return null;
}

function renderFetcher() {
    const f = state.data.fetcher;
    if (!f) return;

    const health = fetcherHealth(f);
    $("fetcher-badge").className = `badge badge--${health.tone}`;
    $("fetcher-badge-text").textContent = health.label;

    const visto = f.ultimoScrapeHaceS === null
        ? "no data yet"
        : `seen ${ago(Date.now() - f.ultimoScrapeHaceS * 1000)}`;
    $("fetcher-sub").textContent = `This is where Hop after collect jumps come from · ${visto}`;

    // Frenado = el backoff subio el delay porque Roblox devolvio 429.
    const frenado = f.delayMs > f.delayBaseMs;

    $("fetcher-tiles").innerHTML = [
        tile("In the pool", fmt(f.total), `${fmt(f.reservados)} handed out now`),
        tile("Available", fmt(f.disponibles), `up to ${f.maxPlayers} players`),
        tile("Untouched", fmt(f.frescos), "nobody has been sent there"),
        tile("Rate limits", fmt(f.rateLimits), f.rateLimits ? "429s from Roblox" : "none"),
        tile("Errors", fmt(f.errores), f.errores ? "failed requests" : "none"),
        // Apagado, el delay configurado no describe nada: no hay requests que
        // espaciar. Mostrarlo como un numero vivo seria inventar actividad.
        f.running
            ? tile("Pace", `${fmt(f.delayMs)} ms`, frenado ? "slowed by rate limits" : "between requests")
            : tile("Pace", "—", "the scraper is not running"),
    ].join("");

    const note = fetcherNote(f);
    $("fetcher-note").hidden = !note;
    if (note) $("fetcher-note").textContent = note;
}

function renderPodium() {
    const top = [...state.data.accounts].sort((a, b) => b.honey - a.honey).slice(0, 3);
    const section = $("podium-section");

    if (top.length < 2 || top[0].honey === 0) {
        section.hidden = true;
        return;
    }
    section.hidden = false;

    const medals = ["🥇", "🥈", "🥉"];
    $("podium").innerHTML = top
        .map(
            (a, i) => `
            <div class="podium__slot podium__slot--${i + 1}">
                <span class="podium__rank">${medals[i]}</span>
                ${avatarHtml(a, "lg")}
                <span class="podium__name">${escapeHtml(a.username)}</span>
                <span class="podium__value num">${fmt(a.honey)} 🍯</span>
            </div>`
        )
        .join("");
}

function sortAccounts(accounts) {
    const list = [...accounts];
    if (state.sort === "name") {
        return list.sort((a, b) => a.username.localeCompare(b.username));
    }
    if (state.sort === "live") {
        return list.sort(
            (a, b) => Number(b.online) - Number(a.online) || b.sessionHoney - a.sessionHoney
        );
    }
    return list.sort((a, b) => b.honey - a.honey);
}

function renderAccounts() {
    const host = $("accounts");
    const accounts = state.data.accounts;

    if (!accounts.length) {
        host.innerHTML = `
            <div class="empty" style="grid-column:1/-1">
                <div class="empty__icon">🐝</div>
                <h3>No accounts connected yet</h3>
                <p>Paste your token into the collector on each account and they show up here on
                   their own, with their avatar, their counter and their controls.</p>
                <button class="btn btn--primary" id="empty-connect">See how to connect</button>
            </div>`;
        $("empty-connect").addEventListener("click", openConnectModal);
        return;
    }

    host.innerHTML = sortAccounts(accounts).map(accountCard).join("");

    for (const card of host.querySelectorAll("[data-account]")) {
        const id = Number(card.dataset.account);
        const account = accounts.find((a) => a.id === id);

        sparkline(card.querySelector("[data-spark]"), account.spark);

        card.querySelector("[data-focus]").addEventListener("click", () => {
            state.selected = state.selected === id ? null : id;
            render();
            document.querySelector(".chart-card").scrollIntoView({ behavior: "smooth", block: "center" });
        });

        for (const button of card.querySelectorAll("[data-cmd]")) {
            button.addEventListener("click", () =>
                sendCommand(id, button.dataset.cmd, button.dataset.value ?? "", button)
            );
        }

        card.querySelector("[data-remove]").addEventListener("click", () => removeAccount(account));
    }
}

function accountCard(a) {
    const status = statusOf(a);
    const uptime = a.online && a.startedAt ? duration((Date.now() - a.startedAt) / 1000) : "—";
    const selected = state.selected === a.id;

    return `
    <article class="account ${a.online ? "" : "account--offline"}" data-account="${a.id}">
        <div class="account__top">
            ${avatarHtml(a, "md")}
            <div class="account__id">
                <div class="account__name">${escapeHtml(a.displayName || a.username)}</div>
                <div class="account__handle">@${escapeHtml(a.username)}</div>
            </div>
            <span class="badge badge--${status.tone}">
                <span class="badge__dot"></span>${status.label}
            </span>
        </div>

        <div>
            <div class="account__honey num">
                ${fmt(a.honey)} <small>honey in game</small>
            </div>
            <div class="tile__spark" data-spark></div>
            <div class="muted" style="font-size:11px">
                ${fmt(a.sessionHoney)} this session · ${escapeHtml(a.status)}
            </div>
        </div>

        <div class="meta">
            <div class="meta__row"><span class="meta__key">Hops</span><span class="meta__val num">${fmt(a.hops)}</span></div>
            <div class="meta__row"><span class="meta__key">Uptime</span><span class="meta__val">${uptime}</span></div>
            <div class="meta__row"><span class="meta__key">Last jar</span><span class="meta__val">${ago(a.lastJarAt)}</span></div>
            <div class="meta__row"><span class="meta__key">Bee event</span><span class="meta__val">${eventCell(a)}</span></div>
            <div class="meta__row"><span class="meta__key">Server</span><span class="meta__val">${
                a.jobId ? `${escapeHtml(a.jobId.slice(0, 8))}${a.players ? ` · ${a.players}p` : ""}` : "—"
            }</span></div>
            <div class="meta__row"><span class="meta__key">Method</span><span class="meta__val">${
                escapeHtml(a.method || "—")
            }${a.smartTp ? " (Smart)" : ""}</span></div>
            <div class="meta__row"><span class="meta__key">Speed</span><span class="meta__val num">${
                a.speed ? `${a.speed}` : "—"
            }</span></div>
        </div>

        <div class="controls">
            ${
                a.pendingCommands
                    ? `<span class="controls__pending">${a.pendingCommands} ${
                          a.pendingCommands === 1 ? "pending order" : "pending orders"
                      } — applied on the next beat</span>`
                    : ""
            }
            <button class="btn btn--sm ${a.enabled ? "btn--on" : ""}" data-cmd="enabled"
                    data-value="${a.enabled ? "off" : "on"}">
                ${a.enabled ? "Pause" : "Collect"}
            </button>
            <button class="btn btn--sm ${a.method === "Grapple" ? "btn--on" : ""}"
                    data-cmd="method" data-value="Grapple"
                    title="Method: Grapple" aria-label="Use Grapple method">Grapple</button>
            <button class="btn btn--sm ${a.method === "Carpet" ? "btn--on" : ""}"
                    data-cmd="method" data-value="Carpet"
                    title="Method: Carpet" aria-label="Use Carpet method">Carpet</button>
            <button class="btn btn--sm ${a.smartTp ? "btn--on" : ""}" data-cmd="smart"
                    data-value="${a.smartTp ? "off" : "on"}" title="Smart TP">Smart TP</button>
            <button class="btn btn--sm ${a.autoHop ? "btn--on" : ""}" data-cmd="autohop"
                    data-value="${a.autoHop ? "off" : "on"}" title="Auto Hop">Auto hop</button>
            <button class="btn btn--sm" data-cmd="hop" title="Hop server now">Hop now</button>
            <button class="btn btn--sm ${a.waitEvent ? "btn--on" : ""}" data-cmd="waitevent"
                    data-value="${a.waitEvent ? "off" : "on"}"
                    title="Hold collecting and hopping until the Bee event starts">Wait event</button>
            <button class="btn btn--sm ${a.antiAfk ? "btn--on" : ""}" data-cmd="antiafk"
                    data-value="${a.antiAfk ? "off" : "on"}" title="Anti-AFK">Anti-AFK</button>
            <button class="btn btn--sm ${selected ? "btn--on" : "btn--ghost"}" data-focus>
                ${selected ? "On the chart" : "See curve"}
            </button>
            <button class="btn btn--sm btn--danger" data-remove title="Remove from panel">Remove</button>
        </div>
    </article>`;
}

/**
 * Estado del evento en una cuenta. Se dice SIEMPRE con texto: "off" con el bot
 * esperando y "off" con el bot juntando igual son dos situaciones distintas y
 * el color solo no las separa.
 */
function eventCell(account) {
    if (!account.online) return "—";
    if (account.eventActive) return '<span class="ev ev--live">live</span>';
    return account.waitEvent
        ? '<span class="ev ev--hold">off · holding</span>'
        : '<span class="ev">off</span>';
}

function renderRanking() {
    const accounts = [...state.data.accounts].sort((a, b) => b.honey - a.honey);
    const section = $("ranking-section");

    if (accounts.length < 2) {
        section.hidden = true;
        return;
    }
    section.hidden = false;

    const max = Math.max(...accounts.map((a) => a.honey), 1);

    $("ranking").innerHTML = accounts
        .map(
            (a, i) => `
            <div class="rank-row">
                <span class="rank-row__pos num">${i + 1}</span>
                ${avatarHtml(a, "sm")}
                <span class="rank-row__name">${escapeHtml(a.username)}</span>
                <span class="rank-row__bar">
                    <span class="rank-row__fill" style="width:${(a.honey / max) * 100}%;background:${rampColor(
                        a.honey,
                        max
                    )}"></span>
                </span>
                <span class="rank-row__val num">${fmt(a.honey)}</span>
            </div>`
        )
        .join("");

    $("table-view").innerHTML = `
        <table class="data">
            <caption class="sr-only">Totals per account</caption>
            <thead>
                <tr>
                    <th scope="col">Account</th>
                    <th scope="col">Status</th>
                    <th scope="col">Honey</th>
                    <th scope="col">Session</th>
                    <th scope="col">Hops</th>
                    <th scope="col">Last jar</th>
                </tr>
            </thead>
            <tbody>
                ${accounts
                    .map(
                        (a) => `
                    <tr>
                        <td>${escapeHtml(a.username)}</td>
                        <td>${statusOf(a).label}</td>
                        <td>${fmt(a.honey)}</td>
                        <td>${fmt(a.sessionHoney)}</td>
                        <td>${fmt(a.hops)}</td>
                        <td>${ago(a.lastJarAt)}</td>
                    </tr>`
                    )
                    .join("")}
            </tbody>
        </table>`;
}

// ── acciones ──────────────────────────────────────────────────

async function sendCommand(accountId, kind, value, button) {
    const previous = button.textContent;
    button.disabled = true;
    button.textContent = "…";
    try {
        const res = await fetch(`/api/accounts/${accountId}/command`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ kind, value }),
        });
        if (!res.ok) throw new Error("command");
        await load();
    } catch {
        button.textContent = "✕";
        setTimeout(() => {
            button.textContent = previous;
            button.disabled = false;
        }, 1200);
    }
}

async function removeAccount(account) {
    const ok = confirm(
        `Remove "${account.username}" from the panel?\n\n` +
        "Its history and totals are deleted. If the script keeps running with your token, " +
        "the account shows up again on the next beat, starting from zero."
    );
    if (!ok) return;
    await fetch(`/api/accounts/${account.id}`, { method: "DELETE" });
    if (state.selected === account.id) state.selected = null;
    load();
}

// ── admin: usuarios y acceso ──────────────────────────────────
//
// Solo lo ve el primer usuario que se registro. El server manda 403 a
// /api/admin/* para cualquier otro, asi que esconder la pestana es comodidad,
// no seguridad: aunque alguien la fuerce desde la consola no ve nada.

async function loadAdmin() {
    try {
        const res = await fetch("/api/admin/overview");
        if (!res.ok) return;
        state.adminData = await res.json();
        // Cuenta como latido: si no, el indicador de arriba se pone en "sin
        // conexion" apenas la pestana de usuarios deja de pedir el overview.
        state.lastOk = Date.now();
        renderAdmin();
    } catch {
        // El tick siguiente reintenta; no vale la pena vaciar la tabla.
    }
}

function renderAdmin() {
    if (!state.adminData) return;
    const { totals, users } = state.adminData;

    $("admin-sub").textContent = totals.pending
        ? `${totals.users} total · ${totals.pending} waiting for access`
        : `${totals.users} total · none waiting`;

    const tiles = [
        ["Users", totals.users, `${totals.approved} with access`],
        ["Accounts created", totals.accounts, "across everyone"],
        ["Reporting now", totals.online, `${totals.running} with the collector on`],
        ["Hub honey", fmt(totals.honey), "total across all accounts"],
    ];
    $("admin-tiles").innerHTML = tiles
        .map(
            ([label, value, foot]) => `
        <div class="tile">
            <span class="tile__label">${label}</span>
            <span class="tile__value num">${typeof value === "number" ? fmt(value) : value}</span>
            <span class="tile__foot">${foot}</span>
        </div>`
        )
        .join("");

    $("admin-users").innerHTML = `
        <table class="data">
            <caption class="sr-only">Hub users and their access</caption>
            <thead>
                <tr>
                    <th scope="col">User</th>
                    <th scope="col">Accounts</th>
                    <th scope="col">Live</th>
                    <th scope="col">Running</th>
                    <th scope="col">Honey</th>
                    <th scope="col">Last seen</th>
                    <th scope="col">Access</th>
                </tr>
            </thead>
            <tbody>
                ${users
                    .map(
                        (u) => `
                    <tr>
                        <td>
                            ${escapeHtml(u.username)}
                            ${u.admin ? '<span class="badge badge--good" style="margin-left:6px">admin</span>' : ""}
                        </td>
                        <td>${fmt(u.accounts)}</td>
                        <td>${u.online ? fmt(u.online) : "—"}</td>
                        <td>${u.running ? fmt(u.running) : "—"}</td>
                        <td>${fmt(u.honey)}</td>
                        <td>${ago(u.lastSeen)}</td>
                        <td>${accessCell(u)}</td>
                    </tr>`
                    )
                    .join("")}
            </tbody>
        </table>`;

    for (const button of $("admin-users").querySelectorAll("[data-access]")) {
        button.addEventListener("click", () =>
            setAccess(Number(button.dataset.access), button.dataset.to === "on", button)
        );
    }
}

function accessCell(user) {
    if (user.admin) return '<span class="muted">always</span>';
    return user.approved
        ? `<button class="btn btn--sm btn--danger" data-access="${user.id}" data-to="off">Revoke access</button>`
        : `<button class="btn btn--sm btn--primary" data-access="${user.id}" data-to="on">Grant access</button>`;
}

async function setAccess(userId, approved, button) {
    const previous = button.textContent;
    button.disabled = true;
    button.textContent = "…";
    try {
        const res = await fetch(`/api/admin/users/${userId}/access`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ approved }),
        });
        if (!res.ok) throw new Error("access");
        await loadAdmin();
    } catch {
        button.textContent = "✕";
        setTimeout(() => {
            button.textContent = previous;
            button.disabled = false;
        }, 1200);
    }
}

/**
 * Las dos vistas comparten el <main>: cambiar de pestana esconde todo lo que no
 * es de la vista activa. Al volver al panel se re-renderiza, porque el podio y
 * el ranking deciden solos si se muestran o no.
 */
function setView(view) {
    state.view = view;
    for (const node of $("main").children) {
        node.hidden = (node.id === "view-admin") !== (view === "admin");
    }
    for (const button of $("views").querySelectorAll("button")) {
        button.setAttribute("aria-pressed", String(button.dataset.view === view));
    }
    $("connect-btn").hidden = view === "admin";

    if (view === "admin") loadAdmin();
    else if (state.data) render();
}

// ── modal de conexión ─────────────────────────────────────────

// El token va tambien en la URL: el server no entrega el .lua sin el, asi que
// el codigo del collector no queda colgado de un link publico.
function snippetFor(token) {
    return [
        `loadstring(game:HttpGet("${location.origin}/honey_hub.lua?token=${encodeURIComponent(token)}"))(`,
        `    "${location.origin}", "${token}"`,
        `)`,
    ].join("\n");
}

function openConnectModal() {
    // Sin acceso no hay token que mostrar: el server ni siquiera lo manda.
    $("connect-open").hidden = !state.approved;
    $("connect-locked").hidden = state.approved;
    $("token-value").textContent = state.token ?? "…";
    $("snippet").textContent = state.token ? snippetFor(state.token) : "…";
    $("connect-modal").hidden = false;
}

function wireModal() {
    $("connect-btn").addEventListener("click", openConnectModal);
    $("connect-close").addEventListener("click", () => ($("connect-modal").hidden = true));
    $("connect-modal").addEventListener("click", (event) => {
        if (event.target === $("connect-modal")) $("connect-modal").hidden = true;
    });
    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") $("connect-modal").hidden = true;
    });

    const copyTo = async (button, text, restore) => {
        try {
            await navigator.clipboard.writeText(text);
            button.textContent = "Copied!";
        } catch {
            // El portapapeles necesita contexto seguro; sin https queda el
            // seleccionar-y-copiar a mano, asi que al menos se avisa.
            button.textContent = "Copy it by hand";
        }
        setTimeout(() => (button.textContent = restore), 1600);
    };

    $("token-copy").addEventListener("click", (event) =>
        copyTo(event.target, state.token ?? "", "Copy")
    );

    $("snippet-copy").addEventListener("click", (event) =>
        copyTo(event.target, snippetFor(state.token ?? ""), "Copy the 3 lines")
    );

    $("token-rotate").addEventListener("click", async () => {
        const ok = confirm(
            "Rotating the token kills the old one instantly.\n\n" +
            "Every account using it stops reporting until you update the script. Continue?"
        );
        if (!ok) return;
        const res = await fetch("/api/auth/token/rotate", { method: "POST" });
        const body = await res.json();
        state.token = body.apiToken;
        openConnectModal();
    });
}

// ── arranque ──────────────────────────────────────────────────

function wireControls() {
    for (const button of $("range").querySelectorAll("button")) {
        button.addEventListener("click", () => {
            state.range = button.dataset.range;
            for (const other of $("range").querySelectorAll("button")) {
                other.setAttribute("aria-pressed", String(other === button));
            }
            load();
        });
    }

    for (const button of $("sort").querySelectorAll("button")) {
        button.addEventListener("click", () => {
            state.sort = button.dataset.sort;
            for (const other of $("sort").querySelectorAll("button")) {
                other.setAttribute("aria-pressed", String(other === button));
            }
            renderAccounts();
        });
    }

    $("table-toggle").addEventListener("click", () => {
        state.tableView = !state.tableView;
        $("ranking").hidden = state.tableView;
        $("table-view").hidden = !state.tableView;
        $("table-toggle").textContent = state.tableView ? "View as ranking" : "View as table";
        $("table-toggle").setAttribute("aria-expanded", String(state.tableView));
    });

    for (const button of $("views").querySelectorAll("button")) {
        button.addEventListener("click", () => setView(button.dataset.view));
    }

    $("logout-btn").addEventListener("click", async () => {
        await fetch("/api/auth/logout", { method: "POST" });
        location.replace("/");
    });

    // El grafico es SVG con viewBox: se re-dibuja al cambiar el ancho para que
    // el numero de etiquetas siga teniendo sentido.
    let resizeTimer;
    addEventListener("resize", () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => state.data && renderChart(), 200);
    });
}

async function boot() {
    const me = await fetch("/api/auth/me");
    if (!me.ok) {
        location.replace("/");
        return;
    }
    const user = (await me.json()).user;
    state.token = user.apiToken;
    state.approved = Boolean(user.approved);
    state.admin = Boolean(user.admin);

    // La pestana de usuarios solo existe para el admin.
    $("views").hidden = !state.admin;

    wireControls();
    wireModal();
    await load();

    // Recien registrado: si todavia no tiene acceso, el modal explica que
    // falta la aprobacion en vez de mostrarle un loader que no le va a andar.
    if (new URLSearchParams(location.search).get("welcome") || !state.approved) {
        openConnectModal();
        history.replaceState(null, "", "/panel");
    }

    setInterval(() => (state.view === "admin" ? loadAdmin() : load()), POLL_MS);
    setInterval(markStale, POLL_MS);
}

boot();
