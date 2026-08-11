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

export const authRouter = Router();

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,24}$/;
const MIN_PASSWORD = 8;

authRouter.post("/register", async (req, res) => {
    if (process.env.ALLOW_SIGNUP === "0") {
        return res.status(403).json({ error: "signup_cerrado" });
    }

    const username = String(req.body?.username ?? "").trim();
    const password = String(req.body?.password ?? "");

    if (!USERNAME_RE.test(username)) {
        return res.status(400).json({
            error: "usuario_invalido",
            message: "3 a 24 caracteres: letras, numeros, punto, guion o guion bajo.",
        });
    }
    if (password.length < MIN_PASSWORD) {
        return res.status(400).json({
            error: "password_corta",
            message: `Minimo ${MIN_PASSWORD} caracteres.`,
        });
    }

    const exists = await one("SELECT 1 FROM users WHERE username_ci = $1", [
        username.toLowerCase(),
    ]);
    if (exists) {
        return res.status(409).json({
            error: "usuario_tomado",
            message: "Ese usuario ya existe.",
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

authRouter.post("/login", async (req, res) => {
    const username = String(req.body?.username ?? "").trim();
    const password = String(req.body?.password ?? "");

    const user = await one(
        `SELECT id, username, password_hash, api_token,
                (approved OR id = (SELECT min(id) FROM users)) AS approved
           FROM users WHERE username_ci = $1`,
        [username.toLowerCase()]
    );

    // Mismo mensaje para "no existe" y "clave mal": decir cual de los dos fue
    // regala una forma de averiguar que usuarios existen.
    const ok = user && (await checkPassword(password, user.password_hash));
    if (!ok) {
        return res.status(401).json({
            error: "credenciales",
            message: "Usuario o contrasena incorrectos.",
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
