import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import {
  getAuth,
  GoogleAuthProvider,
  EmailAuthProvider,
  signInWithPopup,
  getAdditionalUserInfo,
  linkWithCredential,
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  onAuthStateChanged,
  signOut,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";

const firebaseConfig = {
  projectId: "picky-ai",
  appId: "1:466839117567:web:49b511c303b52bd38d76ca",
  storageBucket: "picky-ai.firebasestorage.app",
  apiKey: "AIzaSyBU9P_p_Hqgi8Eo2DeGiRFRKUK1rL94W4g",
  authDomain: "picky-ai.firebaseapp.com",
  messagingSenderId: "466839117567",
};

const firebaseApp = initializeApp(firebaseConfig);
const auth = getAuth(firebaseApp);

const API_BASE = "https://pick-ai-history.byeongminchoi12.workers.dev";

const loginScreen = document.getElementById("loginScreen");
const googleSignInBtn = document.getElementById("googleSignIn");
const loginEmailInput = document.getElementById("loginEmail");
const loginPasswordInput = document.getElementById("loginPassword");
const loginSignInBtn = document.getElementById("loginSignIn");
const loginSignUpBtn = document.getElementById("loginSignUp");
const loginError = document.getElementById("loginError");
const appContent = document.getElementById("appContent");
const accountEmail = document.getElementById("accountEmail");
const signOutBtn = document.getElementById("signOutBtn");
const passwordSetupModal = document.getElementById("passwordSetupModal");
const setupPasswordInput = document.getElementById("setupPassword");
const setupPasswordSubmit = document.getElementById("setupPasswordSubmit");
const setupPasswordSkip = document.getElementById("setupPasswordSkip");
const setupPasswordError = document.getElementById("setupPasswordError");

const grid = document.getElementById("grid");
const emptyEl = document.getElementById("empty");
const errorEl = document.getElementById("errorState");
const retryBtn = document.getElementById("retryBtn");
const loadMoreBtn = document.getElementById("loadMore");
const searchInput = document.getElementById("search");
const filterBtns = document.querySelectorAll(".filter-btn");
const sortSelect = document.getElementById("sortOrder");
const modal = document.getElementById("modal");
const modalClose = document.getElementById("modalClose");
const modalImage = document.getElementById("modalImage");
const modalMeta = document.getElementById("modalMeta");
const modalQuestion = document.getElementById("modalQuestion");
const modalAnswer = document.getElementById("modalAnswer");
const modalDelete = document.getElementById("modalDelete");
const modalDeleteConfirm = document.getElementById("modalDeleteConfirm");
const modalDeleteCancel = document.getElementById("modalDeleteCancel");
const modalDeleteConfirmBtn = document.getElementById("modalDeleteConfirmBtn");

const selectToggleBtn = document.getElementById("selectToggleBtn");
const selectBar = document.getElementById("selectBar");
const selectCount = document.getElementById("selectCount");
const selectBarActions = document.getElementById("selectBarActions");
const selectBarConfirm = document.getElementById("selectBarConfirm");
const selectConfirmText = document.getElementById("selectConfirmText");
const selectAllBtn = document.getElementById("selectAllBtn");
const selectDeleteBtn = document.getElementById("selectDeleteBtn");
const selectCancelBtn = document.getElementById("selectCancelBtn");
const selectDeleteCancelBtn = document.getElementById("selectDeleteCancelBtn");
const selectDeleteConfirmBtn = document.getElementById("selectDeleteConfirmBtn");

// Inline "broken image" placeholder (small gray square) — used instead of the
// browser's default broken-image icon when a screenshot fails to load.
const IMAGE_FALLBACK =
  "data:image/svg+xml;charset=UTF-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='260' height='120'%3E%3Crect width='100%25' height='100%25' fill='%23808080' opacity='0.15'/%3E%3Ctext x='50%25' y='50%25' text-anchor='middle' dy='.3em' fill='%23808080' font-family='sans-serif' font-size='13'%3EImage unavailable%3C/text%3E%3C/svg%3E";

let currentMode = "";
let currentQuery = "";
let currentOrder = "desc";
let lastId;
let debounceTimer = null;
let activeEntryId = null;
let selectMode = false;
const selectedIds = new Set();

// Every API call fetches the current ID token fresh — the Firebase SDK transparently
// refreshes it under the hood when it's close to expiring, so this never uses a stale token.
async function apiFetch(path, options = {}) {
  const user = auth.currentUser;
  if (!user) throw new Error("Not signed in");
  const token = await user.getIdToken();
  return fetch(`${API_BASE}${path}`, {
    ...options,
    headers: { ...(options.headers ?? {}), Authorization: `Bearer ${token}` },
  });
}

function showLogin() {
  appContent.hidden = true;
  loginScreen.hidden = false;
}

function showApp(user) {
  loginScreen.hidden = true;
  appContent.hidden = false;
  accountEmail.textContent = user.email ?? "";
  loadEntries(true);
}

function showLoginError(message) {
  loginError.hidden = false;
  loginError.textContent = message;
}

googleSignInBtn.addEventListener("click", async () => {
  loginError.hidden = true;
  try {
    const result = await signInWithPopup(auth, new GoogleAuthProvider());
    // Google accounts have no password by default — prompt once, right after the first
    // sign-up, so they can also use the Mac app (which only supports email/password).
    if (getAdditionalUserInfo(result)?.isNewUser) {
      passwordSetupModal.hidden = false;
    }
  } catch (err) {
    showLoginError("Google sign-in failed — try again.");
  }
});

setupPasswordSubmit.addEventListener("click", async () => {
  setupPasswordError.hidden = true;
  const password = setupPasswordInput.value;
  if (password.length < 6) {
    setupPasswordError.hidden = false;
    setupPasswordError.textContent = "Password must be at least 6 characters.";
    return;
  }
  try {
    const credential = EmailAuthProvider.credential(auth.currentUser.email, password);
    await linkWithCredential(auth.currentUser, credential);
    passwordSetupModal.hidden = true;
    setupPasswordInput.value = "";
  } catch (err) {
    setupPasswordError.hidden = false;
    setupPasswordError.textContent = "Couldn't set password — try again.";
  }
});

setupPasswordSkip.addEventListener("click", () => {
  passwordSetupModal.hidden = true;
  setupPasswordInput.value = "";
  setupPasswordError.hidden = true;
});

loginSignInBtn.addEventListener("click", async () => {
  loginError.hidden = true;
  try {
    await signInWithEmailAndPassword(auth, loginEmailInput.value.trim(), loginPasswordInput.value);
  } catch (err) {
    showLoginError("Wrong email or password.");
  }
});

loginSignUpBtn.addEventListener("click", async () => {
  loginError.hidden = true;
  try {
    await createUserWithEmailAndPassword(auth, loginEmailInput.value.trim(), loginPasswordInput.value);
  } catch (err) {
    showLoginError(err.code === "auth/weak-password" ? "Password must be at least 6 characters." : "Couldn't create account — check the email and try again.");
  }
});

signOutBtn.addEventListener("click", () => signOut(auth));

onAuthStateChanged(auth, (user) => {
  if (user) {
    showApp(user);
  } else {
    showLogin();
  }
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
  card.dataset.id = String(entry.id);
  card.innerHTML = `
    <input type="checkbox" class="card-checkbox" ${selectMode ? "" : "hidden"} />
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
  const checkbox = card.querySelector(".card-checkbox");
  checkbox.addEventListener("click", (e) => e.stopPropagation());
  checkbox.addEventListener("change", () => toggleSelect(entry.id, checkbox.checked));
  card.addEventListener("click", () => {
    if (selectMode) {
      checkbox.checked = !checkbox.checked;
      toggleSelect(entry.id, checkbox.checked);
    } else {
      openModal(entry);
    }
  });
  return card;
}

// Images need the same bearer-token auth as /api/history, so a plain <img src> can't be
// used directly — fetch with the header and swap in a blob URL.
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
  activeEntryId = entry.id;
  modalImage.hidden = !entry.image_key;
  if (entry.image_key) {
    loadAuthedImage(entry.image_key).then((url) => { modalImage.src = url; });
  }
  modalMeta.textContent = `${entry.mode} · ${formatTime(entry.created_at)}`;
  modalQuestion.textContent = entry.question || "(screenshot)";
  modalAnswer.textContent = entry.answer;
  resetDeleteConfirm();
  modal.hidden = false;
}

function closeModal() {
  modal.hidden = true;
  activeEntryId = null;
  resetDeleteConfirm();
}

function resetDeleteConfirm() {
  modalDelete.hidden = false;
  modalDeleteConfirm.hidden = true;
}

modalClose.addEventListener("click", closeModal);
modal.addEventListener("click", (e) => {
  if (e.target === modal) closeModal();
});

modalDelete.addEventListener("click", () => {
  modalDelete.hidden = true;
  modalDeleteConfirm.hidden = false;
});

modalDeleteCancel.addEventListener("click", resetDeleteConfirm);

modalDeleteConfirmBtn.addEventListener("click", async () => {
  if (activeEntryId === null) return;
  modalDeleteConfirmBtn.disabled = true;
  try {
    const res = await apiFetch(`/api/history/${activeEntryId}`, { method: "DELETE" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const card = grid.querySelector(`.card[data-id="${activeEntryId}"]`);
    if (card) card.remove();
    closeModal();
    if (!grid.children.length) emptyEl.hidden = false;
  } catch (err) {
    modalDeleteConfirmBtn.disabled = false;
    alert("Couldn't delete — try again.");
  }
});

function toggleSelect(id, isSelected) {
  if (isSelected) selectedIds.add(id);
  else selectedIds.delete(id);
  const card = grid.querySelector(`.card[data-id="${id}"]`);
  if (card) card.classList.toggle("selected", isSelected);
  selectCount.textContent = `${selectedIds.size} selected`;
  selectDeleteBtn.disabled = selectedIds.size === 0;
}

function setSelectMode(on) {
  selectMode = on;
  selectBar.hidden = !on;
  selectBarActions.hidden = false;
  selectBarConfirm.hidden = true;
  selectedIds.clear();
  grid.querySelectorAll(".card").forEach((card) => {
    card.classList.remove("selected");
    const cb = card.querySelector(".card-checkbox");
    if (cb) {
      cb.checked = false;
      cb.hidden = !on;
    }
  });
  selectCount.textContent = "0 selected";
  selectDeleteBtn.disabled = true;
}

selectToggleBtn.addEventListener("click", () => setSelectMode(true));
selectCancelBtn.addEventListener("click", () => setSelectMode(false));

selectAllBtn.addEventListener("click", () => {
  grid.querySelectorAll(".card").forEach((card) => {
    const id = Number(card.dataset.id);
    const cb = card.querySelector(".card-checkbox");
    cb.checked = true;
    card.classList.add("selected");
    selectedIds.add(id);
  });
  selectCount.textContent = `${selectedIds.size} selected`;
  selectDeleteBtn.disabled = selectedIds.size === 0;
});

selectDeleteBtn.addEventListener("click", () => {
  if (selectedIds.size === 0) return;
  selectBarActions.hidden = true;
  selectBarConfirm.hidden = false;
  selectConfirmText.textContent = `Delete ${selectedIds.size} item${selectedIds.size === 1 ? "" : "s"}?`;
});

selectDeleteCancelBtn.addEventListener("click", () => {
  selectBarConfirm.hidden = true;
  selectBarActions.hidden = false;
});

selectDeleteConfirmBtn.addEventListener("click", async () => {
  selectDeleteConfirmBtn.disabled = true;
  const ids = [...selectedIds];
  const results = await Promise.allSettled(
    ids.map((id) => apiFetch(`/api/history/${id}`, { method: "DELETE" }))
  );
  let failedCount = 0;
  results.forEach((result, i) => {
    const ok = result.status === "fulfilled" && result.value.ok;
    if (ok) {
      const card = grid.querySelector(`.card[data-id="${ids[i]}"]`);
      if (card) card.remove();
      selectedIds.delete(ids[i]);
    } else {
      failedCount += 1;
    }
  });
  selectDeleteConfirmBtn.disabled = false;
  if (failedCount > 0) {
    alert(`Couldn't delete ${failedCount} item(s) — try again.`);
    selectBarConfirm.hidden = true;
    selectBarActions.hidden = false;
    selectCount.textContent = `${selectedIds.size} selected`;
    selectDeleteBtn.disabled = selectedIds.size === 0;
  } else {
    setSelectMode(false);
    if (!grid.children.length) emptyEl.hidden = false;
  }
});

let latestKnownId;

async function loadEntries(reset) {
  if (reset) {
    grid.innerHTML = "";
    lastId = undefined;
    setSelectMode(false);
  }
  errorEl.hidden = true;

  const params = new URLSearchParams();
  if (currentQuery) params.set("q", currentQuery);
  if (currentMode) params.set("mode", currentMode);
  params.set("order", currentOrder);
  if (lastId !== undefined) params.set("cursorId", String(lastId));

  let rows;
  try {
    const res = await apiFetch(`/api/history?${params.toString()}`);
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
  // Live-update polling only tracks "newer than the top of the default view" — only
  // meaningful right after a from-scratch load of that exact view (see pollForNewEntries).
  if (reset && currentOrder === "desc" && !currentQuery && !currentMode && rows.length > 0) {
    latestKnownId = rows[0].id;
  }
  loadMoreBtn.hidden = rows.length < 30;
}

// Polls for entries newer than the top of the list and prepends them quietly, without
// disturbing scroll position, search text, or filters — only runs on the default
// newest-first/unfiltered view, where "what's new" is unambiguous. A full WebSocket/push
// setup would be overkill for this at personal scale; a short poll is imperceptible.
async function pollForNewEntries() {
  if (latestKnownId === undefined || currentQuery || currentMode || currentOrder !== "desc") return;
  if (!auth.currentUser) return;
  try {
    const res = await apiFetch("/api/history?order=desc&limit=30");
    if (!res.ok) return;
    const rows = await res.json();
    const newRows = rows.filter((r) => r.id > latestKnownId);
    if (newRows.length === 0) return;
    for (const entry of newRows.reverse()) {
      grid.insertBefore(renderCard(entry), grid.firstChild);
    }
    latestKnownId = Math.max(latestKnownId, ...newRows.map((r) => r.id));
    emptyEl.hidden = true;
  } catch {
    // Silent — a failed poll just tries again next interval.
  }
}

setInterval(pollForNewEntries, 8000);

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

sortSelect.addEventListener("change", () => {
  currentOrder = sortSelect.value;
  loadEntries(true);
});
