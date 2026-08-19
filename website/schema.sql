CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    mode TEXT NOT NULL,
    question TEXT,
    answer TEXT NOT NULL,
    image_key TEXT
);
