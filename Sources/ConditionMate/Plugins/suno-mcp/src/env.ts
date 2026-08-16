/**
 * Loads .env from the project root before any other module reads process.env.
 * Must be the first import in index.ts. No-op if the file is missing (e.g. when
 * env vars are injected by `claude mcp add --env ...`).
 */
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url)); // dist/ at runtime
try {
  // dist/ -> project root
  process.loadEnvFile(resolve(here, "..", ".env"));
} catch {
  // ignore: rely on real environment variables
}
