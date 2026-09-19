// Internal-only telemetry. No prompts, response bodies or credentials enter this store.
import { AsyncLocalStorage } from 'node:async_hooks';
const scope = new AsyncLocalStorage();
const count = v => Number.isFinite(v) && v >= 0 ? v : null;
export const replyUsageID = () => scope.getStore()?.id || '';
export async function captureReplyUsage(id, task) {
  const store = { id, calls: [], open: true };
  try {
    const value = await scope.run(store, task);
    return { value, usage: { version: 1, scope: 'reply-generation', calls: structuredClone(store.calls) } };
  } finally { store.open = false; }
}
export function recordReplyUsage(call) {
  const store = scope.getStore();
  if (store?.open) store.calls.push({ ...call, at: Math.floor(Date.now() / 1000) });
}
export function geminiReplyUsage(json, requestedModel, limits = {}) {
  const u = json.usageMetadata || {};
  return { provider: 'gemini', transport: 'api', requestedModel,
    model: json.modelVersion || requestedModel, modelResolved: !!json.modelVersion,
    effort: { state: 'not-set', value: null },
    context: { inputLimit: count(limits.inputTokenLimit), outputLimit: count(limits.outputTokenLimit),
      usedInput: count(u.promptTokenCount), source: limits.inputTokenLimit ? 'models-api' : null },
    tokens: { input: count(u.promptTokenCount), output: count(u.candidatesTokenCount),
      reasoning: count(u.thoughtsTokenCount), cached: count(u.cachedContentTokenCount), total: count(u.totalTokenCount) } };
}
export function anthropicReplyUsage(json, requestedModel, limits = {}) {
  const u = json.usage || {}, input = count(u.input_tokens), output = count(u.output_tokens);
  const cached = count(u.cache_read_input_tokens), created = count(u.cache_creation_input_tokens);
  const used = input === null ? null : input + (cached || 0) + (created || 0);
  return { provider: 'anthropic', transport: 'api', requestedModel, model: json.model || requestedModel,
    modelResolved: !!json.model, effort: { state: 'not-set', value: null },
    context: { inputLimit: count(limits.max_input_tokens), outputLimit: count(limits.max_tokens), usedInput: used,
      source: limits.max_input_tokens ? 'models-api' : null },
    tokens: { input: used, output, reasoning: null, cached, cacheCreated: created,
      total: used === null || output === null ? null : used + output } };
}
export function cliReplyUsage(envelope, requestedModel, effort) {
  const models = Object.entries(envelope.modelUsage || {});
  if (!models.length) models.push([requestedModel, null]);
  return models.map(([model, m]) => {
    const u = m || envelope.usage || {};
    const input = count(m ? u.inputTokens : u.input_tokens), output = count(m ? u.outputTokens : u.output_tokens);
    const cached = count(m ? u.cacheReadInputTokens : u.cache_read_input_tokens);
    const created = count(m ? u.cacheCreationInputTokens : u.cache_creation_input_tokens);
    const used = input === null ? null : input + (cached || 0) + (created || 0);
    return { provider: 'anthropic', transport: 'cli', requestedModel, model, modelResolved: !!m,
      effort: { state: effort ? 'environment' : 'unknown', value: effort || null },
      context: { inputLimit: null, window: count(m?.contextWindow), usedInput: null,
        source: m?.contextWindow ? 'cli-modelUsage' : null },
      tokens: { input: used, output, reasoning: null, cached, cacheCreated: created,
        total: used === null || output === null ? null : used + output } };
  });
}
const limitCache = new Map();
export async function replyModelLimits(provider, model, key, request = fetch) {
  if (!replyUsageID() || !key) return {};
  const cacheKey = provider + ':' + model;
  const old = limitCache.get(cacheKey);
  if (old && old.until > Date.now()) return old.value;
  const value = (async () => {
    try {
      const gemini = provider === 'gemini';
      const url = gemini ? `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}`
        : `https://api.anthropic.com/v1/models/${encodeURIComponent(model)}`;
      const headers = gemini ? { 'x-goog-api-key': key } : { 'x-api-key': key, 'anthropic-version': '2023-06-01' };
      const response = await request(url, { headers, signal: AbortSignal.timeout(1500) });
      if (!response.ok) return {};
      const data = await response.json();
      return gemini ? { inputTokenLimit: count(data.inputTokenLimit), outputTokenLimit: count(data.outputTokenLimit) }
        : { max_input_tokens: count(data.max_input_tokens), max_tokens: count(data.max_tokens) };
    } catch { return {}; }
  })();
  limitCache.set(cacheKey, { value, until: Date.now() + 60 * 60 * 1000 });
  return value;
}
