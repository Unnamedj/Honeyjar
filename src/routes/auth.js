import { Router } from "express";
import { one, query } from "../db.js";
import {
    checkPassword,
    clearSession,
    hashPassword,
    issueSession,
    newApiToken,
    requireUser,
} from "../lib/auth.js";
import { onlyFailures, rateLimit } from "../lib/limit.js";

export const authRouter = Router();

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,24}$/;
const MIN_PASSWORD = 8;
const MAX_PASSWORD = 200;   // bcrypt igual corta en 72 bytes; esto es contra el CPU

// Hash de una contrasena que no es de nadie, para gastar el mismo tiempo
// comparando cuando el usuario no existe (ver el login).
const DUMMY_HASH = "$2a$12$oJqECnqCb23k4vRtNUL3EeQvOsqXlWXGdBUOIKCXlGotxeAn0nCzW";

/**
 * Cuantas cuentas puede haber en total. 0 o sin setear = sin tope. Es el freno
 * duro: el limite por IP frena al que insiste desde un lado, esto frena a un
 * botnet igual.
 */
function maxUsers() {
    const n = Math.floor(Number(process.env.MAX_USERS));
    return Number.isFinite(n) && n > 0 ? n : 0;
}

// Crear cuentas es caro (bcrypt de 12 rondas) y no hay ninguna razon legitima
// para abrir tres en una hora desde la misma IP.
const registerLimit = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 3,
    error: "demasiadas_cuentas",
    message: "Too many new accounts from here. Try again in a while.",
});

// El login cuenta SOLO los fallidos: al que acierta no se le gasta cupo, asi
// que esto molesta al que prueba contrasenas y no al que entra y sale.
const loginLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 10,
    error: "demasiados_intentos",
    message: "Too many failed attempts. Wait a few minutes.",
    countIf: onlyFailures,
});

authRouter.post("/register", registerLimit, async (req, res) => {
    if (process.env.ALLOW_SIGNUP === "0") {
        return res.status(403).json({ error: "signup_cerrado" });
    }

    const cap = maxUsers();
    if (cap) {
        const { count } = await one("SELECT count(*)::int AS count FROM users");
        if (count >= cap) {
            return res.status(403).json({
                error: "cupo_lleno",
                message: "The hub is not taking new accounts.",
            });
        }
    }

    const username = String(req.body?.username ?? "").trim();
    const password = String(req.body?.password ?? "");

    if (!USERNAME_RE.test(username)) {
        return res.status(400).json({
            error: "usuario_invalido",
            message: "3 to 24 characters: letters, numbers, dot, dash or underscore.",
        });
    }
    if (password.length < MIN_PASSWORD || password.length > MAX_PASSWORD) {
        return res.status(400).json({
            error: "password_invalida",
            message: `Between ${MIN_PASSWORD} and ${MAX_PASSWORD} characters.`,
        });
    }

    const exists = await one("SELECT 1 FROM users WHERE username_ci = $1", [
        username.toLowerCase(),
    ]);
    if (exists) {
        return res.status(409).json({
            error: "usuario_tomado",
            message: "That username is taken.",
        });
    }

    // El primer usuario del panel es el admin, y se aprueba solo: si tuviera
    // que habilitarlo alguien, no habria nadie para hacerlo. Del segundo en
    // adelante entran bloqueados y esperan a que el admin les de acceso.
    const user = await one(
        `INSERT INTO users (username, username_ci, password_hash, api_token, approved)
         VALUES ($1, $2, $3, $4, NOT EXISTS (SELECT 1 FROM users))
         RETURNING id, username, api_token, approved`,
        [username, username.toLowerCase(), await hashPassword(password), newApiToken()]
    );

    issueSession(res, user);
    res.json({
        ok: true,
        user: {
            username: user.username,
            apiToken: user.approved ? user.api_token : null,
            approved: user.approved,
        },
    });
});

authRouter.post("/login", loginLimit, async (req, res) => {
    const username = String(req.body?.username ?? "").trim().slice(0, 64);
    const password = String(req.body?.password ?? "").slice(0, MAX_PASSWORD);

    const user = await one(
        `SELECT id, username, password_hash, api_token,
                (approved OR id = (SELECT min(id) FROM users)) AS approved
           FROM users WHERE username_ci = $1`,
        [username.toLowerCase()]
    );

    // Mismo mensaje para "no existe" y "clave mal": decir cual de los dos fue
    // regala una forma de averiguar que usuarios existen. Cuando el usuario no
    // existe igual se corre un bcrypt contra un hash de descarte, porque si no
    // la respuesta vuelve al instante y el reloj delata cuales existen.
    const ok = user
        ? await checkPassword(password, user.password_hash)
        : await checkPassword(password, DUMMY_HASH).then(() => false);
    if (!ok) {
        return res.status(401).json({
            error: "credenciales",
            message: "Wrong username or password.",
        });
    }

    issueSession(res, user);
    res.json({
        ok: true,
        user: {
            username: user.username,
            apiToken: user.approved ? user.api_token : null,
            approved: user.approved,
        },
    });
});

authRouter.post("/logout", (req, res) => {
    clearSession(res);
    res.json({ ok: true });
});

authRouter.get("/me", requireUser, (req, res) => {
    const approved = req.user.approved || req.user.is_admin;
    res.json({
        ok: true,
        user: {
            username: req.user.username,
            // Sin aprobacion el token ni siquiera viaja: el panel no puede
            // mostrar un loader que no tiene. La puerta de verdad igual esta en
            // /api/bot/* (aca abajo), no en esconder el string.
            apiToken: approved ? req.user.api_token : null,
            createdAt: req.user.created_at,
            approved,
            admin: Boolean(req.user.is_admin),
        },
    });
});

/** Rotar el token invalida al instante todos los bots que usaban el viejo. */
authRouter.post("/token/rotate", requireUser, async (req, res) => {
    if (!req.user.approved && !req.user.is_admin) {
        return res.status(403).json({ error: "cuenta_no_aprobada" });
    }
    const token = newApiToken();
    await query("UPDATE users SET api_token = $1 WHERE id = $2", [token, req.user.id]);
    res.json({ ok: true, apiToken: token });
});
