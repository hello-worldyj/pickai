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
