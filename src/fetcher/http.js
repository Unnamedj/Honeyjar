import https from "node:https";
import { HttpsProxyAgent } from "https-proxy-agent";
import { penalize, proxyUrl } from "./proxies.js";

/**
 * GET + JSON.parse a traves de un proxy HTTP (tunel CONNECT). Se usa node:https
 * a pelo en vez de fetch porque el fetch de Node no expone un punto donde
 * enchufar un agent de proxy sin arrastrar undici como dependencia.
 *
 * Nunca tira: devuelve { ok, status, data, error }. El scraper corre en un loop
 * infinito y una excepcion suelta ahi se lleva puesto el proceso entero.
 */
export function getJson(url, { proxy = null, timeoutMs = 15_000 } = {}) {
    return new Promise((resolve) => {
        let settled = false;
        let req = null;
        let agent;
        let guard = null;

        const done = (result) => {
            if (settled) return;
            settled = true;
            if (guard) clearTimeout(guard);
            // El agent es nuevo por request (cada una sale por otra IP, no hay
            // nada que reusar), asi que se cierra con ella: si no, un tunel que
            // quedo a medias se lleva un socket para siempre.
            agent?.destroy?.();
            resolve(result);
        };

        // Timeout DURO. El `timeout` de https.get solo corre una vez que hay
        // socket asignado, y con un proxy que traga el CONNECT sin contestar
        // nunca lo hay: la request se cuelga para siempre y con ella el worker
        // del scraper. Este timer es la unica garantia de que la promesa cierra.
        guard = setTimeout(() => {
            penalize(proxy, 60_000);
            req?.destroy();
            done({ ok: false, status: 0, error: "timeout (proxy sin responder)" });
        }, timeoutMs + 2_000);
        guard.unref?.();

        if (proxy) {
            try {
                // El timeout va tambien en el agent: es el que corta el socket
                // del tunel mientras se esta estableciendo. Sin el, un proxy que
                // no acepta la conexion deja el socket colgado hasta que se
                // rinde el sistema operativo (~2 min).
                agent = new HttpsProxyAgent(proxyUrl(proxy), { timeout: timeoutMs });
            } catch (err) {
                return done({ ok: false, status: 0, error: `proxy invalido: ${err.message}` });
            }
        }

        req = https.get(
            url,
            {
                agent,
                timeout: timeoutMs,
                headers: {
                    // Roblox responde 403 a clientes sin UA de navegador.
                    "User-Agent":
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                    Accept: "application/json",
                },
            },
            (res) => {
                const status = res.statusCode ?? 0;
                let body = "";
                res.setEncoding("utf8");
                // Un cuerpo enorme (o un proxy que devuelve HTML de error) no
                // deberia poder inflar la memoria del proceso.
                res.on("data", (chunk) => {
                    if (body.length < 4_000_000) body += chunk;
                });
                res.on("end", () => {
                    if (status !== 200) {
                        if (status === 407 || status === 403) penalize(proxy, 60_000);
                        return done({ ok: false, status, error: `HTTP ${status}` });
                    }
                    try {
                        done({ ok: true, status, data: JSON.parse(body) });
                    } catch {
                        done({ ok: false, status, error: "respuesta no es JSON" });
                    }
                });
                res.on("error", (err) => done({ ok: false, status, error: err.message }));
            }
        );

        req.on("timeout", () => {
            penalize(proxy, 30_000);
            req.destroy(new Error("timeout"));
        });

        req.on("error", (err) => {
            // Socket caido/rechazado: casi siempre es el proxy, no Roblox.
            penalize(proxy, 30_000);
            done({ ok: false, status: 0, error: err.message });
        });
    });
}
