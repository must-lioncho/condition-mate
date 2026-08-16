#!/usr/bin/env node
/**
 * suno-mcp — a personal MCP server for automating Suno music generation.
 *
 * Exposes five tools over stdio:
 *   generate_song, get_status, get_audio, list_library, get_credits
 *
 * Auth is cookie-based (see auth.ts / .env.example). This is for personal use
 * with your own account.
 */

import "./env.js"; // must run before modules that read process.env
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import { generate, getFeed, getCredits, type Clip } from "./suno.js";

const DOWNLOAD_DIR = process.env.DOWNLOAD_DIR ?? "./downloads";

const server = new McpServer({
  name: "suno-mcp",
  version: "0.1.0",
});

/** Compact a clip down to the fields worth showing the model/user. */
function summarize(c: Clip) {
  return {
    id: c.id,
    title: c.title ?? null,
    status: c.status ?? "unknown",
    audio_url: c.audio_url ?? null,
    video_url: c.video_url ?? null,
  };
}

function asJson(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

server.registerTool(
  "generate_song",
  {
    title: "Generate a song",
    description:
      "Start a Suno generation. Use `description` for description-mode (Suno writes lyrics + style), " +
      "or `lyrics`/`style`/`title` for custom mode. Returns pending clip ids; poll with get_status.",
    inputSchema: {
      description: z.string().optional().describe("Natural-language prompt (description mode)"),
      lyrics: z.string().optional().describe("Your own lyrics (custom mode)"),
      style: z.string().optional().describe("Comma-separated style tags, e.g. 'lo-fi, chill, piano'"),
      title: z.string().optional().describe("Song title (custom mode)"),
      instrumental: z.boolean().optional().describe("No vocals"),
      model: z.string().optional().describe("Override model tag (mv), e.g. chirp-v4"),
    },
  },
  async (args) => {
    const clips = await generate(args);
    return asJson({ count: clips.length, clips: clips.map(summarize) });
  }
);

server.registerTool(
  "get_status",
  {
    title: "Get clip status",
    description: "Fetch the current status of one or more clip ids. Status reaches 'complete' when ready.",
    inputSchema: {
      ids: z.array(z.string()).min(1).describe("Clip ids returned by generate_song"),
    },
  },
  async ({ ids }) => {
    const clips = await getFeed(ids);
    return asJson({ clips: clips.map(summarize) });
  }
);

server.registerTool(
  "get_audio",
  {
    title: "Download finished audio",
    description:
      "Resolve a clip's audio URL and download the mp3 to DOWNLOAD_DIR. Fails if the clip is not yet complete.",
    inputSchema: {
      id: z.string().describe("Clip id"),
      filename: z.string().optional().describe("Output filename (defaults to <id>.mp3)"),
    },
  },
  async ({ id, filename }) => {
    const [clip] = await getFeed([id]);
    if (!clip) throw new Error(`Clip ${id} not found.`);
    if (clip.status !== "complete" || !clip.audio_url) {
      return asJson({ id, status: clip.status ?? "unknown", message: "Not ready yet — poll get_status." });
    }

    const res = await fetch(clip.audio_url);
    if (!res.ok) throw new Error(`Audio download failed: ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());

    await mkdir(DOWNLOAD_DIR, { recursive: true });
    const out = resolve(DOWNLOAD_DIR, filename ?? `${id}.mp3`);
    await writeFile(out, buf);

    return asJson({ id, title: clip.title ?? null, path: out, bytes: buf.length });
  }
);

server.registerTool(
  "list_library",
  {
    title: "List my library",
    description: "List your most recent clips (no ids = recent feed).",
    inputSchema: {},
  },
  async () => {
    const clips = await getFeed([]);
    return asJson({ count: clips.length, clips: clips.map(summarize) });
  }
);

server.registerTool(
  "get_credits",
  {
    title: "Get remaining credits",
    description: "Return account billing / credit info.",
    inputSchema: {},
  },
  async () => {
    return asJson(await getCredits());
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stderr is safe for logging; stdout is the MCP channel.
  console.error("suno-mcp running on stdio");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
