import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

if (!process.env.DATABASE_URL) {
    console.error(
        "[honey-hub] falta DATABASE_URL.\n" +
        "  Railway: agregale el plugin de Postgres al proyecto y la variable aparece sola.\n" +
        "  Local:   copia .env.example a .env y apuntala a tu Postgres."
    );
    process.exit(1);
}

// Postgres de Railway habla TLS pero con certificado propio, asi que el
// verificador de Node lo rechaza. Fuera de localhost va TLS sin verificar CA.
const isLocal = /@(localhost|127\.0\.0\.1)/.test(process.env.DATABASE_URL);

export const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: isLocal ? false : { rejectUnauthorized: false },
    max: 10,
    idleTimeoutMillis: 30_000,
});

export function query(text, params) {
    return pool.query(text, params);
}

/** Primera fila de la consulta, o null. Evita el `.rows[0]` repetido en todos lados. */
export async function one(text, params) {
    const { rows } = await pool.query(text, params);
    return rows[0] ?? null;
}

export async function migrate() {
    const sql = fs.readFileSync(path.join(__dirname, "schema.sql"), "utf8");
    await pool.query(sql);
    console.log("[honey-hub] esquema al dia");
}
