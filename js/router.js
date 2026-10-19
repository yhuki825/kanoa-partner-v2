// ハッシュルーティング＋画面の骨格
// 各画面(feature)は register() で自分を登録する。画面同士は直接importしない
import { S } from './store.js';
import { esc } from './ui/format.js';
import { icon } from './ui/icons.js';
import { showError } from './ui/components.js';
import { logout } from './auth.js';
import { tierLabel } from './config.js';

const routes = new Map();   // path -> { title, icon, roles, visible, nav, order, render(el, params) }
export function register(path, def) { routes.set(path, { order: 99, nav: true, ...def }); }

export function navigate(path) { location.hash = '#/' + String(path).replace(/^#?\/?/, ''); }

function parseHash() {
  const [path, query] = location.hash.replace(/^#\/?/, '').split('?');
  return { path: path || 'home', params: Object.fromEntries(new URLSearchParams(query || '')) };
}

// roles: 見せる役割（'ra'/'ca'）。visible: さらに細かい条件（例: 1次パートナーだけ）。メニューと直接アクセスの両方に効く
function allowed(def) { return (!def.roles || def.roles.includes(S.role)) && (!def.visible || !!def.visible()); }
function titleOf(def) { return typeof def.title === 'function' ? def.title() : def.title; }

export function mountApp() {
  const app = document.getElementById('app');
  const nav = [...routes.entries()].filter(([, d]) => d.nav && allowed(d))
    .sort((a, b) => a[1].order - b[1].order);
  const who = S.role === 'ra'
    ? `${esc(S.member.name)}<span>KANOA（RA）</span>`
    : `${esc(S.member.name)}<span>${esc(S.company.name)}・${esc(S.member.login_id)}・${esc(tierLabel(S.company.tier))}</span>`;

  app.innerHTML = `
    <div class="layout">
      <aside class="sidebar">
        <div class="brand">KANOA Partner Portal</div>
        <div class="who">${who}</div>
        <nav>${nav.map(([p, d]) => `
          <a class="nav-item" href="#/${p}" data-path="${p}">
            ${icon(d.icon)}<span class="nav-label">${esc(titleOf(d))}</span>
            <span class="badge" data-badge="${p}" hidden></span>
          </a>`).join('')}</nav>
        <div class="spacer"></div>
        <button class="nav-item" data-act="logout">${icon('logout')}<span class="nav-label">ログアウト</span></button>
      </aside>
      <div class="main">
        <header class="topbar"><h1 id="view-title"></h1><div class="grow"></div><div id="topbar-actions"></div></header>
        <main class="content" id="view"></main>
      </div>
    </div>`;
  app.querySelector('[data-act="logout"]').onclick = () => logout();
  window.addEventListener('hashchange', renderView);
  renderView();
}

let renderSeq = 0;
export async function renderView() {
  const { path, params } = parseHash();
  const def = routes.get(path);
  if (!def || !allowed(def)) { navigate('home'); return; }
  const seq = ++renderSeq;
  document.getElementById('view-title').textContent = titleOf(def);
  document.title = `${titleOf(def)}｜KANOA Partner Portal`;
  document.getElementById('topbar-actions').innerHTML = '';
  document.querySelectorAll('.nav-item[data-path]').forEach((b) => b.classList.toggle('active', b.dataset.path === (def.navParent || path)));
  // 新しい画面は見えないところで組み立て、できあがった瞬間に差し替える（前の画面のDOMは残さない）
  // 組み立ての間は前の画面を見せたまま待つ。0.15秒を超えたら上に細い帯を出す（「読み込み中」で画面を消さない）
  const old = document.getElementById('view');
  try { old.__cleanup?.(); } catch {}
  if (!old.childElementCount) old.innerHTML = '<div class="empty">読み込み中…</div>';   // 最初の表示だけ
  const el = old.cloneNode(false);
  const slow = setTimeout(() => { if (seq === renderSeq) document.body.classList.add('is-routing'); }, 150);
  let failed = null;
  try { await def.render(el, params); } catch (e) { failed = e; }
  clearTimeout(slow);
  if (seq !== renderSeq) { try { el.__cleanup?.(); } catch {} return; }   // その間に別の画面へ移った → 捨てる
  document.body.classList.remove('is-routing');
  if (failed) {
    el.innerHTML = '<div class="empty">この画面を表示できませんでした。上の帯の内容を確認してください。</div>';
    showError(failed, `画面の表示: ${path}`);
  }
  document.getElementById('view').replaceWith(el);
}

export function setBadge(path, count) {
  document.querySelectorAll(`[data-badge="${path}"]`).forEach((b) => {
    b.hidden = !count;
    b.textContent = count > 99 ? '99+' : String(count || '');
  });
}

export function setTopbarActions(html) {
  const a = document.getElementById('topbar-actions');
  a.innerHTML = html;
  return a;
}
