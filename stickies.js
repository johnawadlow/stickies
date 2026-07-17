const COLS = [
  { id: 'todo',       name: 'To Do' },
  { id: 'inprogress', name: 'In Progress' },
  { id: 'done',       name: 'Done' },
];
const DEFAULTS = ['#388bfd','#3fb950','#d29922','#f78166','#bc8cff','#e3b341'];

// ── State ──────────────────────────────────────
let state = { projects: [], view: 'all' };

let addCardCtx = null; // { projectId, col, cardId? } — cardId present means edit mode
let dragging   = null; // { id, fromCol, projectId }
let ghost      = null;
let wasDragging = false;

// ── Lock state ─────────────────────────────────
// Blocks ops until the board has loaded the current DB contents from the
// server. Doubles as the error surface when the server is unreachable.
let locked = true;

function showLock() {
  locked = true;
  const ov = document.getElementById('lock-overlay');
  if (ov) ov.classList.add('open');
}

function hideLock() {
  locked = false;
  const ov = document.getElementById('lock-overlay');
  if (ov) ov.classList.remove('open');
}

// ── Color math ─────────────────────────────────
function hsvToRgb(h, s, v) {
  const i = Math.floor(h / 60) % 6;
  const f = h / 60 - Math.floor(h / 60);
  const p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  const [r, g, b] = [[v,t,p],[q,v,p],[p,v,t],[p,q,v],[t,p,v],[v,p,q]][i];
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}

function rgbToHex(r, g, b) {
  return '#' + [r, g, b].map(n => n.toString(16).padStart(2, '0')).join('');
}

function hexToHsv(hex) {
  const r = parseInt(hex.slice(1,3),16)/255;
  const g = parseInt(hex.slice(3,5),16)/255;
  const b = parseInt(hex.slice(5,7),16)/255;
  const max = Math.max(r,g,b), min = Math.min(r,g,b), d = max - min;
  let h = 0;
  if (d) {
    if (max === r)      h = ((g - b) / d + (g < b ? 6 : 0)) * 60;
    else if (max === g) h = ((b - r) / d + 2) * 60;
    else                h = ((r - g) / d + 4) * 60;
  }
  return [h, max ? d / max : 0, max];
}

// ── Color picker ───────────────────────────────
let cpH = 214, cpS = 0.78, cpV = 0.99;

function cpHex() { return rgbToHex(...hsvToRgb(cpH, cpS, cpV)); }

function cpSync(skipHex = false) {
  const hex = cpHex();
  document.getElementById('cp-sq').style.background =
    `linear-gradient(to right, #fff, hsl(${cpH},100%,50%))`;
  document.getElementById('cp-cur').style.left  = (cpS * 100) + '%';
  document.getElementById('cp-cur').style.top   = ((1 - cpV) * 100) + '%';
  document.getElementById('cp-hue-th').style.left       = (cpH / 360 * 100) + '%';
  document.getElementById('cp-hue-th').style.background = `hsl(${cpH},100%,50%)`;
  document.getElementById('cp-prev').style.background   = hex;
  if (!skipHex) document.getElementById('cp-hex').value = hex;
}

function initPicker(hex) {
  [cpH, cpS, cpV] = hexToHsv(hex);
  cpSync();
}

// Drag state for the picker controls
let sqDrag = false, hueDrag = false;

function sqPick(e) {
  const r = document.getElementById('cp-sq').getBoundingClientRect();
  const p = e.touches ? e.touches[0] : e;
  cpS = Math.max(0, Math.min(1, (p.clientX - r.left)  / r.width));
  cpV = 1 - Math.max(0, Math.min(1, (p.clientY - r.top) / r.height));
  cpSync();
}

function huePick(e) {
  const r = document.getElementById('cp-hue').getBoundingClientRect();
  const p = e.touches ? e.touches[0] : e;
  cpH = Math.max(0, Math.min(360, ((p.clientX - r.left) / r.width) * 360));
  cpSync();
}

document.getElementById('cp-sq').addEventListener('mousedown',  e => { sqDrag  = true; sqPick(e); });
document.getElementById('cp-hue').addEventListener('mousedown', e => { hueDrag = true; huePick(e); });
document.getElementById('cp-sq').addEventListener('touchstart',  e => { sqDrag  = true; sqPick(e);  e.preventDefault(); }, { passive: false });
document.getElementById('cp-hue').addEventListener('touchstart', e => { hueDrag = true; huePick(e); e.preventDefault(); }, { passive: false });

document.addEventListener('mousemove', e => { if (sqDrag) sqPick(e); if (hueDrag) huePick(e); });
document.addEventListener('mouseup',   () => { sqDrag = false; hueDrag = false; });
document.addEventListener('touchmove', e => {
  if (sqDrag)  { sqPick(e);  e.preventDefault(); }
  if (hueDrag) { huePick(e); e.preventDefault(); }
}, { passive: false });
document.addEventListener('touchend', () => { sqDrag = false; hueDrag = false; });

document.getElementById('cp-hex').addEventListener('input', e => {
  const v = e.target.value.trim();
  if (/^#[0-9a-fA-F]{6}$/.test(v)) {
    [cpH, cpS, cpV] = hexToHsv(v);
    cpSync(true);
  }
});

// ── Persistence ────────────────────────────────
// The board is served by start-stickies.ps1, which owns stickies.db (kb-t20).
// Reads fetch the whole board from GET /data; every mutation POSTs one op to
// /op, where it runs as a single transaction and writes an audit row. Local
// state is updated optimistically before the op is sent; if an op fails the
// board reloads from the DB so the two can't stay diverged.

async function sendOp(op) {
  if (locked) return;
  let res;
  try {
    res = await fetch('/op', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(op),
    });
  } catch(err) {
    alert('Save failed — is the Stickies server still running?\n' + (err.message || err));
    reloadBoard();
    return;
  }
  if (!res.ok) {
    alert('The server rejected this change, so the board will reload without it.\n' + ((await res.text()) || 'HTTP ' + res.status));
    reloadBoard();
  }
}

async function loadData() {
  let res;
  try {
    res = await fetch('/data', { cache: 'no-store' });
  } catch(_) {
    return { ok: false, error: 'Could not reach the Stickies server.\nRun start-stickies.ps1 to serve the board.' };
  }
  if (!res.ok) {
    return { ok: false, error: 'Server returned HTTP ' + res.status + ' for /data.' };
  }
  let parsed;
  try {
    parsed = JSON.parse(await res.text());
  } catch(parseErr) {
    return { ok: false, error: 'Could not parse the /data response:\n' + parseErr.message };
  }
  if (!Array.isArray(parsed.projects)) {
    return { ok: false, error: 'The /data response is missing the top-level "projects" array.' };
  }
  state = parsed;
  render();
  return { ok: true };
}

async function reloadBoard() {
  const result = await loadData();
  if (!result.ok && result.error) alert('Reload failed:\n' + result.error);
}

async function exportData() {
  try {
    const fh = await window.showSaveFilePicker({
      suggestedName: 'stickies-export.json',
      types: [{ description: 'JSON', accept: { 'application/json': ['.json'] } }],
    });
    const writable = await fh.createWritable();
    await writable.write(JSON.stringify(state, null, 2));
    await writable.close();
  } catch(e) {
    if (e.name !== 'AbortError') console.error(e);
  }
}

async function importData() {
  try {
    const [fh] = await window.showOpenFilePicker({
      types: [{ description: 'JSON', accept: { 'application/json': ['.json'] } }],
    });
    const file = await fh.getFile();
    const imported = JSON.parse(await file.text());
    if (!Array.isArray(imported.projects)) throw new Error('Invalid kanban JSON');
    const existingIds = new Set(state.projects.map(p => p.id));
    const newProjects = imported.projects.filter(p => !existingIds.has(p.id));
    state.projects.push(...newProjects);
    sendOp({ kind: 'project-import', projects: newProjects });
    render();
  } catch(e) {
    if (e.name !== 'AbortError') alert('Import failed: ' + e.message);
  }
}

// ── Utilities ──────────────────────────────────
function esc(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function uid() {
  return typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : Math.random().toString(36).slice(2) + Date.now().toString(36);
}


// ── Render ─────────────────────────────────────
function render() {
  renderSidebar();
  renderMain();
}

function renderSidebar() {
  const allBtn = document.getElementById('nav-all');
  allBtn.className = 'nav-item' + (state.view === 'all' ? ' active' : '');

  const nav = document.getElementById('projects-nav');
  nav.innerHTML = '';

  state.projects.forEach(proj => {
    const btn = document.createElement('button');
    btn.className = 'nav-item' + (state.view === proj.id ? ' active' : '');
    btn.innerHTML = `
      <span class="proj-dot" style="background:${proj.color}"></span>
      <span class="proj-name">${esc(proj.name)}</span>
      <button class="del-proj" aria-label="Delete ${esc(proj.name)}" data-pid="${esc(proj.id)}">×</button>
    `;
    btn.addEventListener('click', e => {
      if (e.target.closest('.del-proj')) return;
      setView(proj.id);
    });
    btn.querySelector('.del-proj').addEventListener('click', e => {
      e.stopPropagation();
      deleteProject(proj.id);
    });
    nav.appendChild(btn);
  });
}

function renderMain() {
  const area    = document.getElementById('board-area');
  const titleEl = document.getElementById('header-title');
  const dotEl   = document.getElementById('header-dot');
  const editBtn = document.getElementById('header-edit-btn');

  if (state.view === 'all') {
    titleEl.textContent = 'All Projects';
    dotEl.style.display = 'none';
    editBtn.style.display = 'none';

    if (state.projects.length === 0) {
      area.innerHTML = '';
      area.appendChild(buildEmptyState());
      return;
    }

    area.innerHTML = '';
    const wrap = document.createElement('div');
    wrap.className = 'all-view';
    state.projects.forEach(proj => wrap.appendChild(buildSection(proj)));
    area.appendChild(wrap);

  } else {
    const proj = state.projects.find(p => p.id === state.view);
    if (!proj) { setView('all'); return; }

    titleEl.textContent = proj.name;
    dotEl.style.background = proj.color;
    dotEl.style.display = 'block';
    editBtn.style.display = 'flex';
    editBtn.onclick = () => openProjModal(proj.id);

    area.innerHTML = '';
    const board = document.createElement('div');
    board.className = 'board';
    COLS.forEach(({ id, name }) => board.appendChild(buildColumn(proj, id, name)));
    area.appendChild(board);
  }
}

function buildSection(proj) {
  const section = document.createElement('div');
  section.className = 'project-section';
  const head = document.createElement('div');
  head.className = 'section-head';
  head.innerHTML = `
    <span class="section-dot" style="background:${proj.color}"></span>
    <span class="section-name">${esc(proj.name)}</span>
  `;
  const board = document.createElement('div');
  board.className = 'board';
  COLS.forEach(({ id, name }) => board.appendChild(buildColumn(proj, id, name)));
  section.appendChild(head);
  section.appendChild(board);
  return section;
}

function buildColumn(proj, colId, colName) {
  const col = document.createElement('div');
  col.className = 'column';
  col.dataset.col = colId;
  col.dataset.project = proj.id;

  const cards = proj.board[colId];

  col.innerHTML = `
    <div class="col-head">
      <div class="col-label">
        <div class="col-dot"></div>
        <span class="col-name">${colName}</span>
      </div>
      <span class="col-count">${cards.length}</span>
    </div>
  `;

  const wrap = document.createElement('div');
  wrap.className = 'cards-wrap';
  cards.forEach(card => wrap.appendChild(buildCard(card, colId, proj.id)));
  col.appendChild(wrap);

  const addBtn = document.createElement('button');
  addBtn.className = 'add-card-btn';
  addBtn.innerHTML = `
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round">
      <line x1="5" y1="1" x2="5" y2="9"/>
      <line x1="1" y1="5" x2="9" y2="5"/>
    </svg>
    Add sticky
  `;
  addBtn.addEventListener('click', () => openCardModal(proj.id, colId));
  col.appendChild(addBtn);

  return col;
}

function buildCard(card, col, projectId) {
  const el = document.createElement('div');
  el.className = 'card';
  el.draggable = true;
  el.dataset.id = card.id;
  el.dataset.col = col;
  el.dataset.project = projectId;
  el.innerHTML = `
    <div class="card-title"><span class="card-id">${esc(card.id)}</span> · ${esc(card.title)}</div>
    ${card.desc ? `<div class="card-desc">${esc(card.desc)}</div>` : ''}
    ${card.notes ? `<div class="card-notes-badge">
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round">
        <line x1="1" y1="2.5" x2="9" y2="2.5"/><line x1="1" y1="5" x2="7" y2="5"/><line x1="1" y1="7.5" x2="8" y2="7.5"/>
      </svg>
      notes
    </div>` : ''}
    <button class="card-del" aria-label="Delete sticky">×</button>
  `;
  el.querySelector('.card-del').addEventListener('click', e => {
    e.stopPropagation();
    openConfirm(`Delete "${card.title}"?`, () => {
      const proj = state.projects.find(p => p.id === projectId);
      proj.board[col] = proj.board[col].filter(c => c.id !== card.id);
      sendOp({ kind: 'card-delete', cardId: card.id });
      render();
    });
  });
  el.addEventListener('click', e => {
    if (e.target.closest('.card-del') || wasDragging) return;
    openCardEditModal(card, col, projectId);
  });
  el.addEventListener('dragstart', onDragStart);
  el.addEventListener('dragend', onDragEnd);
  return el;
}

function buildEmptyState() {
  const div = document.createElement('div');
  div.className = 'empty-state';
  div.innerHTML = `
    <svg width="56" height="56" viewBox="0 0 56 56" fill="none" stroke="#388bfd" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <rect x="4" y="8" width="14" height="40" rx="2.5"/>
      <rect x="21" y="8" width="14" height="26" rx="2.5"/>
      <rect x="38" y="8" width="14" height="18" rx="2.5"/>
    </svg>
    <p>No projects yet</p>
    <small>Click "New Project" in the sidebar to get started</small>
  `;
  return div;
}

// ── View ───────────────────────────────────────
function setView(v) {
  state.view = v;
  sendOp({ kind: 'view-set', view: v });
  render();
}

// ── Drag & Drop ────────────────────────────────
function onDragStart(e) {
  wasDragging = true;
  const el = e.currentTarget;
  dragging = { id: el.dataset.id, fromCol: el.dataset.col, projectId: el.dataset.project };
  el.classList.add('dragging');
  e.dataTransfer.effectAllowed = 'move';
  ghost = document.createElement('div');
  ghost.className = 'drop-ghost';
}

function onDragEnd(e) {
  e.currentTarget.classList.remove('dragging');
  ghost?.parentNode?.removeChild(ghost);
  document.querySelectorAll('.column.drag-over').forEach(c => c.classList.remove('drag-over'));
  dragging = null;
  ghost = null;
  setTimeout(() => { wasDragging = false; }, 0);
}

// Returns the card the dragged item should be inserted before, or null to append.
function refCard(wrap, y) {
  for (const c of wrap.querySelectorAll('.card:not(.dragging)')) {
    const r = c.getBoundingClientRect();
    if (y < r.top + r.height / 2) return c;
  }
  return null;
}

document.addEventListener('dragover', e => {
  if (!dragging) return;
  const column = e.target.closest('.column');
  if (!column) return;
  e.preventDefault();

  document.querySelectorAll('.column.drag-over').forEach(c => {
    if (c !== column) c.classList.remove('drag-over');
  });
  column.classList.add('drag-over');

  const wrap = column.querySelector('.cards-wrap');
  const ref = refCard(wrap, e.clientY);
  ref ? wrap.insertBefore(ghost, ref) : wrap.appendChild(ghost);
});

document.addEventListener('dragleave', e => {
  const column = e.target.closest('.column');
  if (column && !column.contains(e.relatedTarget)) column.classList.remove('drag-over');
});

document.addEventListener('drop', e => {
  if (!dragging) return;
  const column = e.target.closest('.column');
  if (!column) return;
  e.preventDefault();
  column.classList.remove('drag-over');

  const toCol       = column.dataset.col;
  const toProjectId = column.dataset.project;
  const wrap        = column.querySelector('.cards-wrap');
  const { id, fromCol, projectId: fromProjectId } = dragging;

  const fromProj = state.projects.find(p => p.id === fromProjectId);
  const toProj   = state.projects.find(p => p.id === toProjectId);
  if (!fromProj || !toProj) return;
  const srcIdx   = fromProj.board[fromCol].findIndex(c => c.id === id);
  if (srcIdx === -1) return;

  const [card] = fromProj.board[fromCol].splice(srcIdx, 1);

  // Count real cards before the ghost to get insertion index.
  let toIdx = toProj.board[toCol].length;
  if (ghost?.parentNode === wrap) {
    let n = 0;
    for (const child of wrap.children) {
      if (child === ghost) { toIdx = n; break; }
      if (child.classList.contains('card') && !child.classList.contains('dragging')) n++;
    }
  }

  toProj.board[toCol].splice(toIdx, 0, card);
  sendOp({ kind: 'card-move', cardId: id, toProjectId, toCol, toIndex: toIdx });
  render();
});

// ── Card Modal ─────────────────────────────────
const cardOverlay  = document.getElementById('card-overlay');
const cardTitleInp = document.getElementById('card-title-inp');
const cardDescInp  = document.getElementById('card-desc-inp');
const cardNotesInp = document.getElementById('card-notes-inp');

function openCardModal(projectId, col) {
  addCardCtx = { projectId, col };
  document.querySelector('#card-overlay .modal h2').textContent = 'Add Sticky';
  document.getElementById('card-submit-btn').textContent = 'Add Sticky';
  cardTitleInp.value = '';
  cardDescInp.value = '';
  cardNotesInp.value = '';
  cardOverlay.classList.add('open');
  cardTitleInp.focus();
}

function openCardEditModal(card, col, projectId) {
  addCardCtx = { projectId, col, cardId: card.id };
  document.querySelector('#card-overlay .modal h2').textContent = 'Edit Sticky';
  document.getElementById('card-submit-btn').textContent = 'Save';
  cardTitleInp.value = card.title;
  cardDescInp.value = card.desc || '';
  cardNotesInp.value = card.notes || '';
  cardOverlay.classList.add('open');
  cardTitleInp.focus();
}

function closeCardModal() {
  cardOverlay.classList.remove('open');
  cardTitleInp.value = '';
  cardDescInp.value = '';
  cardNotesInp.value = '';
  addCardCtx = null;
}

function submitCard() {
  const title = cardTitleInp.value.trim();
  if (!title) { cardTitleInp.focus(); return; }
  const proj = state.projects.find(p => p.id === addCardCtx.projectId);
  if (addCardCtx.cardId) {
    const card = proj.board[addCardCtx.col].find(c => c.id === addCardCtx.cardId);
    if (card) {
      card.title = title;
      card.desc  = cardDescInp.value.trim();
      card.notes = cardNotesInp.value.trim();
      sendOp({ kind: 'card-edit', cardId: card.id, title: card.title, desc: card.desc, notes: card.notes });
    }
  } else {
    const card = { id: uid(), title, desc: cardDescInp.value.trim(), notes: cardNotesInp.value.trim() };
    proj.board[addCardCtx.col].push(card);
    sendOp({ kind: 'card-add', projectId: addCardCtx.projectId, col: addCardCtx.col, card });
  }
  render();
  closeCardModal();
}

document.getElementById('card-cancel-btn').addEventListener('click', closeCardModal);
document.getElementById('card-submit-btn').addEventListener('click', submitCard);
cardOverlay.addEventListener('click', e => { if (e.target === cardOverlay) closeCardModal(); });

// ── Project Modal ──────────────────────────────
const projOverlay = document.getElementById('proj-overlay');
const projNameInp = document.getElementById('proj-name-inp');
let editProjId = null;

function openProjModal(projId = null) {
  editProjId = projId;
  if (projId) {
    const proj = state.projects.find(p => p.id === projId);
    initPicker(proj.color);
    projNameInp.value = proj.name;
    document.querySelector('#proj-overlay .modal h2').textContent = 'Edit Project';
    document.getElementById('proj-submit-btn').textContent = 'Save';
  } else {
    initPicker(DEFAULTS[state.projects.length % DEFAULTS.length]);
    projNameInp.value = '';
    document.querySelector('#proj-overlay .modal h2').textContent = 'New Project';
    document.getElementById('proj-submit-btn').textContent = 'Create Project';
  }
  projOverlay.classList.add('open');
  projNameInp.focus();
}

function closeProjModal() {
  projOverlay.classList.remove('open');
  projNameInp.value = '';
  editProjId = null;
}

function submitProject() {
  const name = projNameInp.value.trim();
  if (!name) { projNameInp.focus(); return; }
  if (editProjId) {
    const proj = state.projects.find(p => p.id === editProjId);
    proj.name = name;
    proj.color = cpHex();
    sendOp({ kind: 'project-edit', projectId: proj.id, name: proj.name, color: proj.color });
  } else {
    const proj = {
      id: uid(),
      name,
      color: cpHex(),
      board: { todo: [], inprogress: [], done: [] },
    };
    state.projects.push(proj);
    state.view = proj.id;
    sendOp({ kind: 'project-add', project: { id: proj.id, name: proj.name, color: proj.color } });
    sendOp({ kind: 'view-set', view: proj.id });
  }
  render();
  closeProjModal();
}

function deleteProject(id) {
  const proj = state.projects.find(p => p.id === id);
  openConfirm(`Delete "${proj.name}" and all its cards?`, () => {
    state.projects = state.projects.filter(p => p.id !== id);
    sendOp({ kind: 'project-delete', projectId: id });
    if (state.view === id) {
      state.view = 'all';
      sendOp({ kind: 'view-set', view: 'all' });
    }
    render();
  });
}

// ── Confirm Modal ──────────────────────────────
let confirmCallback = null;

function openConfirm(message, onConfirm) {
  document.getElementById('confirm-message').textContent = message;
  confirmCallback = onConfirm;
  document.getElementById('confirm-overlay').classList.add('open');
}

function closeConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
  confirmCallback = null;
}

document.getElementById('confirm-ok-btn').addEventListener('click', () => {
  confirmCallback?.();
  closeConfirm();
});
document.getElementById('confirm-cancel-btn').addEventListener('click', closeConfirm);
document.getElementById('confirm-overlay').addEventListener('click', e => {
  if (e.target === document.getElementById('confirm-overlay')) closeConfirm();
});

document.getElementById('new-proj-btn').addEventListener('click', () => openProjModal());
document.getElementById('nav-all').addEventListener('click', () => setView('all'));
document.getElementById('proj-cancel-btn').addEventListener('click', closeProjModal);
document.getElementById('proj-submit-btn').addEventListener('click', submitProject);
projOverlay.addEventListener('click', e => { if (e.target === projOverlay) closeProjModal(); });

// ── Keyboard shortcuts ─────────────────────────
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if (cardOverlay.classList.contains('open')) { closeCardModal(); return; }
    if (projOverlay.classList.contains('open')) { closeProjModal(); return; }
    if (document.getElementById('confirm-overlay').classList.contains('open')) { closeConfirm(); return; }
  }
  if (e.key === 'Enter') {
    if (cardOverlay.classList.contains('open') && document.activeElement !== cardDescInp) {
      e.preventDefault(); submitCard(); return;
    }
    if (projOverlay.classList.contains('open') && document.activeElement.id !== 'cp-hex') {
      e.preventDefault(); submitProject(); return;
    }
  }
});

// ── Init ───────────────────────────────────────
// `locked` starts true, so writes are blocked until the first successful load.
// The lock overlay itself only appears if loading fails — showing it during a
// normal load meant a visible flash before the fetch landed.
render();

function showLockError(msg) {
  const errEl = document.getElementById('lock-error');
  if (!errEl) return;
  errEl.textContent = msg;
  errEl.style.display = '';
}
function clearLockError() {
  const errEl = document.getElementById('lock-error');
  if (!errEl) return;
  errEl.textContent = '';
  errEl.style.display = 'none';
}

async function loadBoard() {
  clearLockError();
  const result = await loadData();
  if (result.ok) {
    hideLock();
  } else {
    showLock();
    showLockError(result.error || 'Could not load the board.');
  }
}

async function applyConfig() {
  try {
    const res = await fetch('/config', { cache: 'no-store' });
    const cfg = await res.json();
    if (cfg.title) {
      document.title = cfg.title;
      document.querySelector('.app-name').textContent = cfg.title;
    }
  } catch {
    // no config endpoint / bad response: keep the static title from the HTML
  }
}

document.getElementById('lock-load-btn').addEventListener('click', loadBoard);

if (location.protocol === 'file:') {
  showLock();
  showLockError('This board now runs from the local Stickies server.\nRun start-stickies.ps1 — it opens the board in your browser automatically.');
} else {
  applyConfig();
  loadBoard();
}
