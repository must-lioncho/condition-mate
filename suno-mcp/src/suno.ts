/**
 * Thin client over Suno's internal studio-api.
 *
 * Every method mints a fresh Clerk bearer via auth.ts and retries once on 401.
 * Endpoint paths/payloads are based on the well-known community reverse-engineering
 * (e.g. gcui-art/suno-api) and MUST be verified against your own Network capture —
 * Suno changes them without notice.
 */

import { getBearerToken, invalidateToken } from "./auth.js";

const SUNO_BASE_URL = process.env.SUNO_BASE_URL ?? "https://studio-api-prod.suno.com";
const SUNO_MODEL = process.env.SUNO_MODEL ?? "chirp-v3-5";

/** A single generated clip as returned by the feed endpoint (subset of fields). */
export interface Clip {
  id: string;
  title?: string;
  status?: string; // "submitted" | "queued" | "streaming" | "complete" | "error"
  audio_url?: string;
  video_url?: string;
  image_url?: string;
  metadata?: Record<string, unknown>;
}

async function apiFetch(path: string, init: RequestInit = {}, retry = true): Promise<any> {
  const token = await getBearerToken();
  const res = await fetch(`${SUNO_BASE_URL}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      ...(init.headers ?? {}),
    },
  });

  if (res.status === 401 && retry) {
    invalidateToken();
    return apiFetch(path, init, false);
  }
  if (!res.ok) {
    throw new Error(`Suno ${init.method ?? "GET"} ${path} failed: ${res.status} ${await res.text()}`);
  }
  // Some endpoints return empty bodies.
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
  /** Override default model tag (mv). */
  model?: string;
}

/**
 * Kick off a generation. Suno returns immediately with the (usually two) clips
 * in a pending state; poll getFeed() until they reach "complete".
 */
export async function generate(input: GenerateInput): Promise<Clip[]> {
  const isCustom = Boolean(input.lyrics || input.style || input.title);
  const payload: Record<string, unknown> = {
    mv: input.model ?? SUNO_MODEL,
    make_instrumental: input.instrumental ?? false,
  };

  if (isCustom) {
    payload.prompt = input.lyrics ?? "";
    payload.tags = input.style ?? "";
    payload.title = input.title ?? "";
  } else {
    payload.gpt_description_prompt = input.description ?? "";
    payload.prompt = "";
  }

  const body = await apiFetch("/api/generate/v2-web/", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  return (body?.clips ?? []) as Clip[];
}

/** Fetch the latest state of one or more clips by id. */
export async function getFeed(ids: string[]): Promise<Clip[]> {
  const query = ids.length ? `?ids=${encodeURIComponent(ids.join(","))}` : "";
  const body = await apiFetch(`/api/feed/${query}`, { method: "GET" });
  // The feed endpoint may return a bare array or { clips: [...] } depending on version.
  if (Array.isArray(body)) return body as Clip[];
  return (body?.clips ?? []) as Clip[];
}

/** Remaining credits / billing info. */
export async function getCredits(): Promise<any> {
  return apiFetch("/api/billing/info/", { method: "GET" });
}
