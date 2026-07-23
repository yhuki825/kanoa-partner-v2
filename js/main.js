// エントリポイント: 認証復元 → ログイン画面 or アプリ本体
import { restoreAuth } from './auth.js';
import { mountApp } from './router.js';
import { renderLogin } from './features/auth/login.js';

// featureの登録（import するだけでルートが router に登録される）
import './features/dashboard/dashboard.js';
import './features/relay/relay.js';
import './features/screening/screening.js';
import './features/candidates/candidates.js';
import './features/projects/projects.js';
import './features/companies/companies.js';
import './features/chat/chat.js';
import './features/invoices/invoices.js';
import './features/tasks/tasks.js';
import './features/settings/settings.js';

async function boot() {
  const authed = await restoreAuth();
  if (authed) mountApp();
  else renderLogin(() => mountApp());
}

boot();
