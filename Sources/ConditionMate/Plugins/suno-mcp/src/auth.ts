/**
 * Auth for Suno's studio-api.
 *
 * A real generate request authenticates with THREE things (captured from the
 * browser; no cookie is sent to studio-api):
 *
 *   1. authorization: Bearer <JWT>   — a Clerk access token, ~1h lifetime
 *   2. browser-token: {"token":"<b64>"} where b64 = base64({"timestamp": <ms>})
 *                                     — a plain, unsigned freshness token we can mint
 *   3. device-id: <uuid>             — a stable per-device id
 *
 * Two ways to supply the Bearer:
 *
 *   A. Manual (SUNO_AUTH_TOKEN): paste the Bearer from DevTools. Simplest, but
 *      expires ~hourly — re-paste when calls start returning 401.
 *   B. Clerk auto-refresh (SUNO_COOKIE): mint a fresh Bearer from the
 *      clerk.suno.com cookie before each call. Unattended, survives expiry.
 *
 * Manual token wins if both are set.
 */

const CLERK_BASE_URL = process.env.CLERK_BASE_URL ?? "https://clerk.suno.com";
const CLERK_JS_VERSION = process.env.CLERK_JS_VERSION ?? "5.35.0";

// ---------------------------------------------------------------------------
// browser-token + device-id
// ---------------------------------------------------------------------------

/** Build the per-request browser-token header value. */
export function makeBrowserToken(): string {
  const inner = Buffer.from(JSON.stringify({ timestamp: Date.now() })).toString("base64");
  return JSON.stringify({ token: inner });
}

/** Stable device id captured from the browser. */
export function getDeviceId(): string {
  const id = process.env.SUNO_DEVICE_ID;
  if (!id || !id.trim()) {
    throw new Error("SUNO_DEVICE_ID is not set. Copy the device-id header from DevTools into .env.");
  }
  return id.trim();
}

// ---------------------------------------------------------------------------
// Bearer token
// ---------------------------------------------------------------------------

function clerkUrl(path: string): string {
  const sep = path.includes("?") ? "&" : "?";
  return `${CLERK_BASE_URL}${path}${sep}_clerk_js_version=${encodeURIComponent(CLERK_JS_VERSION)}`;
}

let cachedSid: string | null = null;

interface CachedToken {
  jwt: string;
  refreshAt: number; // epoch ms when we consider it stale
}
let cachedToken: CachedToken | null = null;

async function fetchSessionId(cookie: string): Promise<string> {
  if (cachedSid) return cachedSid;
  const res = await fetch(clerkUrl("/v1/client"), { method: "GET", headers: { Cookie: cookie } });
  if (!res.ok) throw new Error(`Clerk /v1/client failed: ${res.status} ${await res.text()}`);
  const body: any = await res.json();
  const sid: string | undefined =
    body?.response?.last_active_session_id ??
    body?.response?.sessions?.[0]?.id ??
    body?.client?.last_active_session_id;
  if (!sid) throw new Error("Could not find an active Clerk session id; inspect /v1/client and adjust auth.ts.");
  cachedSid = sid;
  return sid;
}

/** Mint a fresh Bearer through Clerk using the stored cookie. */
async function mintFromClerk(): Promise<string> {
  const cookie = process.env.SUNO_COOKIE;
  if (!cookie || !cookie.trim()) {
    throw new Error(
      "No Bearer available: set SUNO_AUTH_TOKEN (manual) or SUNO_COOKIE (auto-refresh) in .env."
    );
  }
  const now = Date.now();
  if (cachedToken && now < cachedToken.refreshAt) return cachedToken.jwt;

  const sid = await fetchSessionId(cookie.trim());
  const res = await fetch(clerkUrl(`/v1/client/sessions/${sid}/tokens`), {
    method: "POST",
    headers: { Cookie: cookie.trim() },
  });
  if (!res.ok) {
    cachedSid = null;
    throw new Error(`Clerk token mint failed: ${res.status} ${await res.text()}`);
  }
  const body: any = await res.json();
  const jwt: string | undefined = body?.jwt;
  if (!jwt) throw new Error("Clerk token response had no jwt; inspect and adjust auth.ts.");
  // Clerk access tokens last ~60m; refresh a bit early.
  cachedToken = { jwt, refreshAt: now + 50 * 60_000 };
  return jwt;
}

/** Return a usable Bearer token (manual env wins, else Clerk auto-refresh). */
export async function getBearerToken(): Promise<string> {
  const manual = process.env.SUNO_AUTH_TOKEN;
  if (manual && manual.trim()) return manual.trim();
  return mintFromClerk();
}

/** Force the next Clerk mint to re-run (e.g. after a 401). No effect in manual mode. */
export function invalidateToken(): void {
  cachedToken = null;
}
