// Supabaseクライアント（RAもCAも Supabase Auth の正規セッション）
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm';
import { CONFIG } from './config.js';

let _client = null;
export function sb() {
  if (!_client) {
    _client = createClient(CONFIG.SB_URL, CONFIG.SB_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, storageKey: 'kanoa_v2_session' },
    });
  }
  return _client;
}

const FN_ERRORS = {
  unauthorized: 'ログインし直してください。',
  owner_only: 'この操作は会社の代表者だけが行えます。',
  not_found: 'この企業コードの招待が見つかりません。',
  already_used: 'この招待はすでに使用されています。',
  expired: 'この招待は有効期限が切れています。発行元に再発行を依頼してください。',
  bad_password: '初期パスワードが違います。',
  weak_password: '新しいパスワードは8文字以上にしてください。',
  company_name_required: '会社名を入力してください。',
  name_required: '名前を入力してください。',
};

// Edge Function 呼び出し（ログイン中ならトークンを付ける）
export async function callFn(name, body) {
  const headers = { 'Content-Type': 'application/json', apikey: CONFIG.SB_ANON_KEY };
  const { data: s } = await sb().auth.getSession();
  if (s?.session?.access_token) headers.Authorization = `Bearer ${s.session.access_token}`;
  let res;
  try {
    res = await fetch(`${CONFIG.SB_URL}/functions/v1/${name}`, { method: 'POST', headers, body: JSON.stringify(body) });
  } catch {
    throw new Error('通信に失敗しました。ネットワークを確認してください。');
  }
  let data = null;
  try { data = await res.json(); } catch {}
  if (!res.ok) {
    const err = new Error(FN_ERRORS[data?.error] || `処理に失敗しました（${name} / ${res.status} / ${data?.error || '不明'}）`);
    err.detail = { fn: name, status: res.status, body: data };
    throw err;
  }
  return data;
}
