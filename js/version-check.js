// 古い画面を開きっぱなしにさせない（申し送りD-3）
// 5分ごと＋タブに戻ったとき、自分自身（index.html）の更新を確認する。
// 安全なとき（入力中でない・モーダルが開いていない）は黙って再読み込み、
// それ以外は帯で知らせる。
import { anyModalOpen, showNotice } from './ui/components.js';

let baseline = null;
let notified = false;

async function stamp() {
  try {
    const r = await fetch(location.pathname, { method: 'HEAD', cache: 'no-store' });
    return r.headers.get('etag') || r.headers.get('last-modified') || null;
  } catch { return null; }
}

function isTyping() {
  const a = document.activeElement;
  if (a && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName)) return true;
  return [...document.querySelectorAll('textarea, input[type="text"], input:not([type])')].some((x) => x.value && x.dataset.dirty === '1');
}

async function check() {
  const now = await stamp();
  if (!now) return;
  if (baseline === null) { baseline = now; return; }
  if (now === baseline || notified) return;
  if (!anyModalOpen() && !isTyping()) { location.reload(); return; }
  notified = true;
  showNotice('<b>新しい版が公開されました。</b><span>作業のきりがよいところで再読み込みしてください。</span>',
    [{ label: '再読み込み', primary: true, onClick: () => location.reload() }]);
}

export function startVersionCheck() {
  check();
  setInterval(check, 5 * 60 * 1000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') check(); });
  // 入力された欄に印を付けておく（自動再読み込みで入力を消さないため）
  document.addEventListener('input', (e) => { if (e.target?.dataset) e.target.dataset.dirty = '1'; });
}
