/**
 * Thin client over Suno's internal studio-api (studio-api-prod.suno.com).
 *
 * Request shape verified from a real /api/generate/v2-web/ capture. Auth =
 * Bearer + browser-token + device-id (see auth.ts). Endpoints other than
 * generate (feed/credits) still need verification against your own capture.
 */

import { randomUUID } from "node:crypto";
import { getBearerToken, invalidateToken, makeBrowserToken, getDeviceId } from "./auth.js";

const SUNO_BASE_URL = process.env.SUNO_BASE_URL ?? "https://studio-api-prod.suno.com";
const SUNO_MODEL = process.env.SUNO_MODEL ?? "chirp-fenix";
const SUNO_USER_TIER = process.env.SUNO_USER_TIER; // optional; sent in metadata if present
const USER_AGENT =
  process.env.SUNO_USER_AGENT ??
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";

/** A single generated clip (subset of fields the feed returns). */
export interface Clip {
  id: string;
  title?: string;
  status?: string; // "submitted" | "queued" | "streaming" | "complete" | "error"
  audio_url?: string;
  video_url?: string;
  image_url?: string;
  metadata?: Record<string, unknown>;
}

async function authHeaders(): Promise<Record<string, string>> {
  const token = await getBearerToken();
  return {
    authorization: `Bearer ${token}`,
    "browser-token": makeBrowserToken(),
    "device-id": getDeviceId(),
    "content-type": "application/json",
    accept: "*/*",
    origin: "https://suno.com",
    referer: "https://suno.com/",
    "user-agent": USER_AGENT,
  };
}

async function apiFetch(path: string, init: RequestInit = {}, retry = true): Promise<any> {
  const res = await fetch(`${SUNO_BASE_URL}${path}`, {
    ...init,
    headers: { ...(await authHeaders()), ...(init.headers ?? {}) },
  });

  if (res.status === 401 && retry) {
    invalidateToken();
    return apiFetch(path, init, false);
  }
  if (!res.ok) {
    throw new Error(`Suno ${init.method ?? "GET"} ${path} failed: ${res.status} ${await res.text()}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

export interface GenerateInput {
  /** Description mode: a natural-language prompt; Suno writes lyrics + style. */
  description?: string;
  /** Custom mode: your own lyrics. */
  lyrics?: string;
  /** Custom mode: comma-separated style tags, e.g. "lo-fi, chill, piano". */
  style?: string;
  /** Custom mode: song title. */
  title?: string;
  /** Instrumental (no vocals). */
  instrumental?: boolean;
  /** Override default model tag (mv), e.g. chirp-fenix. */
  model?: string;
}

/**
 * Kick off a generation. Returns the pending clips; poll getFeed() until they
 * reach "complete". Payload mirrors the real v2-web request; custom-mode field
 * names (prompt/tags/title) are best-effort and may need a capture to confirm.
 */
export async function generate(input: GenerateInput): Promise<Clip[]> {
  const isCustom = Boolean(input.lyrics || input.style || input.title);

  const metadata: Record<string, unknown> = {
    web_client_pathname: "/create",
    is_max_mode: false,
    is_mumble: false,
    create_mode: "simple",
    disable_volume_normalization: false,
    lyrics_model: "default",
    create_session_token: randomUUID(),
  };
  if (SUNO_USER_TIER) metadata.user_tier = SUNO_USER_TIER;

  const payload: Record<string, unknown> = {
    token: null,
    generation_type: "TEXT",
    mv: input.model ?? SUNO_MODEL,
    make_instrumental: input.instrumental ?? false,
    user_uploaded_images_b64: null,
    metadata,
    override_fields: [],
    cover_clip_id: null,
    cover_start_s: null,
    cover_end_s: null,
    persona_id: null,
    artist_clip_id: null,
    artist_start_s: null,
    artist_end_s: null,
    continue_clip_id: null,
    continued_aligned_prompt: null,
    continue_at: null,
    transaction_uuid: randomUUID(),
    token_provider: null,
  };

  if (isCustom) {
    payload.prompt = input.lyrics ?? "";
    payload.tags = input.style ?? "";
    payload.title = input.title ?? "";
    payload.gpt_description_prompt = "";
  } else {
    payload.prompt = "";
    payload.gpt_description_prompt = input.description ?? "";
  }

  const body = await apiFetch("/api/generate/v2-web/", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  return (body?.clips ?? []) as Clip[];
}

/**
 * Fetch the latest state of one or more clips by id.
 * NOTE: feed path not yet verified — capture a real poll request and adjust if needed.
 */
export async function getFeed(ids: string[]): Promise<Clip[]> {
  const query = ids.length ? `?ids=${encodeURIComponent(ids.join(","))}` : "";
  const body = await apiFetch(`/api/feed/v2${query}`, { method: "GET" });
  if (Array.isArray(body)) return body as Clip[];
  return (body?.clips ?? []) as Clip[];
}

/** Remaining credits / billing info. NOTE: path not yet verified. */
export async function getCredits(): Promise<any> {
  return apiFetch("/api/billing/info/", { method: "GET" });
}
