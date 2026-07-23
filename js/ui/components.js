// 共通UI部品: トースト・モーダル・確認ダイアログ
import { esc } from './format.js';

export function toast(msg, kind = '') {
  const root = document.getElementById('toast-root');
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  root.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .3s'; }, 2600);
  setTimeout(() => el.remove(), 3000);
}

// モーダル: bodyHtml を表示。戻り値 close() で閉じる。背景クリック/Escで閉じる
export function openModal(bodyHtml, { onClose } = {}) {
  const root = document.getElementById('modal-root');
  const back = document.createElement('div');
  back.className = 'modal-back';
  back.innerHTML = `<div class="modal">${bodyHtml}</div>`;
  const close = () => { back.remove(); document.removeEventListener('keydown', onKey); onClose?.(); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  back.addEventListener('click', (e) => { if (e.target === back) close(); });
  document.addEventListener('keydown', onKey);
  root.appendChild(back);
  return { el: back.querySelector('.modal'), close };
}

// 確認ダイアログ（Promise<boolean>）
export function confirmDialog(message, { okLabel = 'OK', danger = false } = {}) {
  return new Promise((resolve) => {
    const m = openModal(`
      <p>${esc(message)}</p>
      <div class="modal-actions">
        <button class="btn" data-act="cancel">キャンセル</button>
        <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-act="ok">${esc(okLabel)}</button>
      </div>`, { onClose: () => resolve(false) });
    m.el.querySelector('[data-act="cancel"]').onclick = () => { m.close(); };
    m.el.querySelector('[data-act="ok"]').onclick = () => { resolve(true); m.close(); };
  });
}
