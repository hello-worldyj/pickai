# Pick AI backend — context for automated fixes

This is a Cloudflare Worker (`backend/src/index.ts`) behind a personal iOS-free Mac menu-bar app
called Pick AI. It receives a screenshot or selected text, asks OpenAI for an answer, and
persists the exchange to D1 (metadata) + Backblaze B2 (the screenshot image).

## Known gotchas (read before diagnosing a new issue)

1. **CPU time limit, not just exceptions.** Cloudflare Workers get killed outright if they burn
   too much synchronous CPU in one request — this happens *before* any try/catch in our own code
   can run, so it never reaches `reportErrorToGitHub` and never files an issue with a real stack
   trace. If a bug report has NO real error/stack (or the Worker is just timing out / returning
   503 without ever hitting our code), suspect a CPU-limit kill, not a JS exception. Look for
   expensive synchronous work on large inputs — especially anything looping over
   `imageBase64` (screenshots are 1-3MB base64 strings). We already hit this once: decoding
   base64 with `Uint8Array.from(str, c => c.charCodeAt(0))` (per-character callback dispatch)
   was slow enough to blow the CPU budget on a real screenshot. Fixed with a plain indexed loop
   (see `base64ToBytes` in index.ts) — if a similar pattern shows up elsewhere, apply the same fix.

2. **`OPENAI_MODEL` matters for correctness, not just cost.** It was `gpt-4o-mini` originally and
   made real arithmetic mistakes (e.g. answered 500/25 = 10). Switched to `gpt-4o`. Don't downgrade
   the model to save cost without checking this doesn't reintroduce accuracy regressions — this
   app is used to solve math/homework problems, so wrong answers are a correctness bug, not a
   quality nice-to-have.

3. **`SYSTEM_PROMPTS.answer` format is load-bearing.** It must produce ONLY a plain-text final
   answer, no LaTeX, no restating the question. This was explicitly requested — if you touch the
   prompt, keep the "The answer is: X" format for math and don't let LaTeX/markdown creep back in.

4. **`OWNER_UID` in `history.ts` is intentionally hardcoded.** The mac app is the only writer of
   history and only one person uses it — this isn't a bug, don't "fix" it into a dynamic user
   lookup unless asked.

5. **Expected error paths are NOT bugs and should never reach `reportErrorToGitHub`.** Bad
   request (400), wrong `X-Pick-Key` (401), OpenAI being down (502) are all normal operating
   conditions handled explicitly with their own status codes in `handleQuery`. Only a genuine
   uncaught exception in our own code should ever result in a filed issue — if you're looking at
   an auto-filed issue, it already passed that bar; don't second-guess whether it's "really a bug."

## Deploy flow

Push to `main` (paths under `backend/**`) auto-deploys via `.github/workflows/deploy-backend.yml`
using the `CLOUDFLARE_API_TOKEN` GitHub secret. Never run `wrangler deploy` directly from an
automated fix — just push and let the Action handle it, then verify with a live curl request
after ~30s.

## Verifying a fix

Prefer reproducing with the *actual* input that triggered the bug when the issue body has enough
detail (e.g. a large image payload, a specific message shape) over a generic "say hi" smoke test —
a generic test can pass while the real trigger condition (like a large payload) still fails.
