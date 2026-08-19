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
  q?: string;
  mode?: string;
  cursorId?: number;
  order: SortOrder;
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
  if (params.cursorId !== undefined) {
    // Which side of the cursor "more" means depends on sort direction: newest-first
    // pages downward through smaller ids, oldest-first pages upward through larger ones.
    conditions.push(params.order === "asc" ? "id > ?" : "id < ?");
    bindings.push(params.cursorId);
  }

  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const orderSql = params.order === "asc" ? "ASC" : "DESC";
  const sql = `SELECT id, created_at, mode, question, answer, image_key FROM history ${where} ORDER BY id ${orderSql} LIMIT ?`;
  bindings.push(params.limit);

  const result = await db.prepare(sql).bind(...bindings).all<HistoryRow>();
  return result.results ?? [];
}

/** Deletes the row and returns its image_key (if any) so the caller can also remove it from B2. */
export async function deleteHistoryRow(db: D1Database, id: number): Promise<string | null> {
  const result = await db
    .prepare("DELETE FROM history WHERE id = ? RETURNING image_key")
    .bind(id)
    .first<{ image_key: string | null }>();
  return result?.image_key ?? null;
}
