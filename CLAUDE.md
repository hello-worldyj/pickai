# Pick AI

Personal macOS menu-bar utility: global-hotkey screenshot/text capture → Cloudflare Worker
backend (OpenAI) → answer shown in a popup. History is stored in D1 + Backblaze B2, browsable on
a website and in the native Mac app.

- `backend/` — Cloudflare Worker, the `/query` endpoint. **Read `backend/CLAUDE.md` before
  touching anything here** — it documents known gotchas (a CPU-limit crash that looks like
  nothing in the logs, model-accuracy requirements, why certain things are hardcoded on purpose).
- `website/` — Firebase-hosted history browser + Cloudflare Worker API, Firebase Auth.
- `mac-app/` — Swift Package Manager menu-bar app (no Xcode project). Build with
  `mac-app/scripts/build_app.sh`, which has a hardened retry loop for an iCloud-Drive xattr race
  that can silently invalidate a code signature after signing succeeds — don't simplify that away.
  The `com.pickai.app` LaunchAgent (`KeepAlive=true`) runs its binary from
  `~/Library/Application Support/PickAI/PickAI.app`, NOT from this iCloud-synced folder — the
  build script deploys there as its last step. Don't point the LaunchAgent back at the
  `mac-app/PickAI.app` path: iCloud can re-tag that copy with `com.apple.FinderInfo` moments after
  a successful sign, invalidating the signature; launchd then SIGKILLs every relaunch attempt for
  a code-signing launch-constraint violation, in a tight crash loop severe enough to have frozen
  the whole machine once (2026-09-09).

## Deploys

`backend/**` pushed to `main` auto-deploys via `.github/workflows/deploy-backend.yml`. The
website deploys manually (`firebase deploy --only hosting`). The Mac app has no CI — rebuild and
restart locally after any change (`bash mac-app/scripts/build_app.sh` then
`launchctl kickstart -k gui/$(id -u)/com.pickai.app`).

## Automated backend fixes

A Claude routine watches `backend/` for auto-filed error issues (labeled `auto-filed`) and fixes
them automatically. If you're that routine: read `backend/CLAUDE.md` first, it's written for you.
