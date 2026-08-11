import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Router } from "express";
import { one } from "../db.js";

export const scriptsRouter = Router();

const LUA_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "lua");

/**
 * Los .lua NO viven en public/ a proposito: ahi los servia express.static y
 * cualquiera con la URL se bajaba el collector entero. Se sirven desde aca,
 * y solo con un token valido.
 *
 * El token viaja en la query porque game:HttpGet no manda headers -- es la
 * unica forma que tiene el ejecutor de pedirlo. Eso significa que puede
 * quedar en logs de proxies: no es un secreto de grado militar, es la
 * diferencia entre "lo tiene el que se lo gano" y "lo tiene cualquiera que
 * pegue la URL en el navegador".
 */
const FETCH_TOKEN = process.env.FETCH_TOKEN || "";

async function tokenSirve(raw) {
    const token = typeof raw === "string" ? raw.trim().slice(0, 80) : "";
    if (!token) return false;

    // El token compartido del script general vale igual que el de una cuenta:
    // es el que viaja embebido en el .lua que se reparte.
    if (FETCH_TOKEN && token === FETCH_TOKEN) return true;

    const user = await one(
        `SELECT 1 FROM users
          WHERE api_token = $1
            AND (approved OR id = (SELECT min(id) FROM users))`,
        [token]
    );
    return Boolean(user);
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

for (const nombre of ["honey_hub.lua", "honey_tp.lua"]) {
    scriptsRouter.get(`/${nombre}`, async (req, res) => {
        const raw = req.query?.token
            ?? (req.get("authorization") ?? "").replace(/^Bearer /, "");

        if (!(await tokenSirve(raw))) {
            // Texto plano y no JSON: del otro lado hay un loadstring, y un
            // warn con el motivo se lee mejor que un objeto sin parsear.
            return res
                .status(401)
                .type("text/plain")
                .send("-- Honey Hub: invalid token or account without access.\n");
        }

        res.type("text/plain");
        res.setHeader("Cache-Control", "no-store");
        res.send(await leer(nombre));
    });
}
