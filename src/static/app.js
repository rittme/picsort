(() => {
let ME = null;
let IMAGES = [];      // [{path, taken, avg, count, mine, scores, deletes}]
let INDEX = new Map(); // path -> idx
let LB = -1;          // lightbox index, -1 = closed

const $ = (s, el=document) => el.querySelector(s);
const el = (tag, attrs={}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k,v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v === true) e.setAttribute(k, '');
    else if (v != null) e.setAttribute(k, v);
  }
  for (const k of kids) e.append(k.nodeType ? k : document.createTextNode(k));
  return e;
};

async function api(path, opts={}) {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

async function login(name) {
  const fd = new FormData();
  fd.set('name', name);
  await fetch('/api/login', { method:'POST', body: fd });
}

async function postRate(path, score) {
  const fd = new FormData();
  fd.set('path', path); fd.set('score', score);
  await fetch('/api/rate', { method:'POST', body: fd });
}
async function postUnrate(path) {
  const fd = new FormData();
  fd.set('path', path);
  await fetch('/api/unrate', { method:'POST', body: fd });
}

function renderTooltip(scores) {
  const t = el('div', {class:'tooltip'});
  if (!scores.length) { t.textContent = 'no ratings yet'; return t; }
  const tbl = el('table');
  scores.sort((a,b)=>a.user.localeCompare(b.user));
  for (const s of scores) {
    const cls = s.score === 0 ? 's del' : 's';
    tbl.append(el('tr', {}, el('td', {}, s.user), el('td', {class:cls}, s.score === 0 ? 'delete' : '★'+s.score)));
  }
  t.append(tbl);
  return t;
}

function makeRatingButtons(it, big=false) {
  const wrap = el('div', { class: big ? '' : 'mine' });
  // 0 = delete, 1..5 = stars
  const labels = [['0','del'],['1',''],['2',''],['3',''],['4',''],['5','']];
  for (const [n, extra] of labels) {
    const score = parseInt(n);
    const isOn = it.mine === score;
    const cls = ['b', extra, isOn ? 'on' : ''].filter(Boolean).join(' ');
    const lbl = score === 0 ? '✖' : score;
    const b = el('button', {
      class: cls,
      title: score === 0 ? 'mark for delete (0)' : `${score} star`,
      onclick: async (ev) => {
        ev.stopPropagation();
        if (it.mine === score) { await postUnrate(it.path); }
        else { await postRate(it.path, score); }
        await refresh();
      }
    }, lbl);
    if (big) b.append(el('kbd', {}, n));
    wrap.append(b);
  }
  return wrap;
}

function renderCard(it, idx) {
  const card = el('div', { class:'card', onclick: () => openLightbox(idx) });
  card.append(el('img', { class:'thumb', loading:'lazy', src:'/img/'+it.path }));
  if (it.deletes > 0)
    card.append(el('div', {class:'deletes', title:`${it.deletes} delete vote(s)`}, '✖'+it.deletes));
  const meta = el('div', {class:'meta'});
  let avgCls = 'avg';
  let avgTxt;
  if (it.count > 0) avgTxt = '★' + it.avg.toFixed(1) + ' ('+it.count+')';
  else { avgCls += ' none'; avgTxt = '—'; }
  const avg = el('span', {class: avgCls}, avgTxt);
  avg.append(renderTooltip(it.scores));
  meta.append(avg);
  meta.append(makeRatingButtons(it));
  card.append(meta);
  return card;
}

function render() {
  const g = $('#grid'); g.innerHTML='';
  IMAGES.forEach((it, i) => g.append(renderCard(it, i)));
  $('#stats').textContent = `${IMAGES.length} images`;
  if (LB >= 0) renderLightbox();
}

async function refresh() {
  const data = await api('/api/images');
  IMAGES = data.images;
  INDEX.clear();
  IMAGES.forEach((it,i) => INDEX.set(it.path, i));
  render();
}

// -- lightbox --
function openLightbox(i) { LB = i; $('#lightbox').classList.remove('hidden'); renderLightbox(); }
function closeLightbox() { LB = -1; $('#lightbox').classList.add('hidden'); }

function renderLightbox() {
  if (LB < 0 || LB >= IMAGES.length) return;
  const it = IMAGES[LB];
  $('#lb-pic').src = '/img/' + it.path;
  $('#lb-name').textContent = `[${LB+1}/${IMAGES.length}] ${it.path}`;
  const avgEl = $('#lb-avg');
  avgEl.innerHTML = '';
  let avgCls = 'avg', avgTxt;
  if (it.count > 0) avgTxt = '★' + it.avg.toFixed(1) + ' ('+it.count+')'; else { avgCls += ' none'; avgTxt = 'no ratings'; }
  const a = el('span', {class:avgCls}, avgTxt);
  a.append(renderTooltip(it.scores));
  avgEl.append(a);
  if (it.deletes > 0) avgEl.append(el('span', {style:'color:#f55;margin-left:.5rem'}, ` ✖${it.deletes}`));
  const m = $('#lb-mine'); m.innerHTML = '';
  m.append(makeRatingButtons(it, true));
}

async function rateCurrent(score) {
  if (LB < 0) return;
  const it = IMAGES[LB];
  if (it.mine === score) await postUnrate(it.path);
  else await postRate(it.path, score);
  await refresh();
  // auto-advance
  if (LB < IMAGES.length - 1) LB++;
  renderLightbox();
}

document.addEventListener('keydown', (e) => {
  if (LB < 0) return;
  if (e.key === 'Escape') return closeLightbox();
  if (e.key === 'ArrowRight') { if (LB < IMAGES.length-1) { LB++; renderLightbox(); } return; }
  if (e.key === 'ArrowLeft')  { if (LB > 0) { LB--; renderLightbox(); } return; }
  if (/^[0-5]$/.test(e.key)) { e.preventDefault(); rateCurrent(parseInt(e.key)); }
});

$('#lb-close').addEventListener('click', closeLightbox);
$('#lightbox .lb-img').addEventListener('click', (e) => { if (e.target.id === 'lb-pic') return; closeLightbox(); });

// -- bootstrap --
(async () => {
  const me = await api('/api/me');
  ME = me.user;
  if (!ME) {
    const dlg = $('#namedlg');
    dlg.showModal();
    dlg.addEventListener('close', async () => {
      const name = $('#name').value.trim();
      if (!name) { dlg.showModal(); return; }
      await login(name); ME = name;
      $('#who').textContent = '👤 ' + ME;
      await refresh();
    });
  } else {
    $('#who').textContent = '👤 ' + ME;
    await refresh();
  }
  // poll every 5s
  setInterval(() => { if (document.visibilityState === 'visible') refresh().catch(()=>{}); }, 5000);
})();
})();
