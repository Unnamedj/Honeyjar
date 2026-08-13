import { one } from "../db.js";

/**
 * Catalogo de scripts que reparte el hub.
 *
 * Es la UNICA fuente de verdad: de aca salen las rutas que sirven los .lua, los
 * toggles de la pestana Users y los snippets del modal de conectar. Sumar un
 * script tercero es agregar una entrada y nada mas.
 *
 * `files` son los .lua que se descargan con ese permiso. El collector son dos
 * (el loader y el collector propiamente dicho, que el loader baja despues con
 * el mismo token), el merchant es uno solo porque es autocontenido y no recibe
 * argumentos: el snippet lo ejecuta directo.
 *
 * `fallback` es que pasa cuando el usuario no tiene fila en user_scripts. El
 * collector viene en true a proposito: es lo que ya estaban usando todos antes
 * de que existieran los permisos, y un deploy no puede cortarles los bots. Lo
 * que se agrega de ahora en mas entra en false y lo habilita el admin.
 */
export const SCRIPTS = {
    collector: {
        label: "Collector",
        description: "Honey TP Collector — junta las jarras del evento Bee y reporta al panel.",
        files: ["honey_hub.lua", "honey_tp.lua"],
        entry: "honey_hub.lua",
        // El loader recibe (url, token): reporta y acepta comandos del panel.
        args: true,
        fallback: true,
    },
    merchant: {
        label: "Merchant",
        description: "Honey Merchant — compra selectiva y sniper del BeeMerchantService.",
        files: ["honey_merchant.lua"],
        entry: "honey_merchant.lua",
        // Autocontenido: no recibe argumentos ni reporta a ningun lado.
        args: false,
        fallback: false,
    },
};

/** Nombre de archivo -> clave del script. Se arma una vez. */
export const FILE_TO_SCRIPT = Object.fromEntries(
    Object.entries(SCRIPTS).flatMap(([key, meta]) => meta.files.map((f) => [f, key]))
);

export const SCRIPT_KEYS = Object.keys(SCRIPTS);

export function isScriptKey(value) {
    return typeof value === "string" && Object.hasOwn(SCRIPTS, value);
}

/**
 * Que scripts puede usar un usuario, como objeto { collector: true, ... }.
 *
 * Reglas, en orden:
 *   · el admin puede todo, siempre (si no, un admin podria dejarse sin nada);
 *   · sin `approved` no puede nada, aunque tenga filas en user_scripts: el
 *     permiso por script afina, no reemplaza a la puerta general;
 *   · con fila, manda la fila;
 *   · sin fila, manda el fallback del catalogo.
 */
export function allowedFor(user, rows = []) {
    const explicit = new Map(rows.map((r) => [r.script, r.allowed]));
    const out = {};
    for (const [key, meta] of Object.entries(SCRIPTS)) {
        if (user?.is_admin || user?.admin) out[key] = true;
        else if (!user?.approved) out[key] = false;
        else out[key] = explicit.get(key) ?? meta.fallback;
    }
    return out;
}

/**
 * Resuelve el permiso de UN script para un usuario, contra la base. Devuelve
 * true/false. Lo usan las rutas que sirven los .lua.
 */
export async function userCanUse(userId, scriptKey) {
    if (!isScriptKey(scriptKey)) return false;

    const row = await one(
        `SELECT (u.id = (SELECT min(id) FROM users))            AS is_admin,
                (u.approved OR u.id = (SELECT min(id) FROM users)) AS approved,
                s.allowed
           FROM users u
           LEFT JOIN user_scripts s ON s.user_id = u.id AND s.script = $2
          WHERE u.id = $1`,
        [userId, scriptKey]
    );
    if (!row) return false;
    if (row.is_admin) return true;
    if (!row.approved) return false;
    return row.allowed ?? SCRIPTS[scriptKey].fallback;
}
