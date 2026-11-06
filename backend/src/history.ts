export interface HistoryEnv {
  HISTORY_DB: D1Database;
}

export interface HistoryEntry {
  mode: string;
  question: string | null;
  answer: string;
  imageKey: string | null;
}

// The mac app is the only writer of new history (per the "AI feature stays as-is, just for
// me" decision) — every entry it creates belongs to this one account.
const OWNER_UID = "XnQcqKAiuNXooC61g2kNIumpDS02";

export async function recordHistory(env: HistoryEnv, entry: HistoryEntry): Promise<void> {
  await env.HISTORY_DB.prepare(
    "INSERT INTO history (created_at, mode, question, answer, image_key, user_id) VALUES (?, ?, ?, ?, ?, ?)"
  )
    .bind(new Date().toISOString(), entry.mode, entry.question, entry.answer, entry.imageKey, OWNER_UID)
    .run();
}
