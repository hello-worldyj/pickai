export interface HistoryRow {
  id: number;
  created_at: string;
  mode: string;
  question: string | null;
  answer: string;
  image_key: string | null;
}

export type SortOrder = "asc" | "desc";

export interface SearchParams {
  userId: string;
  q?: string;
  mode?: string;
  cursorId?: number;
  order: SortOrder;
  limit: number;
}

export async function searchHistory(db: D1Database, params: SearchParams): Promise<HistoryRow[]> {
  const conditions: string[] = ["user_id = ?"];
  const bindings: unknown[] = [params.userId];

  if (params.q) {
    conditions.push("(question LIKE ? OR answer LIKE ?)");
    const like = `%${params.q}%`;
    bindings.push(like, like);
  }
  if (params.mode) {
    conditions.push("mode = ?");
    bindings.push(params.mode);
  }
  if (params.cursorId !== undefined) {
    // Which side of the cursor "more" means depends on sort direction: newest-first
    // pages downward through smaller ids, oldest-first pages upward through larger ones.
    conditions.push(params.order === "asc" ? "id > ?" : "id < ?");
    bindings.push(params.cursorId);
  }

  const where = `WHERE ${conditions.join(" AND ")}`;
  const orderSql = params.order === "asc" ? "ASC" : "DESC";
  const sql = `SELECT id, created_at, mode, question, answer, image_key FROM history ${where} ORDER BY id ${orderSql} LIMIT ?`;
  bindings.push(params.limit);

  const result = await db.prepare(sql).bind(...bindings).all<HistoryRow>();
  return result.results ?? [];
}

/**
 * Deletes the row (scoped to the owning user — a stranger's id guess can't delete someone
 * else's entry) and returns its image_key, if any, so the caller can also remove it from B2.
 */
export async function deleteHistoryRow(db: D1Database, userId: string, id: number): Promise<string | null> {
  const result = await db
    .prepare("DELETE FROM history WHERE id = ? AND user_id = ? RETURNING image_key")
    .bind(id, userId)
    .first<{ image_key: string | null }>();
  return result?.image_key ?? null;
}

/**
 * True only if the given image_key belongs to a row owned by userId — B2 keys are just
 * filenames with no built-in ownership, so without this check any authenticated user could
 * fetch any other user's screenshot just by guessing/observing a key.
 */
export async function userOwnsImage(db: D1Database, userId: string, imageKey: string): Promise<boolean> {
  const result = await db
    .prepare("SELECT 1 FROM history WHERE image_key = ? AND user_id = ? LIMIT 1")
    .bind(imageKey, userId)
    .first();
  return result !== null;
}
