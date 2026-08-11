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

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, "..", "public");

const app = express();
app.set("trust proxy", 1); // Railway termina TLS en su proxy
app.use(express.json({ limit: "64kb" }));
app.use(cookieParser());

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
