import { areaChart, rampColor, sparkline } from "/js/charts.js";

const POLL_MS = 4000;

const state = {
    data: null,
    range: "24h",
    sort: "honey",
    selected: null,   // id de cuenta en modo enfasis, o null = equipo
    tableView: false,
    token: null,
    lastOk: 0,
};

// ── utilidades ────────────────────────────────────────────────

const $ = (id) => document.getElementById(id);

const nf = new Intl.NumberFormat("es");
const fmt = (n) => nf.format(Math.round(n || 0));

function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => (
        { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
}

function ago(stamp) {
    if (!stamp) return "nunca";
    const secs = Math.max(0, Math.round((Date.now() - stamp) / 1000));
    if (secs < 10) return "recién";
    if (secs < 60) return `hace ${secs} s`;
    if (secs < 3600) return `hace ${Math.floor(secs / 60)} min`;
    if (secs < 86400) return `hace ${Math.floor(secs / 3600)} h`;
    return `hace ${Math.floor(secs / 86400)} d`;
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
    collecting: { tone: "good",     label: "Recolectando" },
    waiting:    { tone: "warning",  label: "Esperando jars" },
    hopping:    { tone: "serious",  label: "Cambiando server" },
    stopped:    { tone: "muted",    label: "Detenido" },
    idle:       { tone: "muted",    label: "En espera" },
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
    const photo = account.avatarUrl
        ? `<img src="${escapeHtml(account.avatarUrl)}" alt="" loading="lazy" onerror="this.remove()">`
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
    if (stale) $("pulse-text").textContent = "Sin conexión";
}

// ── render ────────────────────────────────────────────────────

function render() {
    const { totals, accounts } = state.data;

    $("pulse").classList.remove("pulse--stale");
    $("pulse-text").textContent = `${totals.online} en vivo`;

    $("hero-honey").textContent = fmt(totals.honey);
    $("hero-sub").textContent = accounts.length
        ? `Sumando ${accounts.length} ${accounts.length === 1 ? "cuenta" : "cuentas"}`
        : "Todavía no hay cuentas conectadas";

    $("kpi-accounts").textContent = `${totals.online}/${totals.accounts}`;
    $("kpi-accounts-foot").textContent = totals.online
        ? `${totals.online} reportando ahora`
        : "ninguna reportando";
    $("kpi-rate").textContent = fmt(totals.perHour);
    $("kpi-hops").textContent = fmt(totals.hops);
    $("kpi-streak").textContent = totals.streak;
    $("kpi-streak-foot").textContent = totals.bestHour
        ? `mejor hora: ${String(totals.bestHour.hour).padStart(2, "0")}:00`
        : "días seguidos";

    $("accounts-count").textContent = accounts.length
        ? `${accounts.length} en total · ${totals.online} en vivo`
        : "";

    renderChart();
    renderPodium();
    renderAccounts();
    renderRanking();
}

function renderChart() {
    const { series, accounts } = state.data;
    const selected = accounts.find((a) => a.id === state.selected);

    // Al seleccionar una cuenta el grafico pasa a enfasis: ella en ambar, el
    // equipo detras en gris punteado. Dos series -> leyenda obligatoria.
    const spec = selected
        ? {
              t: series.t, values: selected.series, label: selected.username,
              context: series.honey, contextLabel: "Equipo completo", range: state.range,
          }
        : { t: series.t, values: series.honey, label: "Equipo completo", range: state.range };

    areaChart($("chart"), spec);

    const spanText = { "6h": "últimas 6 h", "24h": "últimas 24 h", "7d": "últimos 7 días" }[state.range];
    const bucketText = { "6h": "cada 15 min", "24h": "por hora", "7d": "cada 6 h" }[state.range];
    $("chart-title").textContent = selected
        ? `Ritmo de ${selected.username}`
        : "Ritmo de recolección";
    $("chart-sub").textContent = `Jars ${bucketText} · ${spanText}`;

    const legend = $("chart-legend");
    if (selected) {
        legend.innerHTML =
            `<span class="legend__item"><span class="legend__swatch" style="background:#ffab21"></span>${escapeHtml(selected.username)}</span>` +
            `<span class="legend__item"><span class="legend__swatch" style="background:#6a6270"></span>Equipo completo</span>` +
            `<button class="btn btn--sm btn--ghost" id="clear-selection">Ver el equipo</button>`;
        $("clear-selection").addEventListener("click", () => {
            state.selected = null;
            render();
        });
    } else {
        legend.innerHTML = accounts.length
            ? `<span class="legend__item muted">Tocá una tarjeta de cuenta para ver su curva sola.</span>`
            : "";
    }
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
                <h3>Ninguna cuenta conectada todavía</h3>
                <p>Pegá tu token en el collector de cada cuenta y van a aparecer acá solas,
                   con su avatar, su contador y sus controles.</p>
                <button class="btn btn--primary" id="empty-connect">Ver cómo conectar</button>
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
                ${fmt(a.honey)} <small>jars en total</small>
            </div>
            <div class="tile__spark" data-spark></div>
            <div class="muted" style="font-size:11px">
                ${fmt(a.sessionHoney)} en esta sesión · ${escapeHtml(a.status)}
            </div>
        </div>

        <div class="meta">
            <div class="meta__row"><span class="meta__key">Hops</span><span class="meta__val num">${fmt(a.hops)}</span></div>
            <div class="meta__row"><span class="meta__key">Uptime</span><span class="meta__val">${uptime}</span></div>
            <div class="meta__row"><span class="meta__key">Último jar</span><span class="meta__val">${ago(a.lastJarAt)}</span></div>
            <div class="meta__row"><span class="meta__key">Server</span><span class="meta__val">${
                a.jobId ? `${escapeHtml(a.jobId.slice(0, 8))}${a.players ? ` · ${a.players}p` : ""}` : "—"
            }</span></div>
            <div class="meta__row"><span class="meta__key">Método</span><span class="meta__val">${
                escapeHtml(a.method || "—")
            }${a.smartTp ? " 🧠" : ""}</span></div>
            <div class="meta__row"><span class="meta__key">Velocidad</span><span class="meta__val num">${
                a.speed ? `${a.speed}` : "—"
            }</span></div>
        </div>

        <div class="controls">
            ${
                a.pendingCommands
                    ? `<span class="controls__pending">⏳ ${a.pendingCommands} ${
                          a.pendingCommands === 1 ? "orden pendiente" : "órdenes pendientes"
                      } — se aplica en el próximo beat</span>`
                    : ""
            }
            <button class="btn btn--sm ${a.enabled ? "btn--on" : ""}" data-cmd="enabled"
                    data-value="${a.enabled ? "off" : "on"}">
                ${a.enabled ? "⏸ Pausar" : "▶ Recolectar"}
            </button>
            <button class="btn btn--sm ${a.method === "Grapple" ? "btn--on" : ""}"
                    data-cmd="method" data-value="Grapple"
                    title="Método: Grapple" aria-label="Usar método Grapple">🪝</button>
            <button class="btn btn--sm ${a.method === "Carpet" ? "btn--on" : ""}"
                    data-cmd="method" data-value="Carpet"
                    title="Método: Carpet" aria-label="Usar método Carpet">🧺</button>
            <button class="btn btn--sm ${a.autoHop ? "btn--on" : ""}" data-cmd="autohop"
                    data-value="${a.autoHop ? "off" : "on"}" title="Auto Hop">↷ Hop auto</button>
            <button class="btn btn--sm" data-cmd="hop" title="Saltar de server ahora">⇥ Hop ya</button>
            <button class="btn btn--sm ${selected ? "btn--on" : "btn--ghost"}" data-focus>
                ${selected ? "★ En el gráfico" : "📈 Ver curva"}
            </button>
            <button class="btn btn--sm btn--danger" data-remove title="Quitar del panel">🗑</button>
        </div>
    </article>`;
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
            <caption class="sr-only">Totales por cuenta</caption>
            <thead>
                <tr>
                    <th scope="col">Cuenta</th>
                    <th scope="col">Estado</th>
                    <th scope="col">Honey</th>
                    <th scope="col">Sesión</th>
                    <th scope="col">Hops</th>
                    <th scope="col">Último jar</th>
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
        `¿Quitar "${account.username}" del panel?\n\n` +
        "Se borran su historial y sus totales. Si el script sigue corriendo con tu token, " +
        "la cuenta vuelve a aparecer en el próximo beat, arrancando de cero."
    );
    if (!ok) return;
    await fetch(`/api/accounts/${account.id}`, { method: "DELETE" });
    if (state.selected === account.id) state.selected = null;
    load();
}

// ── modal de conexión ─────────────────────────────────────────

function snippetFor(token) {
    return [
        `loadstring(game:HttpGet("${location.origin}/honey_hub.lua"))(`,
        `    "${location.origin}", "${token}"`,
        `)`,
    ].join("\n");
}

function openConnectModal() {
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
            button.textContent = "¡Copiado!";
        } catch {
            // El portapapeles necesita contexto seguro; sin https queda el
            // seleccionar-y-copiar a mano, asi que al menos se avisa.
            button.textContent = "Copialo a mano";
        }
        setTimeout(() => (button.textContent = restore), 1600);
    };

    $("token-copy").addEventListener("click", (event) =>
        copyTo(event.target, state.token ?? "", "Copiar")
    );

    $("snippet-copy").addEventListener("click", (event) =>
        copyTo(event.target, snippetFor(state.token ?? ""), "Copiar las 3 líneas")
    );

    $("token-rotate").addEventListener("click", async () => {
        const ok = confirm(
            "Rotar el token invalida el anterior al instante.\n\n" +
            "Todas las cuentas que lo estén usando dejan de reportar hasta que actualices el script. ¿Seguimos?"
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
        $("table-toggle").textContent = state.tableView ? "Ver como ranking" : "Ver como tabla";
        $("table-toggle").setAttribute("aria-expanded", String(state.tableView));
    });

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
    state.token = (await me.json()).user.apiToken;

    wireControls();
    wireModal();
    await load();

    if (new URLSearchParams(location.search).get("welcome")) {
        openConnectModal();
        history.replaceState(null, "", "/panel");
    }

    setInterval(load, POLL_MS);
    setInterval(markStale, POLL_MS);
}

boot();
