/**
 * Miniaturas de avatar.
 *
 * El endpoint de Roblox no devuelve la imagen: devuelve una URL de CDN que
 * caduca. Por eso se resuelve en el server (el navegador no tiene por que
 * hablarle a Roblox) y se guarda en accounts.avatar_url con su timestamp; se
 * refresca cada 6h, y si Roblox no contesta se sigue usando la URL vieja en vez
 * de dejar la tarjeta sin foto.
 */

const THUMB_URL = "https://thumbnails.roblox.com/v1/users/avatar-headshot";
const TTL_MS = 6 * 60 * 60 * 1000;

export function avatarIsFresh(avatarUrl, avatarAt) {
    if (!avatarUrl || !avatarAt) return false;
    return Date.now() - new Date(avatarAt).getTime() < TTL_MS;
}

export async function fetchAvatar(robloxUserId) {
    const url =
        `${THUMB_URL}?userIds=${encodeURIComponent(robloxUserId)}` +
        "&size=150x150&format=Png&isCircular=false";

    try {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 6000);
        const res = await fetch(url, { signal: controller.signal });
        clearTimeout(timer);
        if (!res.ok) return null;

        const body = await res.json();
        const entry = body?.data?.[0];
        // "Completed" es el unico estado con imagen lista; "Pending" y "Blocked"
        // traen imageUrl vacio o un placeholder.
        if (entry?.state !== "Completed" || !entry.imageUrl) return null;
        return entry.imageUrl;
    } catch {
        return null;
    }
}
