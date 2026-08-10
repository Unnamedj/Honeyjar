import crypto from "node:crypto";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { one } from "../db.js";

const SECRET = process.env.SESSION_SECRET;
if (!SECRET || SECRET.length < 16) {
    console.error(
        "[honey-hub] falta SESSION_SECRET (o es muy corto).\n" +
        '  Generalo con: node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'hex\'))"'
    );
    process.exit(1);
}

const COOKIE = "hh_session";
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000; // 30 dias

export function hashPassword(plain) {
    return bcrypt.hash(plain, 12);
}

export function checkPassword(plain, hash) {
    return bcrypt.compare(plain, hash);
}

/** Token que se pega en el script. El prefijo hace obvio que es del hub si se filtra en un log. */
export function newApiToken() {
    return "hh_" + crypto.randomBytes(24).toString("hex");
}

export function issueSession(res, user) {
    const token = jwt.sign({ uid: user.id }, SECRET, { expiresIn: "30d" });
    res.cookie(COOKIE, token, {
        httpOnly: true,
        sameSite: "lax",
        secure: process.env.NODE_ENV === "production",
        maxAge: MAX_AGE_MS,
        path: "/",
    });
}

export function clearSession(res) {
    res.clearCookie(COOKIE, { path: "/" });
}

/**
 * Exige sesion. Toda ruta del dashboard pasa por aca y deja req.user cargado,
 * asi ninguna consulta de abajo tiene que acordarse de filtrar por usuario a
 * mano: el user_id sale siempre de la cookie firmada, nunca del body.
 */
export async function requireUser(req, res, next) {
    const raw = req.cookies?.[COOKIE];
    if (!raw) return res.status(401).json({ error: "no_session" });

    let payload;
    try {
        payload = jwt.verify(raw, SECRET);
    } catch {
        clearSession(res);
        return res.status(401).json({ error: "no_session" });
    }

    const user = await one(
        "SELECT id, username, api_token, created_at FROM users WHERE id = $1",
        [payload.uid]
    );
    if (!user) {
        clearSession(res);
        return res.status(401).json({ error: "no_session" });
    }

    req.user = user;
    next();
}
