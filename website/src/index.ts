import { searchHistory } from "./db";
import { fetchFromB2 } from "./b2";

export interface Env {
  HISTORY_DB: D1Database;
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
  HISTORY_ACCESS_KEY: string;
  ASSETS: Fetcher;
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "https://picky-ai.web.app",
  "Access-Control-Allow-Headers": "X-History-Key, Content-Type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  // Without this, Cloudflare's edge cache can serve a stale response for the same URL to a
  // DIFFERENT request — including an old pre-auth 200 to someone with no/wrong key. Verified
  // this actually happened during testing: a cached 200 for /api/history was served with no
  // key at all until this header was added.
  "Cache-Control": "no-store",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS" && url.pathname.startsWith("/api/")) {
      return new Response(null, { headers: CORS_HEADERS });
    }

    if (url.pathname.startsWith("/api/")) {
      // The frontend now lives on a separate origin (Firebase Hosting), so this API is the
      // only thing standing between this data (real screenshots/questions) and the public
      // internet — Cloudflare Access only protects Cloudflare-routed domains, not Firebase's.
      const providedKey = request.headers.get("X-History-Key");
      if (!env.HISTORY_ACCESS_KEY || providedKey !== env.HISTORY_ACCESS_KEY) {
        return new Response("Unauthorized", { status: 401, headers: CORS_HEADERS });
      }
    }

    if (url.pathname === "/api/history") {
      const q = url.searchParams.get("q") ?? undefined;
      const mode = url.searchParams.get("mode") ?? undefined;
      const beforeIdParam = url.searchParams.get("beforeId");
      const beforeId = beforeIdParam ? Number(beforeIdParam) : undefined;
      const rows = await searchHistory(env.HISTORY_DB, { q, mode, beforeId, limit: 30 });
      return new Response(JSON.stringify(rows), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    if (url.pathname.startsWith("/api/image/")) {
      const key = decodeURIComponent(url.pathname.slice("/api/image/".length));
      if (!key) return new Response("Not found", { status: 404, headers: CORS_HEADERS });
      const b2Response = await fetchFromB2(env, key);
      if (!b2Response.ok) return new Response("Not found", { status: 404, headers: CORS_HEADERS });
      return new Response(b2Response.body, {
        headers: {
          "Content-Type": b2Response.headers.get("Content-Type") ?? "image/png",
          ...CORS_HEADERS,
        },
      });
    }

    return env.ASSETS.fetch(request);
  },
};
