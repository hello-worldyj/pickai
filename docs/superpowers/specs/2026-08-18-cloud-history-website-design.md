# Pick AI Cloud History + Website

## Goal

Replace the local `~/Library/Application Support/Pick AI/History` folder with
cloud-backed storage, browsable through a searchable website, so past
questions/screenshots and their answers are easy to find later from any
device, not just buried in a local folder.

## Non-goals

- Multi-user support. This is single-user (one Cloudflare Access identity).
- Editing/deleting history from the UI (read-only browsing for v1).
- Real-time sync indicators, offline support, or a native app for the website.

## Architecture

```
Mac app (PickAI.app)
   │  POST /query  (unchanged from the app's perspective)
   ▼
pick-ai-backend (existing Worker)
   │  1. calls OpenAI, returns the answer to the app immediately
   │  2. ctx.waitUntil(): uploads screenshot to B2, writes a row to D1
   ▼                                   ▼
Backblaze B2 (bucket: pickai)     Cloudflare D1 (new: pickai-history DB)
   screenshot blobs                  metadata: timestamp, mode, question,
                                      answer, image_key
                                          ▲
                                          │  SQL search/filter
                              ┌───────────┴───────────┐
                              │   pick-ai-history      │  (new Worker)
                              │   - serves static UI   │
                              │   - GET /api/history   │
                              │   - GET /api/image/:key│ (streams from B2)
                              └───────────┬────────────┘
                                          │  gated by
                                   Cloudflare Access (email login)
                                          │
                                     your browser
```

Two Workers, both in the existing Cloudflare account:
- **pick-ai-backend** (existing): gains the persistence step.
- **pick-ai-history** (new): the website — static frontend + a tiny JSON API,
  reading D1 for search and proxying image bytes from B2 (bucket stays
  Private; only this Worker's server-side code ever holds B2 credentials).

## Data model (D1)

```sql
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,   -- ISO 8601
    mode TEXT NOT NULL,         -- 'answer' | 'explain'
    question TEXT,              -- nullable: image-only captures have no text
    answer TEXT NOT NULL,
    image_key TEXT              -- nullable: B2 object key, null for text-only queries
);
```

No separate "conversation" grouping for v1 — each answered Q&A (initial or
follow-up) is its own row, consistent with how local history already worked.
Follow-up rows have `image_key = NULL` (the image isn't re-uploaded).

## Backend changes (pick-ai-backend)

- New environment bindings: `B2_KEY_ID`, `B2_APPLICATION_KEY` (secrets),
  `B2_BUCKET`, `B2_ENDPOINT` (vars) — endpoint is
  `s3.eu-central-003.backblazeb2.com` per the existing bucket.
- New D1 binding: `HISTORY_DB` → `pickai-history` database.
- After building the OpenAI response, inside `ctx.waitUntil(...)`:
  1. If the request included an image, PUT it to B2 at
     `{timestamp}-{random-suffix}.png` using B2's S3-compatible API
     (SigV4-signed request via Workers' native `fetch` + `aws4fetch` or a
     hand-rolled signer — pick whichever keeps the Worker bundle small).
  2. `INSERT INTO history (...) VALUES (...)` via the D1 binding.
- Failures here are caught, logged (`console.error`), and swallowed — they
  never affect the response already sent to the app.

## Website (pick-ai-history, new Worker)

- **`GET /`** — static HTML/CSS/JS (served via Workers static assets):
  a card grid of entries (screenshot thumbnail if present, question/answer
  snippet, timestamp, mode badge), a search box, and a mode filter
  (All / Answer / Explain). Clicking a card expands to the full answer and
  full-size image. Dark-mode aware, since that's the bar the rest of this
  app has been held to.
- **`GET /api/history?q=&mode=&limit=&before=`** — queries D1
  (`WHERE question LIKE ? OR answer LIKE ?` when `q` is present, plus mode
  filter and cursor-based pagination on `id`/`created_at`), returns JSON rows.
- **`GET /api/image/:key`** — server-side GET from B2 using the same
  credentials, streamed back with the correct `Content-Type`. This is the
  only way images are ever served — the bucket itself stays Private and is
  never linked to directly.
- **Auth**: Cloudflare Access application configured on this Worker's route
  in the Cloudflare Zero Trust dashboard (manual one-time setup — Access
  policies aren't managed via `wrangler.toml`). Restricts the whole Worker to
  your email only. I'll walk through this step when we get there.

## Mac app changes

- Remove `HistoryStore.swift` and the `HistoryStore.save(...)` call in
  `OverlayPanel.runQuery()` — persistence now happens entirely server-side,
  so the app doesn't need to know about it at all.
- Replace the "Open History Folder" menu item with "Open Pick AI History",
  pointing at the `pick-ai-history` Worker's URL.

## Error handling

- Backend: B2/D1 failures are logged and non-fatal to the user-facing answer
  (see above).
- Website: a failed `/api/history` fetch shows an inline retry state rather
  than a blank page; a failed image load shows a placeholder rather than a
  broken-image icon.
- No retry/backoff logic for the persistence step in v1 — a dropped history
  entry on an occasional B2/D1 hiccup is an acceptable loss at personal scale
  (YAGNI; can revisit if it turns out to matter in practice).

## Testing

- Backend: unit-style check that a request with an image results in exactly
  one B2 PUT and one D1 INSERT with matching `image_key`; a text-only request
  results in a D1 INSERT with `image_key = NULL` and no B2 call.
- Website: `/api/history` search/filter/pagination against a seeded local D1
  (via `wrangler d1 execute --local`); `/api/image/:key` returns 404 for an
  unknown key and the correct bytes/content-type for a known one.
- Manual end-to-end pass after deploy: trigger a real query from the mac app,
  confirm the row + image show up on the website within a few seconds.

## Rollout order

1. Create the D1 database and `pickai-history` table.
2. Add B2 + D1 bindings/secrets to `pick-ai-backend`, implement and deploy
   the persistence step.
3. Scaffold `pick-ai-history` Worker: `/api/history` and `/api/image/:key`.
4. Build the static frontend against those two endpoints.
5. Deploy `pick-ai-history`, configure Cloudflare Access on it (manual).
6. Update the mac app (remove local history, add the new menu item), rebuild.
7. End-to-end manual verification.
