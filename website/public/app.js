import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import {
  getAuth,
  GoogleAuthProvider,
  signInWithPopup,
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
    await signInWithPopup(auth, new GoogleAuthProvider());
  } catch (err) {
    showLoginError("Google sign-in failed — try again.");
  }
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

async function loadEntries(reset) {
  if (reset) {
    grid.innerHTML = "";
    lastId = undefined;
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

sortSelect.addEventListener("change", () => {
  currentOrder = sortSelect.value;
  loadEntries(true);
});
