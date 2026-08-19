import { searchHistory, deleteHistoryRow, userOwnsImage } from "./db";
import { fetchFromB2, deleteFromB2 } from "./b2";
import { verifyFirebaseToken, extractBearerToken, AuthError } from "./auth";

export interface Env {
  HISTORY_DB: D1Database;
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
  ASSETS: Fetcher;
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "https://picky-ai.web.app",
  "Access-Control-Allow-Headers": "Authorization, Content-Type",
  "Access-Control-Allow-Methods": "GET, DELETE, OPTIONS",
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

    if (!url.pathname.startsWith("/api/")) {
      return env.ASSETS.fetch(request);
    }

    // Every /api/ route is scoped to whichever real, signed-in Firebase account made the
    // request — open signup means this is the only thing keeping one user's data private
    // from every other user, not just from the public internet.
    let userId: string;
    const token = extractBearerToken(request);
    if (!token) {
      return new Response("Unauthorized", { status: 401, headers: CORS_HEADERS });
    }
    try {
      userId = await verifyFirebaseToken(token);
    } catch (err) {
      if (err instanceof AuthError) {
        return new Response("Unauthorized", { status: 401, headers: CORS_HEADERS });
      }
      throw err;
    }

    if (url.pathname === "/api/history" && request.method === "GET") {
      const q = url.searchParams.get("q") ?? undefined;
      const mode = url.searchParams.get("mode") ?? undefined;
      const order = url.searchParams.get("order") === "asc" ? "asc" : "desc";
      const cursorParam = url.searchParams.get("cursorId");
      const cursorId = cursorParam ? Number(cursorParam) : undefined;
      const limitParam = Number(url.searchParams.get("limit"));
      const limit = Number.isInteger(limitParam) && limitParam > 0 && limitParam <= 100 ? limitParam : 30;
      const rows = await searchHistory(env.HISTORY_DB, { userId, q, mode, cursorId, order, limit });
      return new Response(JSON.stringify(rows), {
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    if (url.pathname.startsWith("/api/history/") && request.method === "DELETE") {
      const id = Number(url.pathname.slice("/api/history/".length));
      if (!Number.isInteger(id)) {
        return new Response("Invalid id", { status: 400, headers: CORS_HEADERS });
      }
      const imageKey = await deleteHistoryRow(env.HISTORY_DB, userId, id);
      if (imageKey) {
        try {
          await deleteFromB2(env, imageKey);
        } catch (err) {
          console.error("B2 delete failed:", err);
        }
      }
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (url.pathname.startsWith("/api/image/") && request.method === "GET") {
      const key = decodeURIComponent(url.pathname.slice("/api/image/".length));
      if (!key || !(await userOwnsImage(env.HISTORY_DB, userId, key))) {
        return new Response("Not found", { status: 404, headers: CORS_HEADERS });
      }
      const b2Response = await fetchFromB2(env, key);
      if (!b2Response.ok) return new Response("Not found", { status: 404, headers: CORS_HEADERS });
      return new Response(b2Response.body, {
        headers: {
          "Content-Type": b2Response.headers.get("Content-Type") ?? "image/png",
          ...CORS_HEADERS,
        },
      });
    }

    return new Response("Not found", { status: 404, headers: CORS_HEADERS });
  },
};
