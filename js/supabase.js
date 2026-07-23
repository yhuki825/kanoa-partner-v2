// Supabaseクライアント管理
// 管理者もパートナーも Supabase Auth のセッションを使う（パートナーのセッションは
// Edge Function partner-login が code+pw 照合後に発行する）
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { CONFIG } from './config.js';

let _client = null;

export function sb() {
  if (_client) return _client;
  _client = createClient(CONFIG.SB_URL, CONFIG.SB_ANON_KEY, {
    auth: { persistSession: true, storageKey: 'kanoa_v2_auth' },
  });
  return _client;
}

// Edge Function 呼び出し（fetch直。エラーメッセージを日本語化して投げる）
export async function callFn(name, body, { token } = {}) {
  const headers = { 'Content-Type': 'application/json', apikey: CONFIG.SB_ANON_KEY };
  if (token) headers.Authorization = `Bearer ${token}`;
  let res;
  try {
    res = await fetch(`${CONFIG.SB_URL}/functions/v1/${name}`, {
      method: 'POST', headers, body: JSON.stringify(body),
    });
  } catch {
    throw new Error('通信に失敗しました。ネットワークを確認してください。');
  }
  let data = null;
  try { data = await res.json(); } catch {}
  if (!res.ok) {
    const code = data?.error;
    const msgs = {
      invalid: '企業コードまたはパスワードが違います。',
      suspended: 'このアカウントは停止されています。',
      too_many_attempts: 'ログイン試行が多すぎます。10分ほど待ってから再度お試しください。',
      not_found: 'この企業コードの招待が見つかりません。',
      already_used: 'この招待はすでに使用されています。',
      expired: 'この招待は有効期限が切れています。発行元に再発行を依頼してください。',
      bad_password: '初期パスワードが違います。',
      weak_password: '新しいパスワードは8文字以上にしてください。',
      unauthorized: 'ログインし直してください。',
    };
    throw new Error(msgs[code] || `エラーが発生しました（${res.status}）`);
  }
  return data;
}
