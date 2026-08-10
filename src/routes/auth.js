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

    const user = await one(
        `INSERT INTO users (username, username_ci, password_hash, api_token)
         VALUES ($1, $2, $3, $4)
         RETURNING id, username, api_token`,
        [username, username.toLowerCase(), await hashPassword(password), newApiToken()]
    );

    issueSession(res, user);
    res.json({ ok: true, user: { username: user.username, apiToken: user.api_token } });
});

authRouter.post("/login", async (req, res) => {
    const username = String(req.body?.username ?? "").trim();
    const password = String(req.body?.password ?? "");

    const user = await one(
        "SELECT id, username, password_hash, api_token FROM users WHERE username_ci = $1",
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
    res.json({ ok: true, user: { username: user.username, apiToken: user.api_token } });
});

authRouter.post("/logout", (req, res) => {
    clearSession(res);
    res.json({ ok: true });
});

authRouter.get("/me", requireUser, (req, res) => {
    res.json({
        ok: true,
        user: {
            username: req.user.username,
            apiToken: req.user.api_token,
            createdAt: req.user.created_at,
        },
    });
});

/** Rotar el token invalida al instante todos los bots que usaban el viejo. */
authRouter.post("/token/rotate", requireUser, async (req, res) => {
    const token = newApiToken();
    await query("UPDATE users SET api_token = $1 WHERE id = $2", [token, req.user.id]);
    res.json({ ok: true, apiToken: token });
});
