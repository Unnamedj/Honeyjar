(() => {
    "use strict";

    const form = document.getElementById("form");
    const errorBox = document.getElementById("error");
    const successBox = document.getElementById("success");
    const submit = document.getElementById("submit");
    const switchBtn = document.getElementById("switch");
    const switchText = document.getElementById("switch-text");
    const password = document.getElementById("password");
    const tagline = document.getElementById("tagline");

    let mode = "login";

    const COPY = {
        login: {
            submit: "Sign in",
            switchText: "No account yet?",
            switchBtn: "Create one",
            autocomplete: "current-password",
            tagline:
                "Every account of yours collecting, on one screen. Total honey, hourly rate, " +
                "ranking and remote control — and only you see yours.",
        },
        register: {
            submit: "Create account",
            switchText: "Already have an account?",
            switchBtn: "Sign in",
            autocomplete: "new-password",
            tagline:
                "Create your account and wait for the admin to approve you. Then your own token " +
                "shows up: every Roblox account that pastes it reports to YOUR panel — never anyone else's.",
        },
    };

    function show(box, message) {
        box.textContent = message;
        box.hidden = !message;
    }

    function setMode(next) {
        mode = next;
        const copy = COPY[mode];
        submit.textContent = copy.submit;
        switchText.textContent = copy.switchText;
        switchBtn.textContent = copy.switchBtn;
        password.autocomplete = copy.autocomplete;
        password.placeholder = mode === "register" ? "at least 8 characters" : "••••••••";
        tagline.textContent = copy.tagline;
        show(errorBox, "");
        show(successBox, "");
    }

    switchBtn.addEventListener("click", () => setMode(mode === "login" ? "register" : "login"));

    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        show(errorBox, "");
        submit.disabled = true;
        submit.textContent = "…";

        try {
            const res = await fetch(`/api/auth/${mode}`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    username: document.getElementById("username").value.trim(),
                    password: password.value,
                }),
            });
            const body = await res.json().catch(() => ({}));

            if (!res.ok) {
                show(errorBox, body.message || "Could not complete. Try again.");
                return;
            }

            // Al registrarse se entra directo al panel: el token se muestra ahi,
            // en el modal de conectar cuentas, con el snippet listo para copiar.
            location.href = mode === "register" ? "/panel?welcome=1" : "/panel";
        } catch {
            show(errorBox, "No connection to the server.");
        } finally {
            submit.disabled = false;
            submit.textContent = COPY[mode].submit;
        }
    });

    // Si la cookie sigue viva, no tiene sentido mostrar el login.
    fetch("/api/auth/me")
        .then((res) => { if (res.ok) location.replace("/panel"); })
        .catch(() => {});

    setMode("login");
})();
