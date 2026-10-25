import { describe, expect, test } from "bun:test";
import { createApp, parseCodes, personFor } from "../src/app";
import { buildCall, readText, vendorOf } from "../src/providers";
import { Usage } from "../src/usage";

const CODE = "jason-code-123456";

function setup(over: Partial<Parameters<typeof createApp>[0]> = {}) {
  const calls: { url: string; init: any }[] = [];
  const logs: string[] = [];
  const fakeFetch = (async (url: string, init: any) => {
    calls.push({ url, init });
    if (url.includes("anthropic")) {
      return new Response(JSON.stringify({ content: [{ type: "text", text: '{"index":3}' }] }), { status: 200 });
    }
    if (url.includes("openai")) {
      return new Response(JSON.stringify({ error: { message: "Incorrect API key" } }), { status: 401 });
    }
    return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: '{"index":1}' }] } }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const handle = createApp({
    keys: { anthropic: "sk-ant-server", openai: "sk-server", gemini: "AIza-server" },
    codes: parseCodes(`jason=${CODE},short=abc`),
    dailyLimit: 2,
    allowedModels: new Set(),
    adminCode: "admin-code-123456",
    usage: new Usage(":memory:"),
    fetch: fakeFetch,
    log: (l) => logs.push(l),
    ...over,
  });
  const ask = (body: unknown, code = CODE) =>
    handle(new Request("http://x/v1/choose", {
      method: "POST",
      headers: { authorization: `Bearer ${code}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    }));
  return { handle, ask, calls, logs };
}

const body = { model: "claude-haiku-5-5", system: "sys", prompt: "which one?", maxTokens: 300 };

describe("access", () => {
  test("short codes are ignored and wrong codes are refused", async () => {
    expect(parseCodes("a=abc,b=long-enough-code").size).toBe(1);
    const { ask } = setup();
    expect((await ask(body, "nope")).status).toBe(401);
    expect((await ask(body, "abc")).status).toBe(401);
  });

  test("codes resolve to the right person", () => {
    const codes = parseCodes(`jason=${CODE},kim=kim-code-1234567`);
    expect(personFor("kim-code-1234567", codes)).toBe("kim");
    expect(personFor("kim-code-123456", codes)).toBeNull();
  });

  test("health needs no code", async () => {
    const { handle } = setup();
    expect((await handle(new Request("http://x/health"))).status).toBe(200);
  });
});

describe("choosing", () => {
  test("forwards with the server's key and returns only the text", async () => {
    const { ask, calls, logs } = setup();
    const res = await ask(body);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ text: '{"index":3}' });
    expect(calls[0].url).toBe("https://api.anthropic.com/v1/messages");
    expect(calls[0].init.headers["x-api-key"]).toBe("sk-ant-server");
    expect(logs[0]).toContain("jason claude-haiku-5-5 200");
    expect(logs[0]).not.toContain("which one?");
  });

  test("routes Gemini models to Google", async () => {
    const { ask, calls } = setup();
    const res = await ask({ ...body, model: "gemini-3.8-flash" });
    expect(await res.json()).toEqual({ text: '{"index":1}' });
    expect(calls[0].url).toContain("models/gemini-3.8-flash:generateContent");
    expect(calls[0].init.headers["x-goog-api-key"]).toBe("AIza-server");
  });

  test("a bad server key isn't reported as the tester's fault", async () => {
    const { ask } = setup();
    const res = await ask({ ...body, model: "gpt-6-luna" });
    expect(res.status).toBe(502);
    expect((await res.json()).error).toContain("Incorrect API key");
  });

  test("daily limit per person", async () => {
    const { ask } = setup();
    expect((await ask(body)).status).toBe(200);
    expect((await ask(body)).status).toBe(200);
    const third = await ask(body);
    expect(third.status).toBe(429);
    expect((await third.json()).error).toContain("Daily limit of 2");
  });

  test("missing keys and blocked models are explained", async () => {
    const noOpenAI = setup({ keys: { anthropic: "k" } });
    const r1 = await noOpenAI.ask({ ...body, model: "gpt-6-luna" });
    expect(r1.status).toBe(403);
    expect((await r1.json()).error).toContain("OpenAI");
    const onlyHaiku = setup({ allowedModels: new Set(["claude-haiku-5-5"]) });
    expect((await onlyHaiku.ask({ ...body, model: "claude-opus-5-5" })).status).toBe(403);
    expect((await onlyHaiku.ask(body)).status).toBe(200);
  });

  test("rejects junk", async () => {
    const { ask } = setup();
    expect((await ask({ ...body, model: "../../etc" })).status).toBe(400);
    expect((await ask({ ...body, prompt: "x".repeat(60_001) })).status).toBe(413);
  });

  test("usage report needs the admin code", async () => {
    const { handle, ask } = setup();
    await ask(body);
    const denied = await handle(new Request("http://x/v1/usage", { headers: { authorization: `Bearer ${CODE}` } }));
    expect(denied.status).toBe(401);
    const ok = await handle(new Request("http://x/v1/usage", { headers: { authorization: "Bearer admin-code-123456" } }));
    expect((await ok.json()).usage[0]).toMatchObject({ person: "jason", model: "claude-haiku-5-5", count: 1 });
  });
});

describe("providers", () => {
  test("vendor routing matches the app", () => {
    expect(vendorOf("gpt-6.1-sol")).toBe("openai");
    expect(vendorOf("gemini-4-argon")).toBe("gemini");
    expect(vendorOf("claude-opus-5-5")).toBe("anthropic");
  });

  test("Gemini thinking parts are skipped", () => {
    const reply = { candidates: [{ content: { parts: [{ text: "hmm", thought: true }, { text: '{"index":2}' }] } }] };
    expect(readText("gemini", reply)).toBe('{"index":2}');
  });

  test("OpenAI asks for JSON", () => {
    const call = buildCall({ ...body, model: "gpt-6-luna" }, "k");
    expect(JSON.parse(call.body).response_format).toEqual({ type: "json_object" });
  });
});
