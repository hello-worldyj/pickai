# Pick AI Cloud History + Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the local `~/Library/Application Support/Pick AI/History` folder with a Cloudflare D1 + Backblaze B2 backed history, browsable through a new searchable website gated by Cloudflare Access.

**Architecture:** The existing `pick-ai-backend` Worker gains a background persistence step (upload screenshot to B2, insert a row into D1) that runs via `ctx.waitUntil` after the answer is already sent to the app. A new `pick-ai-history` Worker serves a static search UI plus two JSON/binary endpoints that read from the same D1 database and B2 bucket. The mac app drops local history entirely.

**Tech Stack:** Cloudflare Workers (TypeScript), Cloudflare D1, Cloudflare Workers Static Assets, Backblaze B2 (S3-compatible API via `aws4fetch`), vanilla HTML/CSS/JS frontend, Swift/AppKit (mac app changes).

**Spec:** `docs/superpowers/specs/2026-08-18-cloud-history-website-design.md`

## Global Constraints

- No automated test runner exists in this codebase today (neither `backend/` nor the mac app has one) — verification is via `wrangler dev` + `curl` locally, `wrangler d1 execute --local` for the database, and real deploys checked with `curl`/browser. Do not introduce a new test framework for this feature; that would be disproportionate to a two-Worker personal project with no existing test infra.
- This directory is **not a git repository** (confirmed: `git status` fails here). Skip every "commit" step a template might imply — verify manually and move to the next step instead. Do not run `git init` unprompted.
- Cloudflare account is already authenticated (`npx wrangler whoami` succeeds, scopes include `d1:write`, `workers:write`). Account ID: `988c02d2decf22365a035e8bfc3af3dd`.
- Backblaze B2 bucket already exists: name `pickai`, endpoint `s3.eu-central-003.backblazeb2.com`, region `eu-central-003`, Private, encryption enabled. An application key (name `pickai`, keyID `003ac4c3e6e2d700000000001`) has already been issued — the raw secret value is not written into any file in this repo; it's provided directly to `wrangler secret put` at execution time.
- Follow the existing backend's conventions: `tsconfig.json` (`target: ES2021`, `module: ES2022`, `moduleResolution: Bundler`, `strict: true`), `.gitignore` excludes `node_modules/`, `.dev.vars`, `.wrangler/`.

---

### Task 1: Create the D1 database and schema

**Files:**
- Create: `backend/schema.sql`

**Interfaces:**
- Produces: a D1 database named `pickai-history` with a `history` table (`id`, `created_at`, `mode`, `question`, `answer`, `image_key`) — every later task binds to this database by the `database_id` this task prints.

- [ ] **Step 1: Create the D1 database**

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/backend"
npx wrangler d1 create pickai-history
```

Copy the `database_id` from the output (also written into a `[[d1_databases]]` block wrangler prints — ignore that suggested block, Task 2 writes it by hand with the right binding name). Keep the ID handy for Tasks 2 and 3.

- [ ] **Step 2: Write the schema file**

```sql
-- backend/schema.sql
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    mode TEXT NOT NULL,
    question TEXT,
    answer TEXT NOT NULL,
    image_key TEXT
);
```

- [ ] **Step 3: Apply the schema locally and verify**

```bash
npx wrangler d1 execute pickai-history --local --file=schema.sql
npx wrangler d1 execute pickai-history --local --command "SELECT sql FROM sqlite_master WHERE name='history';"
```

Expected: the second command prints the `CREATE TABLE history (...)` statement back.

- [ ] **Step 4: Apply the schema to the real (remote) database**

```bash
npx wrangler d1 execute pickai-history --remote --file=schema.sql
npx wrangler d1 execute pickai-history --remote --command "SELECT sql FROM sqlite_master WHERE name='history';"
```

Expected: same output as Step 3, confirming the live database has the table.

---

### Task 2: Backend persistence (B2 upload + D1 insert)

**Files:**
- Create: `backend/src/b2.ts`
- Create: `backend/src/history.ts`
- Modify: `backend/src/index.ts`
- Modify: `backend/wrangler.toml`
- Modify: `backend/package.json` (add `aws4fetch` dependency)

**Interfaces:**
- Consumes: D1 database `pickai-history` from Task 1 (`database_id` from Task 1 Step 1).
- Produces: `uploadToB2(env, key, data, contentType): Promise<void>` and `recordHistory(env, entry): Promise<void>`, both called from `index.ts`'s `fetch` handler. Later tasks (website) re-implement their own GET-side `b2.ts`/`db.ts` — these are not imported cross-project, see Global Constraints on why they're duplicated rather than shared.

- [ ] **Step 1: Install `aws4fetch`**

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/backend"
npm install aws4fetch
```

- [ ] **Step 2: Write the B2 upload helper**

```typescript
// backend/src/b2.ts
import { AwsClient } from "aws4fetch";

export interface B2Env {
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
}

function client(env: B2Env): AwsClient {
  return new AwsClient({
    accessKeyId: env.B2_KEY_ID,
    secretAccessKey: env.B2_APPLICATION_KEY,
    region: "eu-central-003",
    service: "s3",
  });
}

export async function uploadToB2(
  env: B2Env,
  key: string,
  data: Uint8Array,
  contentType: string
): Promise<void> {
  const url = `https://${env.B2_ENDPOINT}/${env.B2_BUCKET}/${key}`;
  const response = await client(env).fetch(url, {
    method: "PUT",
    body: data,
    headers: { "Content-Type": contentType },
  });
  if (!response.ok) {
    throw new Error(`B2 upload failed: ${response.status} ${await response.text()}`);
  }
}
```

- [ ] **Step 3: Write the D1 history writer**

```typescript
// backend/src/history.ts
export interface HistoryEnv {
  HISTORY_DB: D1Database;
}

export interface HistoryEntry {
  mode: string;
  question: string | null;
  answer: string;
  imageKey: string | null;
}

export async function recordHistory(env: HistoryEnv, entry: HistoryEntry): Promise<void> {
  await env.HISTORY_DB.prepare(
    "INSERT INTO history (created_at, mode, question, answer, image_key) VALUES (?, ?, ?, ?, ?)"
  )
    .bind(new Date().toISOString(), entry.mode, entry.question, entry.answer, entry.imageKey)
    .run();
}
```

- [ ] **Step 4: Wire persistence into the request handler**

In `backend/src/index.ts`:

1. Add to the `Env` interface:

```typescript
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
```

2. Add imports near the top:

```typescript
import { uploadToB2 } from "./b2";
import { recordHistory } from "./history";
```

3. Change the handler signature from `async fetch(request: Request, env: Env): Promise<Response> {` to:

```typescript
async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
```

4. Immediately before the final `return new Response(JSON.stringify({ result }), ...)` at the end of the handler, insert:

```typescript
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
            const bytes = Uint8Array.from(atob(lastMessage.imageBase64), (c) => c.charCodeAt(0));
            await uploadToB2(env, imageKey, bytes, "image/png");
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

```

(This goes after `const result = data.choices[0]?.message?.content?.trim() ?? "";` and before the final `return`.)

- [ ] **Step 5: Add bindings to `wrangler.toml`**

```toml
name = "pick-ai-backend"
main = "src/index.ts"
compatibility_date = "2024-11-01"

[vars]
OPENAI_MODEL = "gpt-4o-mini"
B2_BUCKET = "pickai"
B2_ENDPOINT = "s3.eu-central-003.backblazeb2.com"

[[d1_databases]]
binding = "HISTORY_DB"
database_name = "pickai-history"
database_id = "<paste the database_id from Task 1 Step 1>"
```

- [ ] **Step 6: Set the B2 secrets**

```bash
npx wrangler secret put B2_KEY_ID
```
When prompted, paste: `003ac4c3e6e2d700000000001`

```bash
npx wrangler secret put B2_APPLICATION_KEY
```
When prompted, paste the application key value provided earlier in this session (not repeated here — it's a secret, shown only once by B2, and must never be written into a file in this repo).

- [ ] **Step 7: Verify locally**

```bash
npx wrangler dev --local &
sleep 3
curl -s -X POST http://localhost:8787/query \
  -H "Content-Type: application/json" \
  -H "X-Pick-Key: dev-secret-123" \
  -d '{"mode":"answer","messages":[{"role":"user","text":"say hi in one word"}]}'
sleep 1
npx wrangler d1 execute pickai-history --local --command "SELECT mode, question, answer, image_key FROM history ORDER BY id DESC LIMIT 1;"
kill %1
```

Expected: the `curl` returns `{"result":"..."}`, and the `d1 execute` shows one row with `mode=answer`, `question="say hi in one word"`, `image_key` NULL.

- [ ] **Step 8: Deploy and verify against production**

```bash
npx wrangler deploy
curl -s -X POST "https://pick-ai-backend.byeongminchoi12.workers.dev/query" \
  -H "Content-Type: application/json" \
  -H "X-Pick-Key: a5ecdc060e5315e7b4ad486cd7e3f48f76d05a38908479ac" \
  -d '{"mode":"answer","messages":[{"role":"user","text":"say hi in one word"}]}'
sleep 2
npx wrangler d1 execute pickai-history --remote --command "SELECT mode, question, answer, image_key FROM history ORDER BY id DESC LIMIT 1;"
```

Expected: same shape as Step 7, confirming the deployed Worker persists to the real database.

---

### Task 3: Website Worker — API endpoints

**Files:**
- Create: `website/package.json`
- Create: `website/tsconfig.json`
- Create: `website/.gitignore`
- Create: `website/wrangler.toml`
- Create: `website/src/db.ts`
- Create: `website/src/b2.ts`
- Create: `website/src/index.ts`

**Interfaces:**
- Consumes: D1 database `pickai-history` and B2 bucket `pickai` from Tasks 1-2 (same `database_id`, same B2 credentials).
- Produces: `GET /api/history?q=&mode=&beforeId=` returning `HistoryRow[]` JSON, and `GET /api/image/:key` streaming image bytes — Task 4's frontend calls both by exact path/query-param names below.

- [ ] **Step 1: Scaffold the project files**

```json
// website/package.json
{
  "name": "pick-ai-history",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "dependencies": {
    "aws4fetch": "^1.0.20"
  },
  "devDependencies": {
    "wrangler": "^3.90.0",
    "@cloudflare/workers-types": "^4.20241127.0",
    "typescript": "^5.6.0"
  }
}
```

```json
// website/tsconfig.json
{
  "compilerOptions": {
    "target": "ES2021",
    "lib": ["ES2021"],
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src/**/*.ts"]
}
```

```
node_modules/
.wrangler/
```
(`website/.gitignore` — no `.dev.vars` here since this Worker has no local-dev secrets file yet; Step 5 covers secrets via `wrangler secret put` directly.)

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/website"
npm install
```

- [ ] **Step 2: Write the D1 search helper**

```typescript
// website/src/db.ts
export interface HistoryRow {
  id: number;
  created_at: string;
  mode: string;
  question: string | null;
  answer: string;
  image_key: string | null;
}

export interface SearchParams {
  q?: string;
  mode?: string;
  beforeId?: number;
  limit: number;
}

export async function searchHistory(db: D1Database, params: SearchParams): Promise<HistoryRow[]> {
  const conditions: string[] = [];
  const bindings: unknown[] = [];

  if (params.q) {
    conditions.push("(question LIKE ? OR answer LIKE ?)");
    const like = `%${params.q}%`;
    bindings.push(like, like);
  }
  if (params.mode) {
    conditions.push("mode = ?");
    bindings.push(params.mode);
  }
  if (params.beforeId !== undefined) {
    conditions.push("id < ?");
    bindings.push(params.beforeId);
  }

  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const sql = `SELECT id, created_at, mode, question, answer, image_key FROM history ${where} ORDER BY id DESC LIMIT ?`;
  bindings.push(params.limit);

  const result = await db.prepare(sql).bind(...bindings).all<HistoryRow>();
  return result.results ?? [];
}
```

- [ ] **Step 3: Write the B2 read helper**

```typescript
// website/src/b2.ts
import { AwsClient } from "aws4fetch";

export interface B2Env {
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
}

function client(env: B2Env): AwsClient {
  return new AwsClient({
    accessKeyId: env.B2_KEY_ID,
    secretAccessKey: env.B2_APPLICATION_KEY,
    region: "eu-central-003",
    service: "s3",
  });
}

export async function fetchFromB2(env: B2Env, key: string): Promise<Response> {
  const url = `https://${env.B2_ENDPOINT}/${env.B2_BUCKET}/${key}`;
  return client(env).fetch(url, { method: "GET" });
}
```

- [ ] **Step 4: Write the Worker entrypoint**

```typescript
// website/src/index.ts
import { searchHistory } from "./db";
import { fetchFromB2 } from "./b2";

export interface Env {
  HISTORY_DB: D1Database;
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
  ASSETS: Fetcher;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/history") {
      const q = url.searchParams.get("q") ?? undefined;
      const mode = url.searchParams.get("mode") ?? undefined;
      const beforeIdParam = url.searchParams.get("beforeId");
      const beforeId = beforeIdParam ? Number(beforeIdParam) : undefined;
      const rows = await searchHistory(env.HISTORY_DB, { q, mode, beforeId, limit: 30 });
      return new Response(JSON.stringify(rows), {
        headers: { "Content-Type": "application/json" },
      });
    }

    if (url.pathname.startsWith("/api/image/")) {
      const key = decodeURIComponent(url.pathname.slice("/api/image/".length));
      if (!key) return new Response("Not found", { status: 404 });
      const b2Response = await fetchFromB2(env, key);
      if (!b2Response.ok) return new Response("Not found", { status: 404 });
      return new Response(b2Response.body, {
        headers: { "Content-Type": b2Response.headers.get("Content-Type") ?? "image/png" },
      });
    }

    return env.ASSETS.fetch(request);
  },
};
```

- [ ] **Step 5: Write `wrangler.toml` and set secrets**

```toml
name = "pick-ai-history"
main = "src/index.ts"
compatibility_date = "2024-11-01"

[vars]
B2_BUCKET = "pickai"
B2_ENDPOINT = "s3.eu-central-003.backblazeb2.com"

[[d1_databases]]
binding = "HISTORY_DB"
database_name = "pickai-history"
database_id = "<same database_id used in Task 2 Step 5>"

[assets]
directory = "./public"
binding = "ASSETS"
```

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/website"
npx wrangler secret put B2_KEY_ID
```
Paste: `003ac4c3e6e2d700000000001`

```bash
npx wrangler secret put B2_APPLICATION_KEY
```
Paste the same B2 application key value used in Task 2 Step 6.

- [ ] **Step 6: Create a placeholder public/ so local dev boots, then verify the API**

```bash
mkdir -p public
echo "<!doctype html><title>placeholder</title>" > public/index.html
npx wrangler dev --local &
sleep 3
curl -s "http://localhost:8787/api/history"
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8787/api/image/does-not-exist.png"
kill %1
```

Expected: `/api/history` returns `[]` or existing seeded rows as a JSON array (empty locally unless Task 1's local DB has rows from Task 2 Step 7 — it does, so expect one row back); the image request returns `404`.

(The real `public/index.html` is written in Task 4 — this step's placeholder only exists so `wrangler dev` has a valid `[assets] directory` to boot against.)

---

### Task 4: Static frontend

**Files:**
- Create: `website/public/index.html`
- Create: `website/public/style.css`
- Create: `website/public/app.js`

**Interfaces:**
- Consumes: `GET /api/history?q=&mode=&beforeId=` → `HistoryRow[]` and `GET /api/image/:key` from Task 3.

- [ ] **Step 1: Write the HTML shell**

```html
<!-- website/public/index.html -->
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Pick AI History</title>
<link rel="stylesheet" href="/style.css" />
</head>
<body>
<header>
  <h1>Pick AI History</h1>
  <div class="controls">
    <input id="search" type="search" placeholder="Search questions and answers…" />
    <div class="filters">
      <button class="filter-btn active" data-mode="">All</button>
      <button class="filter-btn" data-mode="answer">Answer</button>
      <button class="filter-btn" data-mode="explain">Explain</button>
    </div>
  </div>
</header>
<main id="grid" class="grid"></main>
<p id="empty" class="empty" hidden>No entries yet.</p>
<div id="errorState" class="empty" hidden>
  Couldn't load history. <button id="retryBtn" class="load-more">Retry</button>
</div>
<button id="loadMore" class="load-more" hidden>Load more</button>

<div id="modal" class="modal" hidden>
  <div class="modal-content">
    <button id="modalClose" class="modal-close">&times;</button>
    <img id="modalImage" class="modal-image" hidden />
    <p id="modalMeta" class="modal-meta"></p>
    <h2 id="modalQuestion"></h2>
    <p id="modalAnswer" class="modal-answer"></p>
  </div>
</div>

<script src="/app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Write the stylesheet (dark-mode aware)**

```css
/* website/public/style.css */
:root {
  --bg: #f5f5f7;
  --card-bg: #ffffff;
  --text: #1d1d1f;
  --text-secondary: #6e6e73;
  --border: #e5e5e7;
  --accent: #0071e3;
  --answer-badge: #34c759;
  --explain-badge: #af52de;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000000;
    --card-bg: #1c1c1e;
    --text: #f5f5f7;
    --text-secondary: #98989d;
    --border: #38383a;
    --accent: #0a84ff;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  background: var(--bg);
  color: var(--text);
}

header {
  position: sticky;
  top: 0;
  background: var(--bg);
  padding: 24px 32px 16px;
  border-bottom: 1px solid var(--border);
  z-index: 10;
}

h1 { font-size: 22px; margin: 0 0 16px; }

.controls { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }

#search {
  flex: 1;
  min-width: 240px;
  padding: 10px 14px;
  border-radius: 10px;
  border: 1px solid var(--border);
  background: var(--card-bg);
  color: var(--text);
  font-size: 14px;
}

.filters { display: flex; gap: 6px; }

.filter-btn {
  padding: 8px 14px;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: var(--card-bg);
  color: var(--text-secondary);
  font-size: 13px;
  cursor: pointer;
}

.filter-btn.active { background: var(--accent); color: white; border-color: var(--accent); }

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 16px;
  padding: 24px 32px;
}

.card {
  background: var(--card-bg);
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 16px;
  cursor: pointer;
  transition: transform 0.15s ease, box-shadow 0.15s ease;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.card:hover { transform: translateY(-2px); box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12); }

.card img { width: 100%; border-radius: 8px; object-fit: cover; max-height: 160px; }

.card-meta { display: flex; justify-content: space-between; align-items: center; font-size: 12px; color: var(--text-secondary); }

.badge { padding: 2px 8px; border-radius: 6px; font-size: 11px; font-weight: 600; color: white; }
.badge.answer { background: var(--answer-badge); }
.badge.explain { background: var(--explain-badge); }

.card-question {
  font-size: 14px;
  font-weight: 600;
  margin: 0;
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.card-answer {
  font-size: 13px;
  color: var(--text-secondary);
  margin: 0;
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
}

.empty, .load-more { text-align: center; color: var(--text-secondary); margin: 40px auto; display: block; }

.load-more {
  padding: 10px 20px;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: var(--card-bg);
  color: var(--text);
  cursor: pointer;
}

.modal {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 100;
  padding: 20px;
}

.modal-content {
  background: var(--card-bg);
  border-radius: 16px;
  padding: 28px;
  max-width: 640px;
  width: 100%;
  max-height: 85vh;
  overflow-y: auto;
  position: relative;
}

.modal-close {
  position: absolute;
  top: 16px;
  right: 16px;
  background: none;
  border: none;
  font-size: 24px;
  color: var(--text-secondary);
  cursor: pointer;
}

.modal-image { width: 100%; border-radius: 10px; margin-bottom: 16px; }
.modal-meta { font-size: 12px; color: var(--text-secondary); margin: 0 0 8px; }
.modal-answer { white-space: pre-wrap; line-height: 1.5; }
```

- [ ] **Step 3: Write the frontend logic**

```javascript
// website/public/app.js
const grid = document.getElementById("grid");
const emptyEl = document.getElementById("empty");
const errorEl = document.getElementById("errorState");
const retryBtn = document.getElementById("retryBtn");
const loadMoreBtn = document.getElementById("loadMore");
const searchInput = document.getElementById("search");
const filterBtns = document.querySelectorAll(".filter-btn");
const modal = document.getElementById("modal");
const modalClose = document.getElementById("modalClose");
const modalImage = document.getElementById("modalImage");
const modalMeta = document.getElementById("modalMeta");
const modalQuestion = document.getElementById("modalQuestion");
const modalAnswer = document.getElementById("modalAnswer");

// Inline "broken image" placeholder (small gray square) — used instead of the
// browser's default broken-image icon when a screenshot fails to load.
const IMAGE_FALLBACK =
  "data:image/svg+xml;charset=UTF-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='260' height='120'%3E%3Crect width='100%25' height='100%25' fill='%23808080' opacity='0.15'/%3E%3Ctext x='50%25' y='50%25' text-anchor='middle' dy='.3em' fill='%23808080' font-family='sans-serif' font-size='13'%3EImage unavailable%3C/text%3E%3C/svg%3E";

let currentMode = "";
let currentQuery = "";
let lastId;
let debounceTimer = null;

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function formatTime(iso) {
  return new Date(iso).toLocaleString();
}

function renderCard(entry) {
  const card = document.createElement("div");
  card.className = "card";
  card.innerHTML = `
    ${entry.image_key ? `<img src="/api/image/${encodeURIComponent(entry.image_key)}" loading="lazy" />` : ""}
    <div class="card-meta">
      <span class="badge ${entry.mode}">${entry.mode}</span>
      <span>${formatTime(entry.created_at)}</span>
    </div>
    <p class="card-question">${escapeHtml(entry.question || "(screenshot)")}</p>
    <p class="card-answer">${escapeHtml(entry.answer)}</p>
  `;
  const img = card.querySelector("img");
  if (img) img.addEventListener("error", () => { img.src = IMAGE_FALLBACK; }, { once: true });
  card.addEventListener("click", () => openModal(entry));
  return card;
}

function openModal(entry) {
  modalImage.hidden = !entry.image_key;
  if (entry.image_key) {
    modalImage.src = `/api/image/${encodeURIComponent(entry.image_key)}`;
    modalImage.addEventListener("error", () => { modalImage.src = IMAGE_FALLBACK; }, { once: true });
  }
  modalMeta.textContent = `${entry.mode} · ${formatTime(entry.created_at)}`;
  modalQuestion.textContent = entry.question || "(screenshot)";
  modalAnswer.textContent = entry.answer;
  modal.hidden = false;
}

modalClose.addEventListener("click", () => { modal.hidden = true; });
modal.addEventListener("click", (e) => {
  if (e.target === modal) modal.hidden = true;
});

async function loadEntries(reset) {
  if (reset) {
    grid.innerHTML = "";
    lastId = undefined;
  }
  errorEl.hidden = true;

  const params = new URLSearchParams();
  if (currentQuery) params.set("q", currentQuery);
  if (currentMode) params.set("mode", currentMode);
  if (lastId !== undefined) params.set("beforeId", String(lastId));

  let rows;
  try {
    const res = await fetch(`/api/history?${params.toString()}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    rows = await res.json();
  } catch (err) {
    errorEl.hidden = false;
    emptyEl.hidden = true;
    loadMoreBtn.hidden = true;
    return;
  }

  if (rows.length === 0 && reset) {
    emptyEl.hidden = false;
    loadMoreBtn.hidden = true;
    return;
  }
  emptyEl.hidden = true;

  for (const entry of rows) {
    grid.appendChild(renderCard(entry));
  }

  if (rows.length > 0) {
    lastId = rows[rows.length - 1].id;
  }
  loadMoreBtn.hidden = rows.length < 30;
}

retryBtn.addEventListener("click", () => loadEntries(true));

searchInput.addEventListener("input", () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    currentQuery = searchInput.value.trim();
    loadEntries(true);
  }, 250);
});

filterBtns.forEach((btn) => {
  btn.addEventListener("click", () => {
    filterBtns.forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    currentMode = btn.dataset.mode;
    loadEntries(true);
  });
});

loadMoreBtn.addEventListener("click", () => loadEntries(false));

loadEntries(true);
```

- [ ] **Step 4: Verify locally**

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/website"
npx wrangler dev --local &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8787/"
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8787/style.css"
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8787/app.js"
kill %1
```

Expected: all three return `200`. Then open `http://localhost:8787/` in a real browser (the dev server needs to be running; re-launch it without `&`/`kill` for an interactive look) and confirm the seeded row from Task 2 Step 7 shows up as a card, search/filter update the grid, and clicking a card opens the modal.

- [ ] **Step 5: Deploy**

```bash
npx wrangler deploy
```

Note the deployed URL (`https://pick-ai-history.<subdomain>.workers.dev`) — Task 6 needs it.

---

### Task 5: Cloudflare Access (manual)

**Files:** none — this is dashboard configuration, not code.

**Interfaces:** none.

- [ ] **Step 1: Walk through Cloudflare Zero Trust dashboard setup with the user**

This step can't be scripted via `wrangler` — Access applications are configured in the Cloudflare dashboard. Guide the user through:

1. Go to `https://one.dash.cloudflare.com/` → Access → Applications → Add an application → Self-hosted.
2. Application domain: the `pick-ai-history.<subdomain>.workers.dev` hostname from Task 4 Step 5.
3. Add a policy: Action = Allow, Include = "Emails" containing the user's own email address only.
4. Save.

- [ ] **Step 2: Verify it's actually gated**

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://pick-ai-history.<subdomain>.workers.dev/"
```

Expected: `302` (redirect to Cloudflare's login page) rather than `200` — confirms Access is intercepting unauthenticated requests. Then visit the URL in a real browser and confirm the email-code login flow works and lands on the site afterward.

---

### Task 6: Mac app — remove local history, add website link

**Files:**
- Delete: `mac-app/Sources/PickAI/HistoryStore.swift`
- Modify: `mac-app/Sources/PickAI/OverlayPanel.swift`
- Modify: `mac-app/Sources/PickAI/AppDelegate.swift`
- Modify: `mac-app/Sources/PickAI/Config.swift`

**Interfaces:**
- Consumes: the deployed website URL from Task 4 Step 5.
- Produces: none (leaf task).

- [ ] **Step 1: Delete the local history store**

```bash
rm "/Users/choibyeongmin/Desktop/pick ai/mac-app/Sources/PickAI/HistoryStore.swift"
```

- [ ] **Step 2: Remove the `HistoryStore.save` call from `OverlayPanel.swift`**

Find this block in `runQuery()` and delete it (keep everything else in the function as-is):

```swift
                HistoryStore.save(
                    mode: mode,
                    question: messages.last(where: { $0.role == "user" })?.text,
                    answer: result,
                    imagePNGData: isFirstExchange ? initialImagePNGData : nil
                )
```

Also remove the now-unused `isFirstExchange` local (`let isFirstExchange = messages.count == 1`) from the top of `runQuery()` — it was only computed for that call.

- [ ] **Step 3: Add the website URL to `Config.swift`**

```swift
// mac-app/Sources/PickAI/Config.swift
import Foundation

enum Config {
    static let backendURL = URL(string: "https://pick-ai-backend.byeongminchoi12.workers.dev/query")!
    static let sharedSecret = "a5ecdc060e5315e7b4ad486cd7e3f48f76d05a38908479ac"
    static let historyURL = URL(string: "https://pick-ai-history.<subdomain>.workers.dev")!
}
```

(Fill in `<subdomain>` with the exact hostname noted in Task 4 Step 5.)

- [ ] **Step 4: Update the menu item in `AppDelegate.swift`**

Change:
```swift
        menu.addItem(withTitle: "Open History Folder", action: #selector(openHistoryFolder), keyEquivalent: "")
```
to:
```swift
        menu.addItem(withTitle: "Open Pick AI History", action: #selector(openHistoryFolder), keyEquivalent: "")
```

Change the action implementation:
```swift
    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(HistoryStore.directoryURL)
    }
```
to:
```swift
    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(Config.historyURL)
    }
```

- [ ] **Step 5: Rebuild and relaunch**

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/mac-app"
bash scripts/build_app.sh
launchctl kickstart -k gui/$(id -u)/com.pickai.app
sleep 2
pgrep -x PickAI
```

Expected: build succeeds with no errors (in particular, no leftover reference to `HistoryStore` — a compile error here means Step 2 missed a usage), and a live PID prints.

---

### Task 7: End-to-end verification

**Files:** none.

**Interfaces:** none — this task only exercises the full system built by Tasks 1-6.

- [ ] **Step 1: Trigger a real query from the mac app**

Ask the user to press ⌃⌥⌘S over any content and click "Answer" (or use "Wake Pick AI Up Here" from the menu), for real — this can't be safely automated (established earlier in this project: the overlay panel doesn't respond to synthetic AX/CGEvent clicks).

- [ ] **Step 2: Confirm it landed in D1 and B2**

```bash
cd "/Users/choibyeongmin/Desktop/pick ai/backend"
npx wrangler d1 execute pickai-history --remote --command "SELECT id, created_at, mode, question, image_key FROM history ORDER BY id DESC LIMIT 1;"
```

Expected: a row with a `created_at` timestamp matching roughly when the user just triggered the query, and (if it was a screenshot capture) a non-null `image_key`.

- [ ] **Step 3: Confirm it's visible on the website**

Ask the user to open `Config.historyURL` (via the menu item from Task 6) in their browser, log in via Cloudflare Access if not already, and confirm the new entry appears at the top of the grid with its screenshot thumbnail (if any) loading correctly and the answer text matching what the app showed.
