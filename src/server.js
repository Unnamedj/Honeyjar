import "dotenv/config";
import path from "node:path";
import { fileURLToPath } from "node:url";
import cookieParser from "cookie-parser";
import express from "express";
import { migrate, pool } from "./db.js";
import { startFetcher, stopFetcher } from "./fetcher/pool.js";
import { adminRouter } from "./routes/admin.js";
import { authRouter } from "./routes/auth.js";
import { botRouter } from "./routes/bot.js";
import { dashRouter } from "./routes/dash.js";
import { fetchRouter } from "./routes/fetch.js";
import { scriptsRouter } from "./routes/scripts.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, "..", "public");

const app = express();
app.set("trust proxy", 1); // Railway termina TLS en su proxy
app.disable("x-powered-by"); // no hace falta anunciar con que esta hecho
app.use(express.json({ limit: "64kb" }));
app.use(cookieParser());

/**
 * Cabeceras de seguridad. Sin helmet: son seis lineas y una dependencia menos
 * que auditar.
 *
 * La CSP es la que hace el trabajo. Todo el JS del panel son modulos con src
 * propio, asi que 'self' alcanza y NO hace falta 'unsafe-inline' para scripts
 * -- eso es lo que convierte un XSS en nada. Los estilos si lo necesitan
 * porque el panel usa atributos style= y los graficos SVG se pintan inline.
 * Las unicas imagenes de afuera son los avatares de Roblox.
 */
const CSP = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https://*.rbxcdn.com",
    "connect-src 'self'",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
].join("; ");

app.use((_req, res, next) => {
    res.setHeader("Content-Security-Policy", CSP);
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Permissions-Policy", "geolocation=(), microphone=(), camera=(), interest-cohort=()");
    // HSTS solo en produccion: en local no hay TLS y esto dejaria el navegador
    // insistiendo con https://localhost por meses.
    if (process.env.NODE_ENV === "production") {
        res.setHeader("Strict-Transport-Security", "max-age=15552000; includeSubDomains");
    }
    next();
});

app.get("/api/health", (_req, res) => res.json({ ok: true }));

app.use("/api/auth", authRouter);
app.use("/api/bot", botRouter);
// Antes que dashRouter: dashRouter esta montado en /api y exige cookie de
// sesion para TODO lo que le entra, y el fetcher se autentica con el api_token
// del script, no con la cookie del panel.
app.use("/api/fetch", fetchRouter);
// Tambien antes que dashRouter, que se come todo /api: /api/admin tiene su
// propio guardia (sesion + ser el primer usuario).
app.use("/api/admin", adminRouter);
app.use("/api", dashRouter);
// Los .lua se sirven aca y no desde public/: exigen token (ver routes/scripts.js).
app.use("/", scriptsRouter);

app.use(
    express.static(PUBLIC_DIR, {
        extensions: ["html"],
        setHeaders(res, filePath) {
            // El HTML se revalida siempre; el resto puede cachearse un rato.
            if (filePath.endsWith(".html")) res.setHeader("Cache-Control", "no-cache");
        },
    })
);

// Una ruta de API que no existe devuelve JSON, no el HTML del login: un fetch
// que recibe "<!doctype html>" falla al parsear y esconde el 404 real.
app.use("/api", (_req, res) => res.status(404).json({ error: "no_encontrado" }));
app.use((_req, res) => res.status(404).sendFile(path.join(PUBLIC_DIR, "index.html")));

// eslint-disable-next-line no-unused-vars -- express reconoce el handler de error por su aridad
app.use((err, _req, res, _next) => {
    console.error("[honey-hub]", err);
    res.status(500).json({ error: "error_interno" });
});

const PORT = Number(process.env.PORT) || 3000;

await migrate();
const server = app.listen(PORT, () => {
    console.log(`[honey-hub] escuchando en :${PORT}`);
});

// El scraper arranca despues del listen: si Railway tarda en resolver los
// proxies, el healthcheck ya contesta igual.
startFetcher();

for (const signal of ["SIGTERM", "SIGINT"]) {
    process.on(signal, () => {
        stopFetcher();
        server.close(() => pool.end().then(() => process.exit(0)));
    });
}
