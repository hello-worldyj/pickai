import { uploadToB2 } from "./b2";
import { recordHistory } from "./history";

export interface Env {
  OPENAI_API_KEY: string;
  SHARED_SECRET: string;
  OPENAI_MODEL: string;
  HISTORY_DB: D1Database;
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
}

type Mode = "answer" | "explain";
type Role = "user" | "assistant";

interface Message {
  role: Role;
  text?: string;
  imageBase64?: string;
}

interface QueryRequest {
  mode: Mode;
  messages: Message[];
}

const SYSTEM_PROMPTS: Record<Mode, string> = {
  answer:
    "Give ONLY the final answer, nothing else. No restating the question, no work shown, no steps, no preamble, no LaTeX or math notation (no \\( \\), \\[ \\], $, or similar) — plain text only. " +
    'For a math or computation question, respond in exactly this format: "The answer is: <result>". For any other question, respond with just the answer itself in one short line. ' +
    "If the user asks a follow-up question, keep answering in this same terse style.",
  explain: "Give a clear, step-by-step explanation. Be thorough but concise. If the user asks a follow-up question, continue explaining in the same style.",
};

const IMAGE_INSTRUCTION =
  "Identify the question or problem shown in this image and solve it.";

const MAX_TEXT_LENGTH = 8000;
const MAX_MESSAGES = 20;

function isMessage(value: unknown): value is Message {
  if (typeof value !== "object" || value === null) return false;
  const m = value as Record<string, unknown>;
  if (m.role !== "user" && m.role !== "assistant") return false;
  const hasText = typeof m.text === "string" && m.text.length > 0;
  const hasImage = typeof m.imageBase64 === "string" && m.imageBase64.length > 0;
  return hasText || hasImage;
}

function isQueryRequest(body: unknown): body is QueryRequest {
  if (typeof body !== "object" || body === null) return false;
  const b = body as Record<string, unknown>;
  if (b.mode !== "answer" && b.mode !== "explain") return false;
  return Array.isArray(b.messages) && b.messages.length > 0 && b.messages.length <= MAX_MESSAGES && b.messages.every(isMessage);
}

type ChatContent =
  | string
  | ({ type: "text"; text: string } | { type: "image_url"; image_url: { url: string } })[];

// Uint8Array.from(str, c => c.charCodeAt(0)) dispatches a callback per character, which is
// slow enough on a multi-MB base64 string (a full-res screenshot) to blow the Worker's CPU
// time limit on its own. A preallocated array + plain indexed loop is JIT-friendly and avoids
// that per-element call overhead.
function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function toChatContent(message: Message): ChatContent {
  if (message.imageBase64) {
    return [
      { type: "text", text: message.text || IMAGE_INSTRUCTION },
      { type: "image_url", image_url: { url: `data:image/png;base64,${message.imageBase64}` } },
    ];
  }
  return (message.text ?? "").slice(0, MAX_TEXT_LENGTH);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname !== "/query" || request.method !== "POST") {
      return new Response("Not found", { status: 404 });
    }

    const providedKey = request.headers.get("X-Pick-Key");
    if (!env.SHARED_SECRET || providedKey !== env.SHARED_SECRET) {
      return new Response("Unauthorized", { status: 401 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    if (!isQueryRequest(body)) {
      return new Response(
        "Expected { mode: 'answer' | 'explain', messages: [{ role: 'user' | 'assistant', text?: string, imageBase64?: string }, ...] }",
        { status: 400 }
      );
    }

    const openaiMessages = [
      { role: "system", content: SYSTEM_PROMPTS[body.mode] },
      ...body.messages.map((message) => ({ role: message.role, content: toChatContent(message) })),
    ];

    const openaiResponse = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: env.OPENAI_MODEL || "gpt-4o-mini",
        messages: openaiMessages,
        temperature: 0.3,
      }),
    });

    if (!openaiResponse.ok) {
      const errText = await openaiResponse.text();
      return new Response(`Upstream error: ${errText}`, { status: 502 });
    }

    const data = await openaiResponse.json<{
      choices: { message: { content: string } }[];
    }>();

    const result = data.choices[0]?.message?.content?.trim() ?? "";

    // The most recent message is this turn's question — for the very first exchange
    // of a session that's the screenshot/text that kicked it off; for a follow-up it's
    // always text (the app never re-sends the original image on follow-ups), so this
    // naturally uploads the screenshot exactly once per session, not on every turn.
    const lastMessage = body.messages[body.messages.length - 1];
    const imageKey = lastMessage.imageBase64 ? `${Date.now()}-${crypto.randomUUID()}.png` : null;

    ctx.waitUntil(
      (async () => {
        try {
          if (imageKey && lastMessage.imageBase64) {
            await uploadToB2(env, imageKey, base64ToBytes(lastMessage.imageBase64), "image/png");
          }
          await recordHistory(env, {
            mode: body.mode,
            question: lastMessage.text ?? null,
            answer: result,
            imageKey,
          });
        } catch (err) {
          console.error("history persistence failed:", err);
        }
      })()
    );

    return new Response(JSON.stringify({ result }), {
      headers: { "Content-Type": "application/json" },
    });
  },
};
