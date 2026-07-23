// エントリポイント: 認証復元 → ログイン画面 or アプリ本体
import { restoreAuth } from './auth.js';
import { mountApp } from './router.js';
import { renderLogin } from './features/auth/login.js';

// featureの登録（import するだけでルートが router に登録される）
import './features/dashboard/dashboard.js';
// Phase 2以降で追加: candidates / relay / companies / invites / projects / chat / invoices / tasks / settings

async function boot() {
  const authed = await restoreAuth();
  if (authed) mountApp();
  else renderLogin(() => mountApp());
}

boot();
