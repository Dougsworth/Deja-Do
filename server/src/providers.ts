// Sends one "which element is it?" request to the company that runs the model,
// using this server's own keys. Mirrors Sources/DejaDoCore/AIProviders.swift.

export type Vendor = "anthropic" | "openai" | "gemini";

export interface Keys {
  anthropic?: string;
  openai?: string;
  gemini?: string;
}

export interface Ask {
  model: string;
  system: string;
  prompt: string;
  maxTokens: number;
}

export interface Call {
  url: string;
  headers: Record<string, string>;
  body: string;
}

export function vendorOf(model: string): Vendor {
  if (/^(gpt|o1|o3|o4)/.test(model)) return "openai";
  if (model.startsWith("gemini")) return "gemini";
  return "anthropic";
}

export const vendorName: Record<Vendor, string> = {
  anthropic: "Anthropic",
  openai: "OpenAI",
  gemini: "Google Gemini",
};

export function buildCall(ask: Ask, key: string): Call {
  const json = { "content-type": "application/json" };
  switch (vendorOf(ask.model)) {
    case "anthropic":
      return {
        url: "https://api.anthropic.com/v1/messages",
        headers: { ...json, "x-api-key": key, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: ask.model,
          max_tokens: ask.maxTokens,
          system: ask.system,
          messages: [{ role: "user", content: ask.prompt }],
        }),
      };
    case "openai":
      return {
        url: "https://api.openai.com/v1/chat/completions",
        headers: { ...json, authorization: `Bearer ${key}` },
        body: JSON.stringify({
          model: ask.model,
          max_completion_tokens: ask.maxTokens,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: ask.system },
            { role: "user", content: ask.prompt },
          ],
        }),
      };
    case "gemini":
      return {
        url: `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(ask.model)}:generateContent`,
        headers: { ...json, "x-goog-api-key": key },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: ask.system }] },
          contents: [{ role: "user", parts: [{ text: ask.prompt }] }],
          generationConfig: { responseMimeType: "application/json", maxOutputTokens: ask.maxTokens },
        }),
      };
  }
}

/** The model's text from a successful reply, or null if it can't be found. */
export function readText(vendor: Vendor, reply: any): string | null {
  let text: string | undefined;
  switch (vendor) {
    case "anthropic":
      text = (reply?.content ?? [])
        .filter((c: any) => c?.type === "text")
        .map((c: any) => c.text)
        .join("");
      break;
    case "openai":
      text = reply?.choices?.[0]?.message?.content;
      break;
    case "gemini":
      text = (reply?.candidates?.[0]?.content?.parts ?? [])
        .filter((p: any) => !p?.thought)
        .map((p: any) => p?.text ?? "")
        .join("");
      break;
  }
  return typeof text === "string" && text.length > 0 ? text : null;
}

export function errorMessage(reply: any, raw: string): string {
  const m = reply?.error?.message ?? (typeof reply?.error === "string" ? reply.error : undefined);
  return String(m ?? raw).slice(0, 200);
}
