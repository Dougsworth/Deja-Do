import { createApp, parseCodes } from "./app";
import { Usage } from "./usage";

const env = process.env;
const codes = parseCodes(env.ACCESS_CODES);
const keys = {
  anthropic: env.ANTHROPIC_API_KEY || undefined,
  openai: env.OPENAI_API_KEY || undefined,
  gemini: env.GEMINI_API_KEY || undefined,
};

if (codes.size === 0) console.warn("No ACCESS_CODES set (person=code, codes at least 12 characters), so nobody can use this server yet.");
if (!keys.anthropic && !keys.openai && !keys.gemini) console.warn("No API keys set: add ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY.");

const handle = createApp({
  keys,
  codes,
  dailyLimit: Number(env.DAILY_LIMIT) || 200,
  allowedModels: new Set((env.ALLOWED_MODELS ?? "").split(",").map((s) => s.trim()).filter(Boolean)),
  adminCode: env.ADMIN_CODE || undefined,
  usage: new Usage(`${env.DATA_DIR || "/data"}/usage.sqlite`),
});

const server = Bun.serve({ port: Number(env.PORT) || 3000, fetch: handle });
console.log(`Deja Do server listening on ${server.port} for ${codes.size} ${codes.size === 1 ? "person" : "people"}`);
