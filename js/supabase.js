// Supabaseクライアント管理
// ・KANOA管理者: supabase.auth のセッションをそのまま使う
// ・パートナー: Edge Function発行のJWTを Authorization ヘッダに載せる
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { CONFIG, TOKEN_KEY } from './config.js';

let _client = null;
let _partnerToken = null;

export function getPartnerToken() {
  if (_partnerToken) return _partnerToken;
  try { _partnerToken = localStorage.getItem(TOKEN_KEY); } catch { /* private mode等 */ }
  return _partnerToken;
}

export function setPartnerToken(token) {
  _partnerToken = token;
  try { token ? localStorage.setItem(TOKEN_KEY, token) : localStorage.removeItem(TOKEN_KEY); } catch {}
  _client = null;  // ヘッダ構成が変わるため作り直し
}

// JWTペイロードの取り出し（署名検証はサーバー側の仕事。ここでは表示・期限判定のみ）
export function parseJwt(token) {
  try {
    const b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(decodeURIComponent(escape(atob(b64))));
  } catch { return null; }
}

export function sb() {
  if (_client) return _client;
  const token = getPartnerToken();
  _client = createClient(CONFIG.SB_URL, CONFIG.SB_ANON_KEY, token
    ? { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } }
    : { auth: { persistSession: true, storageKey: 'kanoa_v2_admin' } });
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
