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
  GITHUB_TOKEN: string;
  CF_VERSION_METADATA: { id: string };
}

const ISSUE_REPO = "hello-worldyj/pick_ai";

function githubHeaders(env: Env): Record<string, string> {
  return {
    Authorization: `Bearer ${env.GITHUB_TOKEN}`,
    "Content-Type": "application/json",
    "User-Agent": "pick-ai-backend",
    Accept: "application/vnd.github+json",
  };
}

// Files a GitHub issue for a genuine unexpected exception, so it gets picked up and fixed
// without anyone having to notice and report it first. Deliberately narrow: expected error
// paths (bad request, auth, OpenAI being down) return their own status codes above this and
// never reach here — only real bugs in this code should file an issue. Can't catch a Worker
// killed outright for exceeding its CPU/memory limits (execution halts before this runs) —
// that shows up as no issue at all, not one filed by this function.
async function reportErrorToGitHub(env: Env, error: unknown, context: Record<string, unknown>): Promise<void> {
  if (!env.GITHUB_TOKEN) return;
  const message = error instanceof Error ? error.message : String(error);
  const stack = error instanceof Error ? error.stack : undefined;
  const title = `[auto] Backend error: ${message.slice(0, 100)}`;
  const versionId = env.CF_VERSION_METADATA?.id ?? "unknown";

  try {
    // A repeatedly-triggering bug shouldn't file a new issue (and fire a new routine run) on
    // every single request — that's issue-spam and wasted routine invocations for one root
    // cause. Bump an occurrence count on the existing open issue instead, if there is one.
    const existing = await fetch(
      `https://api.github.com/repos/${ISSUE_REPO}/issues?state=open&labels=auto-filed&per_page=50`,
      { headers: githubHeaders(env) }
    );
    if (existing.ok) {
      const issues = await existing.json<{ number: number; title: string }[]>();
      const match = issues.find((i) => i.title === title);
      if (match) {
        await fetch(`https://api.github.com/repos/${ISSUE_REPO}/issues/${match.number}/comments`, {
          method: "POST",
          headers: githubHeaders(env),
          body: JSON.stringify({
            body: `Occurred again at ${new Date().toISOString()} (worker version \`${versionId}\`). Context: \`${JSON.stringify(context)}\`.`,
          }),
        });
        return;
      }
    }

    await fetch(`https://api.github.com/repos/${ISSUE_REPO}/issues`, {
      method: "POST",
      headers: githubHeaders(env),
      body: JSON.stringify({
        title,
        body:
          `**Message:** ${message}\n\n` +
          `**Context:** \`${JSON.stringify(context)}\`\n\n` +
          `**Worker version:** \`${versionId}\`\n\n` +
          `**Time:** ${new Date().toISOString()}\n\n` +
          (stack ? `**Stack:**\n\`\`\`\n${stack}\n\`\`\`` : ""),
        labels: ["auto-filed", "backend"],
      }),
    });
  } catch (reportErr) {
    console.error("failed to file GitHub issue:", reportErr);
  }
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

// Split into two labeled sections so the backend can show the model's work (which materially
// improves accuracy on arithmetic/multi-step problems vs. jumping straight to an answer) while
// still giving the app a clean final answer to display and store. Plain text only, no LaTeX/markdown
// in either section — that formatting was explicitly requested to not creep back in.
const REASONING_MARKER = "FINAL ANSWER:";

const SYSTEM_PROMPTS: Record<Mode, string> = {
  answer:
    "Work through the problem step by step first, showing your reasoning in plain text (no LaTeX or math notation — no \\( \\), \\[ \\], $, or similar). " +
    `Then, on a new line, write "${REASONING_MARKER}" followed by ONLY the final answer, nothing else — no restating the question, no units of work, no LaTeX. ` +
    `For a math or computation question, that final line must be exactly "${REASONING_MARKER} The answer is: <result>". For any other question, that final line must be exactly "${REASONING_MARKER} <answer>" with the answer in one short line. ` +
    "If the user asks a follow-up question, repeat this same two-part structure.",
  explain: "Give a clear, step-by-step explanation. Be thorough but concise. If the user asks a follow-up question, continue explaining in the same style.",
};

const IMAGE_INSTRUCTION =
  "Identify the question or problem shown in this image and solve it.";

const MAX_TEXT_LENGTH = 8000;
const MAX_MESSAGES = 20;

export function isMessage(value: unknown): value is Message {
  if (typeof value !== "object" || value === null) return false;
  const m = value as Record<string, unknown>;
  if (m.role !== "user" && m.role !== "assistant") return false;
  const hasText = typeof m.text === "string" && m.text.length > 0;
  const hasImage = typeof m.imageBase64 === "string" && m.imageBase64.length > 0;
  return hasText || hasImage;
}

export function isQueryRequest(body: unknown): body is QueryRequest {
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
export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// "explain" mode's whole response is already the step-by-step content the user asked to see,
// so it has no separate reasoning section. Only "answer" mode's response is split on the marker;
// if the model didn't include it (rare, but not guaranteed), fall back to the full content as
// the result with no reasoning shown rather than losing the answer.
export function splitReasoningAndAnswer(content: string, mode: Mode): { reasoning: string; result: string } {
  if (mode !== "answer") return { reasoning: "", result: content };
  const markerIndex = content.indexOf(REASONING_MARKER);
  if (markerIndex === -1) return { reasoning: "", result: content };
  return {
    reasoning: content.slice(0, markerIndex).trim(),
    result: content.slice(markerIndex + REASONING_MARKER.length).trim(),
  };
}

export function toChatContent(message: Message): ChatContent {
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

    try {
      return await handleQuery(body, env, ctx);
    } catch (error) {
      const hasImage = body.messages.some((m) => !!m.imageBase64);
      ctx.waitUntil(
        reportErrorToGitHub(env, error, {
          mode: body.mode,
          messageCount: body.messages.length,
          hasImage,
          cfRay: request.headers.get("cf-ray") ?? undefined,
        })
      );
      console.error("unexpected error:", error);
      return new Response("Internal error", { status: 500 });
    }
  },
};

async function handleQuery(body: QueryRequest, env: Env, ctx: ExecutionContext): Promise<Response> {
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
        // gpt-5.x models reject any non-default temperature via chat/completions (400 error),
        // so this is intentionally omitted rather than set — don't add it back.
        model: env.OPENAI_MODEL || "gpt-4o-mini",
        // "medium" is Terra's default reasoning effort — set explicitly rather than omitted
        // so it's not silently affected by a future provider default change.
        reasoning_effort: "medium",
        messages: openaiMessages,
      }),
    });

    if (!openaiResponse.ok) {
      const errText = await openaiResponse.text();
      return new Response(`Upstream error: ${errText}`, { status: 502 });
    }

    const data = await openaiResponse.json<{
      choices: { message: { content: string } }[];
    }>();

    const content = data.choices[0]?.message?.content?.trim() ?? "";
    const { reasoning, result } = splitReasoningAndAnswer(content, body.mode);

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

    return new Response(JSON.stringify({ result, reasoning }), {
      headers: { "Content-Type": "application/json" },
    });
}
