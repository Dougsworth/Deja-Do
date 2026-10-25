import { createHash, timingSafeEqual } from "node:crypto";
import { buildCall, errorMessage, readText, vendorName, vendorOf, type Keys } from "./providers";
import { Usage } from "./usage";

export interface Config {
  keys: Keys;
  /** Access code to person, e.g. from ACCESS_CODES="douglas=abc123,jason=def456". */
  codes: Map<string, string>;
  dailyLimit: number;
  /** Only these models may be used. Empty means any model whose company has a key here. */
  allowedModels: Set<string>;
  /** Lets the owner read the usage report. */
  adminCode?: string;
  usage: Usage;
  fetch?: typeof fetch;
  log?: (line: string) => void;
}

export function parseCodes(raw: string | undefined): Map<string, string> {
  const codes = new Map<string, string>();
  for (const pair of (raw ?? "").split(",")) {
    const [person, code] = pair.split("=").map((s) => s?.trim());
    if (person && code && code.length >= 12) codes.set(code, person);
  }
  return codes;
}

function digest(s: string): Buffer {
  return createHash("sha256").update(s).digest();
}

/** Finds whose code this is without leaking timing about how close a guess was. */
export function personFor(code: string, codes: Map<string, string>): string | null {
  const given = digest(code);
  let found: string | null = null;
  for (const [known, person] of codes) {
    if (timingSafeEqual(given, digest(known))) found = person;
  }
  return found;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const bearer = (req: Request) => (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();

export function createApp(cfg: Config) {
  const send = cfg.fetch ?? fetch;
  const log = cfg.log ?? ((line: string) => console.log(line));

  return async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);

    if (req.method === "GET" && url.pathname === "/health") return json(200, { ok: true });

    if (req.method === "GET" && url.pathname === "/v1/usage") {
      if (!cfg.adminCode || !timingSafeEqual(digest(bearer(req)), digest(cfg.adminCode))) {
        return json(401, { error: "Admin code needed." });
      }
      return json(200, { usage: cfg.usage.report() });
    }

    const person = personFor(bearer(req), cfg.codes);
    if (url.pathname.startsWith("/v1/") && !person) {
      return json(401, { error: "That access code isn't valid. Ask whoever invited you for a new one." });
    }

    if (req.method === "GET" && url.pathname === "/v1/me") {
      const models = [...cfg.allowedModels].filter((m) => cfg.keys[vendorOf(m)]);
      return json(200, { person, usedToday: cfg.usage.used(person!), dailyLimit: cfg.dailyLimit, models });
    }

    if (req.method !== "POST" || url.pathname !== "/v1/choose") return json(404, { error: "Not found." });

    let body: any;
    try {
      body = await req.json();
    } catch {
      return json(400, { error: "Send JSON." });
    }
    const model = typeof body?.model === "string" ? body.model.trim() : "";
    const system = typeof body?.system === "string" ? body.system : "";
    const prompt = typeof body?.prompt === "string" ? body.prompt : "";
    const maxTokens = Math.min(4000, Math.max(64, Number(body?.maxTokens) || 1500));
    if (!/^[A-Za-z0-9.\-:_]{1,80}$/.test(model)) return json(400, { error: "Pick a model." });
    if (!prompt || prompt.length > 60_000 || system.length > 4_000) return json(413, { error: "Request too large." });
    if (cfg.allowedModels.size > 0 && !cfg.allowedModels.has(model)) {
      return json(403, { error: `${model} isn't available on this server.` });
    }
    const vendor = vendorOf(model);
    const key = cfg.keys[vendor];
    if (!key) return json(403, { error: `This server isn't set up for ${vendorName[vendor]} models.` });

    if (!cfg.usage.take(person!, model, cfg.dailyLimit)) {
      return json(429, { error: `Daily limit of ${cfg.dailyLimit} AI fixes reached. It resets at midnight UTC.` });
    }

    const started = Date.now();
    const call = buildCall({ model, system, prompt, maxTokens }, key);
    let status = 0;
    try {
      const upstream = await send(call.url, {
        method: "POST",
        headers: call.headers,
        body: call.body,
        signal: AbortSignal.timeout(60_000),
      });
      status = upstream.status;
      const raw = await upstream.text();
      let reply: any = null;
      try {
        reply = JSON.parse(raw);
      } catch {}
      if (!upstream.ok) {
        // Don't pass on the company's key errors as the tester's fault.
        const code = upstream.status === 401 || upstream.status === 403 ? 502 : upstream.status;
        return json(code, { error: `${vendorName[vendor]}: ${errorMessage(reply, raw)}` });
      }
      const text = readText(vendor, reply);
      if (!text) return json(502, { error: `${vendorName[vendor]} sent an empty answer.` });
      return json(200, { text });
    } catch (e: any) {
      status = 504;
      return json(504, { error: `${vendorName[vendor]} didn't answer in time.` });
    } finally {
      // Never log prompts or answers, only who used what.
      log(`${new Date().toISOString()} ${person} ${model} ${status} ${Date.now() - started}ms`);
    }
  };
}
