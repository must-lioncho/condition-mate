/**
 * Clerk session-token manager.
 *
 * Suno authenticates through Clerk. The session JWT it hands to studio-api is
 * short-lived (~60s), so we cannot store one and reuse it. Instead we hold the
 * long-lived browser *cookie* and mint a fresh JWT from Clerk right before each
 * call to studio-api.
 *
 * Flow (verify the exact paths against your own Network capture):
 *   1. GET  {CLERK_BASE_URL}/v1/client            -> find the active session id (sid)
 *   2. POST {CLERK_BASE_URL}/v1/client/sessions/{sid}/tokens -> { jwt }
 *   3. use jwt as `Authorization: Bearer {jwt}` against studio-api.
 */

const CLERK_BASE_URL = process.env.CLERK_BASE_URL ?? "https://clerk.suno.com";
const CLERK_JS_VERSION = process.env.CLERK_JS_VERSION ?? "5.35.0";

function requireCookie(): string {
  const cookie = process.env.SUNO_COOKIE;
  if (!cookie || cookie.trim().length === 0) {
    throw new Error(
      "SUNO_COOKIE is not set. Copy your logged-in Suno cookie into .env (see .env.example)."
    );
  }
  return cookie;
}

function clerkUrl(path: string): string {
  const sep = path.includes("?") ? "&" : "?";
  return `${CLERK_BASE_URL}${path}${sep}_clerk_js_version=${encodeURIComponent(CLERK_JS_VERSION)}`;
}

let cachedSid: string | null = null;

/** Resolve the active Clerk session id from the client object. */
async function fetchSessionId(cookie: string): Promise<string> {
  if (cachedSid) return cachedSid;

  const res = await fetch(clerkUrl("/v1/client"), {
    method: "GET",
    headers: { Cookie: cookie },
  });
  if (!res.ok) {
    throw new Error(`Clerk /v1/client failed: ${res.status} ${await res.text()}`);
  }
  const body: any = await res.json();
  // Clerk returns the active session under response.last_active_session_id,
  // with the sessions array in response.sessions. Field names can drift —
  // adjust here if your capture differs.
  const sid: string | undefined =
    body?.response?.last_active_session_id ??
    body?.response?.sessions?.[0]?.id ??
    body?.client?.last_active_session_id;
  if (!sid) {
    throw new Error(
      "Could not find an active Clerk session id. Inspect the /v1/client response shape and adjust auth.ts."
    );
  }
  cachedSid = sid;
  return sid;
}

interface CachedToken {
  jwt: string;
  /** epoch ms when we consider this token stale and refresh it */
  refreshAt: number;
}

let cachedToken: CachedToken | null = null;

/**
 * Return a valid short-lived Suno bearer token, refreshing through Clerk when
 * the cached one is near expiry. Treats the JWT as good for ~50s to leave a
 * safety margin under Clerk's ~60s lifetime.
 */
export async function getBearerToken(): Promise<string> {
  const now = Date.now();
  if (cachedToken && now < cachedToken.refreshAt) {
    return cachedToken.jwt;
  }

  const cookie = requireCookie();
  const sid = await fetchSessionId(cookie);

  const res = await fetch(clerkUrl(`/v1/client/sessions/${sid}/tokens`), {
    method: "POST",
    headers: { Cookie: cookie },
  });
  if (!res.ok) {
    // A 401/404 here usually means the cookie expired or the session id changed.
    cachedSid = null;
    throw new Error(`Clerk token mint failed: ${res.status} ${await res.text()}`);
  }
  const body: any = await res.json();
  const jwt: string | undefined = body?.jwt;
  if (!jwt) {
    throw new Error("Clerk token response did not contain a jwt. Inspect the response and adjust auth.ts.");
  }

  cachedToken = { jwt, refreshAt: now + 50_000 };
  return jwt;
}

/** Force the next call to re-mint a token (e.g. after a 401 from studio-api). */
export function invalidateToken(): void {
  cachedToken = null;
}
