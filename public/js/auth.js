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
            submit: "Entrar",
            switchText: "¿Todavía no tenés cuenta?",
            switchBtn: "Creá una",
            autocomplete: "current-password",
            tagline:
                "Todas tus cuentas recolectando, en una sola pantalla. Honey total, ritmo por hora, " +
                "ranking y control remoto — y lo tuyo solo lo ves vos.",
        },
        register: {
            submit: "Crear cuenta",
            switchText: "¿Ya tenés cuenta?",
            switchBtn: "Entrá",
            autocomplete: "new-password",
            tagline:
                "Creá tu cuenta y vas a recibir un token propio. Todas las cuentas de Roblox que peguen " +
                "ese token reportan a TU panel — nunca al de otro.",
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
        password.placeholder = mode === "register" ? "mínimo 8 caracteres" : "••••••••";
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
                show(errorBox, body.message || "No se pudo completar. Probá de nuevo.");
                return;
            }

            // Al registrarse se entra directo al panel: el token se muestra ahi,
            // en el modal de conectar cuentas, con el snippet listo para copiar.
            location.href = mode === "register" ? "/panel?welcome=1" : "/panel";
        } catch {
            show(errorBox, "Sin conexión con el servidor.");
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
