/* ============================================================
   Graficos — SVG a mano, sin librerias.
   ------------------------------------------------------------
   Formas usadas y por que:
     · Ritmo en el tiempo  -> area de UNA serie (el equipo). Al elegir una
       cuenta pasa a modo ENFASIS: esa cuenta en ambar, el equipo detras en
       gris de contexto. Nunca una linea por cuenta con un color inventado
       para cada una — con 10 cuentas ningun set de colores sobrevive.
     · Sparkline por tarjeta -> una serie, sin ejes: es textura, no lectura fina.
     · Ranking -> barras de magnitud con el ramp secuencial de un solo tono.
   Los ejes y la grilla van en tono recesivo; el dato es lo unico saturado.
   ============================================================ */

const NS = "http://www.w3.org/2000/svg";

const COLOR = {
    honey: "#ffab21",
    honeyLit: "#ffd65a",
    context: "#6a6270",
    grid: "#2c2630",
    axis: "#3a3340",
    muted: "#8a8090",
    surface: "#1b161c",
};

function el(name, attrs = {}) {
    const node = document.createElementNS(NS, name);
    for (const [key, value] of Object.entries(attrs)) {
        if (value !== null && value !== undefined) node.setAttribute(key, String(value));
    }
    return node;
}

/**
 * Tope del eje Y elegido desde el PASO, no desde el maximo: son cuatro lineas
 * de grilla, asi que lo que tiene que caer redondo es max/4. Elegirlo al reves
 * (un tope "lindo" dividido en 4) es lo que produce ejes con 187.5 y 562.5.
 */
function niceMax(value) {
    if (value <= 4) return 4;
    const raw = value / 4;
    const pow = 10 ** Math.floor(Math.log10(raw));
    for (const factor of [1, 2, 5, 10]) {
        const step = factor * pow;
        if (raw <= step) return Math.max(1, Math.ceil(step)) * 4;
    }
    return Math.ceil(10 * pow) * 4;
}

function formatTime(stamp, range) {
    const d = new Date(stamp);
    if (range === "7d") {
        return d.toLocaleDateString("en", { weekday: "short", day: "numeric" });
    }
    return d.toLocaleTimeString("en", { hour: "2-digit", minute: "2-digit" });
}

function formatFull(stamp) {
    return new Date(stamp).toLocaleString("en", {
        day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
    });
}

/**
 * Grafico de area con crosshair y tooltip.
 *
 * @param {HTMLElement} host      contenedor (position: relative)
 * @param {object}      spec
 * @param {number[]}    spec.t          timestamps
 * @param {number[]}    spec.values     serie principal
 * @param {string}      spec.label      nombre de la serie principal
 * @param {number[]}   [spec.context]   serie de contexto (modo enfasis)
 * @param {string}     [spec.contextLabel]
 * @param {string}      spec.range      '6h' | '24h' | '7d'
 */
export function areaChart(host, spec) {
    host.textContent = "";

    const { t, values, range } = spec;
    const hasData = values.some((v) => v > 0) || (spec.context ?? []).some((v) => v > 0);

    if (!t.length || !hasData) {
        const empty = document.createElement("div");
        empty.className = "chart-empty";
        empty.textContent = "No jars in this range yet. Turn on Auto Collect on some account.";
        host.appendChild(empty);
        return;
    }

    const W = 1000;
    const H = 260;
    const pad = { top: 16, right: 14, bottom: 28, left: 46 };
    const plotW = W - pad.left - pad.right;
    const plotH = H - pad.top - pad.bottom;

    const peak = Math.max(...values, ...(spec.context ?? [0]));
    const yMax = niceMax(peak);

    const x = (i) => pad.left + (t.length === 1 ? plotW / 2 : (i / (t.length - 1)) * plotW);
    const y = (v) => pad.top + plotH - (v / yMax) * plotH;

    const svg = el("svg", {
        viewBox: `0 0 ${W} ${H}`,
        preserveAspectRatio: "none",
        role: "img",
        "aria-label": `${spec.label}: collection rate`,
    });

    const gradId = `honey-fill-${Math.random().toString(36).slice(2, 8)}`;
    const defs = el("defs");
    const grad = el("linearGradient", { id: gradId, x1: "0", y1: "0", x2: "0", y2: "1" });
    grad.append(
        el("stop", { offset: "0%", "stop-color": COLOR.honey, "stop-opacity": "0.38" }),
        el("stop", { offset: "100%", "stop-color": COLOR.honey, "stop-opacity": "0.02" })
    );
    defs.appendChild(grad);
    svg.appendChild(defs);

    // Grilla horizontal + eje Y. Hairline, para que quede debajo del dato.
    for (let i = 0; i <= 4; i++) {
        const value = (yMax / 4) * i;
        const gy = y(value);
        svg.appendChild(
            el("line", {
                x1: pad.left, y1: gy, x2: W - pad.right, y2: gy,
                stroke: i === 0 ? COLOR.axis : COLOR.grid, "stroke-width": 1,
            })
        );
        const label = el("text", {
            x: pad.left - 10, y: gy + 4,
            "text-anchor": "end", fill: COLOR.muted,
            "font-size": 11, "font-family": "system-ui, sans-serif",
            style: "font-variant-numeric: tabular-nums",
        });
        label.textContent = value >= 1000 ? `${Math.round(value / 100) / 10}k` : String(value);
        svg.appendChild(label);
    }

    // Etiquetas de tiempo: como maximo 6, para que no se pisen.
    const tickEvery = Math.max(1, Math.ceil(t.length / 6));
    for (let i = 0; i < t.length; i += tickEvery) {
        const label = el("text", {
            x: x(i), y: H - 8,
            "text-anchor": "middle", fill: COLOR.muted,
            "font-size": 11, "font-family": "system-ui, sans-serif",
        });
        label.textContent = formatTime(t[i], range);
        svg.appendChild(label);
    }

    const linePath = (series) => series.map((v, i) => `${i ? "L" : "M"}${x(i)},${y(v)}`).join(" ");

    // Contexto primero: siempre por debajo de la serie enfatizada.
    if (spec.context) {
        svg.appendChild(
            el("path", {
                d: linePath(spec.context),
                fill: "none", stroke: COLOR.context, "stroke-width": 2,
                "stroke-linejoin": "round", "stroke-linecap": "round",
                "stroke-dasharray": "5 5", opacity: "0.85",
            })
        );
    }

    svg.appendChild(
        el("path", {
            d: `${linePath(values)} L${x(values.length - 1)},${y(0)} L${x(0)},${y(0)} Z`,
            fill: `url(#${gradId})`, stroke: "none",
        })
    );
    svg.appendChild(
        el("path", {
            d: linePath(values),
            fill: "none", stroke: COLOR.honey, "stroke-width": 2,
            "stroke-linejoin": "round", "stroke-linecap": "round",
        })
    );

    // Etiqueta directa en el pico: un solo numero, el que importa. Nunca uno
    // por punto.
    const peakIndex = values.indexOf(Math.max(...values));
    if (values[peakIndex] > 0) {
        svg.appendChild(
            el("circle", {
                cx: x(peakIndex), cy: y(values[peakIndex]), r: 4.5,
                fill: COLOR.honeyLit, stroke: COLOR.surface, "stroke-width": 2,
            })
        );
        const tag = el("text", {
            x: x(peakIndex), y: y(values[peakIndex]) - 12,
            "text-anchor": peakIndex > t.length - 3 ? "end" : peakIndex < 2 ? "start" : "middle",
            fill: COLOR.honeyLit, "font-size": 12, "font-weight": "700",
            "font-family": "system-ui, sans-serif",
        });
        tag.textContent = `${values[peakIndex]} 🍯`;
        svg.appendChild(tag);
    }

    // ── Capa de hover ──
    const crosshair = el("line", {
        y1: pad.top, y2: pad.top + plotH,
        stroke: COLOR.axis, "stroke-width": 1, opacity: "0",
    });
    const marker = el("circle", {
        r: 5, fill: COLOR.honey, stroke: COLOR.surface, "stroke-width": 2, opacity: "0",
    });
    const contextMarker = el("circle", {
        r: 4, fill: COLOR.context, stroke: COLOR.surface, "stroke-width": 2, opacity: "0",
    });
    svg.append(crosshair, contextMarker, marker);

    const capture = el("rect", {
        x: pad.left, y: pad.top, width: plotW, height: plotH,
        fill: "transparent", style: "cursor: crosshair",
    });
    svg.appendChild(capture);
    host.appendChild(svg);

    const tip = document.createElement("div");
    tip.className = "chart__tip";
    host.appendChild(tip);

    const swatchRow = (color, name, value) =>
        `<div class="chart__tip-row">
             <span class="chart__tip-swatch" style="background:${color}"></span>
             <span>${name}</span>
             <span class="chart__tip-value num">${value}</span>
         </div>`;

    function hideTip() {
        tip.dataset.show = "0";
        crosshair.setAttribute("opacity", "0");
        marker.setAttribute("opacity", "0");
        contextMarker.setAttribute("opacity", "0");
    }

    function moveTip(event) {
        const box = svg.getBoundingClientRect();
        const localX = ((event.clientX - box.left) / box.width) * W;
        const ratio = (localX - pad.left) / plotW;
        const index = Math.max(0, Math.min(t.length - 1, Math.round(ratio * (t.length - 1))));

        crosshair.setAttribute("x1", x(index));
        crosshair.setAttribute("x2", x(index));
        crosshair.setAttribute("opacity", "1");
        marker.setAttribute("cx", x(index));
        marker.setAttribute("cy", y(values[index]));
        marker.setAttribute("opacity", "1");

        let rows = swatchRow(COLOR.honey, spec.label, values[index]);
        if (spec.context) {
            contextMarker.setAttribute("cx", x(index));
            contextMarker.setAttribute("cy", y(spec.context[index]));
            contextMarker.setAttribute("opacity", "1");
            rows += swatchRow(COLOR.context, spec.contextLabel ?? "Equipo", spec.context[index]);
        }

        tip.innerHTML = `<div class="chart__tip-time">${formatFull(t[index])}</div>${rows}`;
        tip.dataset.show = "1";
        tip.style.left = `${(x(index) / W) * 100}%`;
        tip.style.top = `${(y(values[index]) / H) * 100}%`;
    }

    capture.addEventListener("pointermove", moveTip);
    capture.addEventListener("pointerdown", moveTip);
    capture.addEventListener("pointerleave", hideTip);
}

/** Sparkline sin ejes: solo la forma del ritmo reciente. */
export function sparkline(host, values, { color = COLOR.honey } = {}) {
    host.textContent = "";
    if (!values.length) return;

    const W = 200;
    const H = 40;
    const max = Math.max(...values, 1);
    const x = (i) => (values.length === 1 ? W / 2 : (i / (values.length - 1)) * W);
    const y = (v) => H - 3 - (v / max) * (H - 8);

    const svg = el("svg", {
        viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none",
        "aria-hidden": "true", style: "width:100%;height:100%",
    });

    const line = values.map((v, i) => `${i ? "L" : "M"}${x(i)},${y(v)}`).join(" ");
    const gradId = `spark-${Math.random().toString(36).slice(2, 8)}`;
    const defs = el("defs");
    const grad = el("linearGradient", { id: gradId, x1: "0", y1: "0", x2: "0", y2: "1" });
    grad.append(
        el("stop", { offset: "0%", "stop-color": color, "stop-opacity": "0.34" }),
        el("stop", { offset: "100%", "stop-color": color, "stop-opacity": "0" })
    );
    defs.appendChild(grad);
    svg.appendChild(defs);

    svg.appendChild(
        el("path", { d: `${line} L${x(values.length - 1)},${H} L${x(0)},${H} Z`, fill: `url(#${gradId})` })
    );
    svg.appendChild(
        el("path", {
            d: line, fill: "none", stroke: color, "stroke-width": 2,
            "stroke-linejoin": "round", "stroke-linecap": "round",
            "vector-effect": "non-scaling-stroke",
        })
    );

    host.appendChild(svg);
}

/** Los 5 pasos del ramp ambar, de menos a mas. */
export const RAMP = ["#7a5413", "#a87316", "#d1911a", "#ffab21", "#ffd65a"];

/** Color de una barra segun su magnitud relativa al maximo de la lista. */
export function rampColor(value, max) {
    if (max <= 0) return RAMP[0];
    const index = Math.min(RAMP.length - 1, Math.floor((value / max) * RAMP.length));
    return RAMP[Math.max(0, index)];
}
