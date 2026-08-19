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
