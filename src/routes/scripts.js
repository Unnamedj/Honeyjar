import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Router } from "express";
import { one } from "../db.js";
import { FILE_TO_SCRIPT, SCRIPTS, userCanUse } from "../lib/scripts.js";

export const scriptsRouter = Router();

const LUA_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "lua");

/**
 * Los .lua NO viven en public/ a proposito: ahi los servia express.static y
 * cualquiera con la URL se bajaba el collector entero. Se sirven desde aca,
 * y solo con un token valido Y el permiso de ese script.
 *
 * El token viaja en la query porque game:HttpGet no manda headers -- es la
 * unica forma que tiene el ejecutor de pedirlo. Eso significa que puede
 * quedar en logs de proxies: no es un secreto de grado militar, es la
 * diferencia entre "lo tiene el que se lo gano" y "lo tiene cualquiera que
 * pegue la URL en el navegador".
 */
const FETCH_TOKEN = process.env.FETCH_TOKEN || "";

/**
 * Resuelve el token a un permiso concreto sobre ESE script.
 *
 * El FETCH_TOKEN compartido sigue abriendo todo: es el que viaja embebido en lo
 * que se reparte y no cuelga de ningun usuario, asi que no hay a quien
 * preguntarle permisos. El token de una cuenta, en cambio, ahora se chequea
 * contra user_scripts: tener token no alcanza, hay que tener habilitado ese
 * script en particular.
 */
async function tokenSirve(raw, scriptKey) {
    const token = typeof raw === "string" ? raw.trim().slice(0, 80) : "";
    if (!token) return false;

    if (FETCH_TOKEN && token === FETCH_TOKEN) return true;

    const user = await one("SELECT id FROM users WHERE api_token = $1", [token]);
    if (!user) return false;

    return userCanUse(user.id, scriptKey);
}

// Cache en memoria: el archivo no cambia entre deploys y esto se pide una vez
// por ejecucion de script, pero con muchas cuentas son muchas lecturas de disco.
const cache = new Map();

async function leer(nombre) {
    if (cache.has(nombre)) return cache.get(nombre);
    const texto = await fs.readFile(path.join(LUA_DIR, nombre), "utf8");
    cache.set(nombre, texto);
    return texto;
}

// Las rutas salen del catalogo, no de una lista a mano: agregar un script en
// src/lib/scripts.js lo publica solo, con su permiso ya enganchado.
for (const [nombre, scriptKey] of Object.entries(FILE_TO_SCRIPT)) {
    scriptsRouter.get(`/${nombre}`, async (req, res) => {
        const raw = req.query?.token
            ?? (req.get("authorization") ?? "").replace(/^Bearer /, "");

        if (!(await tokenSirve(raw, scriptKey))) {
            // Texto plano y no JSON: del otro lado hay un loadstring, y un
            // warn con el motivo se lee mejor que un objeto sin parsear. El
            // mensaje nombra el script para que se entienda que puede ser
            // permiso de ESE y no del token en general.
            return res
                .status(401)
                .type("text/plain")
                .send(
                    `-- Honey Hub: invalid token, or your account cannot use ` +
                    `${SCRIPTS[scriptKey].label}.\n`
                );
        }

        res.type("text/plain");
        res.setHeader("Cache-Control", "no-store");
        res.send(await leer(nombre));
    });
}
