// 共通UI部品
// ・トースト: 成功の短い知らせだけに使う（失敗は載せない）
// ・失敗の帯: 閉じるまで残る＋詳細をコピーできる（申し送りD-1）
// ・モーダル: 閉じたらDOMごと破棄する（前回の入力を拾わない。申し送りA-4）
import { esc } from './format.js';

export function toast(msg) {
  const root = document.getElementById('toast-root');
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  root.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .3s'; }, 2400);
  setTimeout(() => el.remove(), 2800);
}

export function showError(err, context = '') {
  const root = document.getElementById('alert-root');
  const message = err?.message || String(err);
  const detail = JSON.stringify({
    at: new Date().toISOString(), context, message, detail: err?.detail || null, page: location.hash,
  }, null, 2);
  const el = document.createElement('div');
  el.className = 'alert-bar err';
  el.innerHTML = `
    <div class="alert-msg"><b>うまくいきませんでした</b><span>${esc(message)}</span></div>
    <button class="btn btn-sm" data-act="copy">詳細をコピー</button>
    <button class="btn btn-sm" data-act="close" aria-label="閉じる">閉じる</button>`;
  el.querySelector('[data-act="copy"]').onclick = async () => {
    try { await navigator.clipboard.writeText(detail); toast('コピーしました'); } catch { prompt('この内容をコピーしてください', detail); }
  };
  el.querySelector('[data-act="close"]').onclick = () => el.remove();
  root.appendChild(el);
  console.error(context, err);
}

export function showNotice(html, actions = []) {
  const root = document.getElementById('alert-root');
  const el = document.createElement('div');
  el.className = 'alert-bar info';
  el.innerHTML = `<div class="alert-msg">${html}</div>` +
    actions.map((a, i) => `<button class="btn btn-sm ${a.primary ? 'btn-primary' : ''}" data-i="${i}">${esc(a.label)}</button>`).join('');
  actions.forEach((a, i) => { el.querySelector(`[data-i="${i}"]`).onclick = () => { a.onClick(); el.remove(); }; });
  root.appendChild(el);
  return el;
}

export function openModal(bodyHtml, { onClose, wide = false } = {}) {
  const root = document.getElementById('modal-root');
  const back = document.createElement('div');
  back.className = 'modal-back';
  back.innerHTML = `<div class="modal ${wide ? 'modal-wide' : ''}" role="dialog" aria-modal="true">${bodyHtml}</div>`;
  let closed = false;
  const close = () => {
    if (closed) return; closed = true;
    back.remove();                      // 隠すのではなく破棄する
    document.removeEventListener('keydown', onKey);
    onClose?.();
  };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  back.addEventListener('mousedown', (e) => { if (e.target === back) close(); });
  document.addEventListener('keydown', onKey);
  root.appendChild(back);
  back.querySelector('input,textarea,select')?.focus();
  return { el: back.querySelector('.modal'), close };
}
export function anyModalOpen() { return !!document.querySelector('#modal-root .modal-back'); }

export function confirmDialog(message, { okLabel = 'OK', danger = false } = {}) {
  return new Promise((resolve) => {
    let answered = false;
    const m = openModal(`
      <p style="white-space:pre-wrap">${esc(message)}</p>
      <div class="modal-actions">
        <button class="btn" data-act="cancel">キャンセル</button>
        <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-act="ok">${esc(okLabel)}</button>
      </div>`, { onClose: () => { if (!answered) resolve(false); } });
    m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
    m.el.querySelector('[data-act="ok"]').onclick = () => { answered = true; resolve(true); m.close(); };
  });
}

// ボタンを押している間の二重送信防止
export async function busy(btn, fn) {
  if (btn.disabled) return;
  btn.disabled = true;
  try { return await fn(); } finally { btn.disabled = false; }
}
