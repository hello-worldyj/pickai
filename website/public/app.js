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
    ${entry.image_key ? `<img src="/api/image/${encodeURIComponent(entry.image_key)}" loading="lazy" />` : ""}
    <div class="card-meta">
      <span class="badge ${entry.mode}">${entry.mode}</span>
      <span>${formatTime(entry.created_at)}</span>
    </div>
    <p class="card-question">${escapeHtml(entry.question || "(screenshot)")}</p>
    <p class="card-answer">${escapeHtml(entry.answer)}</p>
  `;
  const img = card.querySelector("img");
  if (img) img.addEventListener("error", () => { img.src = IMAGE_FALLBACK; }, { once: true });
  card.addEventListener("click", () => openModal(entry));
  return card;
}

function openModal(entry) {
  modalImage.hidden = !entry.image_key;
  if (entry.image_key) {
    modalImage.src = `/api/image/${encodeURIComponent(entry.image_key)}`;
    modalImage.addEventListener("error", () => { modalImage.src = IMAGE_FALLBACK; }, { once: true });
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
    const res = await fetch(`/api/history?${params.toString()}`);
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

loadEntries(true);
