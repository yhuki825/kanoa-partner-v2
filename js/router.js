// ハッシュルーティング＋画面シェル描画
// 各featureは register() でルートを登録する。feature同士の直接importは禁止
import { S } from './store.js';
import { esc } from './ui/format.js';
import { logout } from './auth.js';
import { tierLabel } from './config.js';

const routes = new Map();   // path -> { title, nav, roles, render(el), icon }

export function register(path, def) { routes.set(path, def); }

export function navigate(path) { location.hash = '#/' + path.replace(/^#?\/?/, ''); }

function currentPath() {
  const h = location.hash.replace(/^#\/?/, '');
  return h || 'home';
}

// ログイン後のアプリ骨格を描画
export function mountApp() {
  const app = document.getElementById('app');
  const navItems = [...routes.entries()]
    .filter(([, d]) => d.nav && (!d.roles || d.roles.includes(S.role)));

  const who = S.role === 'kanoa'
    ? 'KANOA 管理'
    : `${esc(S.company?.name || '')}（${esc(S.company?.code || '')}・${tierLabel(S.company?.tier || 1)}）`;

  app.innerHTML = `
    <div class="layout">
      <aside class="sidebar">
        <div class="brand">KANOA Partner Portal<small>${who}</small></div>
        ${navItems.map(([p, d]) => `
          <button class="nav-item" data-path="${p}">
            <span>${d.icon || '・'}</span><span class="nav-label">${esc(d.title)}</span>
            <span class="badge" data-badge="${p}" hidden></span>
          </button>`).join('')}
        <div class="spacer"></div>
        <button class="nav-item" data-act="logout"><span>⏻</span><span class="nav-label">ログアウト</span></button>
      </aside>
      <div class="main">
        <header class="topbar"><h1 id="view-title"></h1><div class="grow"></div></header>
        <main class="content" id="view"></main>
      </div>
    </div>`;

  app.querySelectorAll('.nav-item[data-path]').forEach((b) => {
    b.onclick = () => navigate(b.dataset.path);
  });
  app.querySelector('[data-act="logout"]').onclick = () => logout();

  window.addEventListener('hashchange', renderView);
  renderView();
}

export function renderView() {
  const path = currentPath();
  const def = routes.get(path) || routes.get('home');
  if (!def) return;
  if (def.roles && !def.roles.includes(S.role)) { navigate('home'); return; }

  document.getElementById('view-title').textContent = def.title;
  document.querySelectorAll('.nav-item[data-path]').forEach((b) => {
    b.classList.toggle('active', b.dataset.path === path);
  });
  const el = document.getElementById('view');
  el.innerHTML = '<div class="empty">読み込み中…</div>';
  Promise.resolve(def.render(el)).catch((e) => {
    el.innerHTML = `<div class="empty">読み込みに失敗しました<br><small>${esc(e?.message || '')}</small></div>`;
  });
}

// ナビのバッジ（未読数など）を更新
export function setBadge(path, count) {
  document.querySelectorAll(`[data-badge="${path}"]`).forEach((b) => {
    b.hidden = !count;
    b.textContent = count > 99 ? '99+' : String(count || '');
  });
}
