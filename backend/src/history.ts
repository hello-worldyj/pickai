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
