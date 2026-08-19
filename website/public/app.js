const API_BASE = "https://pick-ai-history.byeongminchoi12.workers.dev";
const STORAGE_KEY = "historyAccessKey";

const loginScreen = document.getElementById("loginScreen");
const loginKeyInput = document.getElementById("loginKey");
const loginSubmit = document.getElementById("loginSubmit");
const loginError = document.getElementById("loginError");
const appContent = document.getElementById("appContent");

const grid = document.getElementById("grid");
const emptyEl = document.getElementById("empty");
const errorEl = document.getElementById("errorState");
const retryBtn = document.getElementById("retryBtn");
const loadMoreBtn = document.getElementById("loadMore");
const searchInput = document.getElementById("search");
const filterBtns = document.querySelectorAll(".filter-btn");
const modal = document.getElementById("modal");
const modalClose = document.getElementById("modalClose");
const modalImage = document.getElementById("modalImage");
const modalMeta = document.getElementById("modalMeta");
const modalQuestion = document.getElementById("modalQuestion");
const modalAnswer = document.getElementById("modalAnswer");

// Inline "broken image" placeholder (small gray square) — used instead of the
// browser's default broken-image icon when a screenshot fails to load.
const IMAGE_FALLBACK =
  "data:image/svg+xml;charset=UTF-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='260' height='120'%3E%3Crect width='100%25' height='100%25' fill='%23808080' opacity='0.15'/%3E%3Ctext x='50%25' y='50%25' text-anchor='middle' dy='.3em' fill='%23808080' font-family='sans-serif' font-size='13'%3EImage unavailable%3C/text%3E%3C/svg%3E";

let currentMode = "";
let currentQuery = "";
let lastId;
let debounceTimer = null;

function accessKey() {
  return localStorage.getItem(STORAGE_KEY);
}

function apiFetch(path) {
  return fetch(`${API_BASE}${path}`, {
    headers: { "X-History-Key": accessKey() ?? "" },
  });
}

function showLogin(message) {
  appContent.hidden = true;
  loginScreen.hidden = false;
  loginError.hidden = !message;
  if (message) loginError.textContent = message;
}

function showApp() {
  loginScreen.hidden = true;
  appContent.hidden = false;
}

async function trySavedKeyOrShowLogin() {
  if (!accessKey()) {
    showLogin();
    return;
  }
  // Verify the stored key still works before committing to showing the app —
  // an old/revoked key should bounce back to the login screen, not a blank app.
  const res = await apiFetch("/api/history?limit=1");
  if (res.status === 401) {
    localStorage.removeItem(STORAGE_KEY);
    showLogin("Saved key no longer works — enter it again.");
    return;
  }
  showApp();
  loadEntries(true);
}

loginSubmit.addEventListener("click", async () => {
  const key = loginKeyInput.value.trim();
  if (!key) return;
  localStorage.setItem(STORAGE_KEY, key);
  const res = await apiFetch("/api/history?limit=1");
  if (res.status === 401) {
    localStorage.removeItem(STORAGE_KEY);
    loginError.hidden = false;
    loginError.textContent = "Wrong key — try again.";
    return;
  }
  showApp();
  loadEntries(true);
});

loginKeyInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") loginSubmit.click();
});

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function formatTime(iso) {
  return new Date(iso).toLocaleString();
}

function renderCard(entry) {
  const card = document.createElement("div");
  card.className = "card";
  card.innerHTML = `
    ${entry.image_key ? `<img loading="lazy" />` : ""}
    <div class="card-meta">
      <span class="badge ${entry.mode}">${entry.mode}</span>
      <span>${formatTime(entry.created_at)}</span>
    </div>
    <p class="card-question">${escapeHtml(entry.question || "(screenshot)")}</p>
    <p class="card-answer">${escapeHtml(entry.answer)}</p>
  `;
  const img = card.querySelector("img");
  if (img) {
    img.addEventListener("error", () => { img.src = IMAGE_FALLBACK; }, { once: true });
    loadAuthedImage(entry.image_key).then((url) => { img.src = url; });
  }
  card.addEventListener("click", () => openModal(entry));
  return card;
}

// Images need the access-key header too (same auth as /api/history), so a plain
// <img src> can't be used directly — fetch with the header and swap in a blob URL.
async function loadAuthedImage(key) {
  try {
    const res = await apiFetch(`/api/image/${encodeURIComponent(key)}`);
    if (!res.ok) return IMAGE_FALLBACK;
    const blob = await res.blob();
    return URL.createObjectURL(blob);
  } catch {
    return IMAGE_FALLBACK;
  }
}

function openModal(entry) {
  modalImage.hidden = !entry.image_key;
  if (entry.image_key) {
    loadAuthedImage(entry.image_key).then((url) => { modalImage.src = url; });
  }
  modalMeta.textContent = `${entry.mode} · ${formatTime(entry.created_at)}`;
  modalQuestion.textContent = entry.question || "(screenshot)";
  modalAnswer.textContent = entry.answer;
  modal.hidden = false;
}

modalClose.addEventListener("click", () => { modal.hidden = true; });
modal.addEventListener("click", (e) => {
  if (e.target === modal) modal.hidden = true;
});

async function loadEntries(reset) {
  if (reset) {
    grid.innerHTML = "";
    lastId = undefined;
  }
  errorEl.hidden = true;

  const params = new URLSearchParams();
  if (currentQuery) params.set("q", currentQuery);
  if (currentMode) params.set("mode", currentMode);
  if (lastId !== undefined) params.set("beforeId", String(lastId));

  let rows;
  try {
    const res = await apiFetch(`/api/history?${params.toString()}`);
    if (res.status === 401) {
      localStorage.removeItem(STORAGE_KEY);
      showLogin("Session expired — enter your key again.");
      return;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    rows = await res.json();
  } catch (err) {
    errorEl.hidden = false;
    emptyEl.hidden = true;
    loadMoreBtn.hidden = true;
    return;
  }

  if (rows.length === 0 && reset) {
    emptyEl.hidden = false;
    loadMoreBtn.hidden = true;
    return;
  }
  emptyEl.hidden = true;

  for (const entry of rows) {
    grid.appendChild(renderCard(entry));
  }

  if (rows.length > 0) {
    lastId = rows[rows.length - 1].id;
  }
  loadMoreBtn.hidden = rows.length < 30;
}

retryBtn.addEventListener("click", () => loadEntries(true));

searchInput.addEventListener("input", () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    currentQuery = searchInput.value.trim();
    loadEntries(true);
  }, 250);
});

filterBtns.forEach((btn) => {
  btn.addEventListener("click", () => {
    filterBtns.forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    currentMode = btn.dataset.mode;
    loadEntries(true);
  });
});

loadMoreBtn.addEventListener("click", () => loadEntries(false));

trySavedKeyOrShowLogin();
