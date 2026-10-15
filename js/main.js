// 入口: 認証の復元 → ログイン画面 / 初回パスワード変更 / アプリ本体
import { loadMe } from './auth.js';
import { S } from './store.js';
import { mountApp } from './router.js';
import { showError } from './ui/components.js';
import { startVersionCheck } from './version-check.js';
import { renderLogin } from './features/auth/login.js';
import { renderForcePasswordChange } from './features/auth/change-password.js';

// 画面の登録（importするだけで router に載る）
import { refreshNoticeBadge } from './features/home/home.js';
import './features/upcoming/upcoming.js';
import './features/account/account.js';

// 握り潰さない: 想定外のエラーはすべて帯に出す（申し送りA-4/D-1）
window.addEventListener('error', (e) => showError(e.error || new Error(e.message), '想定外のエラー'));
window.addEventListener('unhandledrejection', (e) => showError(e.reason, '想定外のエラー（非同期）'));

function enter() {
  if (S.member?.must_change_pw) { renderForcePasswordChange(enter); return; }
  mountApp();
  refreshNoticeBadge();
}

async function boot() {
  startVersionCheck();
  try {
    if (await loadMe()) enter();
    else renderLogin(enter);
  } catch (e) {
    renderLogin(enter);
    showError(e, '起動');
  }
}
boot();
