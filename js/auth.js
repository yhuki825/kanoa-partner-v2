// 認証: 起動時の復元・ログイン・ログアウト
import { sb, callFn, setPartnerToken, getPartnerToken, parseJwt } from './supabase.js';
import { S } from './store.js';

// 起動時: 保存済みの認証を復元して S に反映。戻り値 true=ログイン済み
export async function restoreAuth() {
  // 1) パートナーJWT
  const token = getPartnerToken();
  if (token) {
    const p = parseJwt(token);
    if (p && p.exp * 1000 > Date.now() + 60_000 && p.app_role === 'partner') {
      S.role = 'partner';
      S.company = { id: p.company_id, tier: p.tier, code: p.code, name: p.name || '' };
      return true;
    }
    setPartnerToken(null);  // 期限切れは破棄
  }
  // 2) KANOA管理者セッション
  try {
    const { data } = await sb().auth.getSession();
    if (data?.session) {
      S.role = 'kanoa';
      S.adminEmail = data.session.user?.email || null;
      return true;
    }
  } catch {}
  return false;
}

export async function adminLogin(email, pw) {
  const { error } = await sb().auth.signInWithPassword({ email, password: pw });
  if (error) throw new Error('メールアドレスまたはパスワードが違います。');
  S.role = 'kanoa';
  S.adminEmail = email;
}

export async function partnerLogin(code, pw) {
  const data = await callFn('partner-login', { code, pw });
  setPartnerToken(data.token);
  S.role = 'partner';
  S.company = data.company;
  return data;  // must_change_pw を呼び出し側で確認
}

// 招待の受諾（初回ログイン）
export async function partnerAccept({ code, tempPw, newPw, contact, email, phone }) {
  const data = await callFn('invite-accept', {
    code, temp_pw: tempPw, new_pw: newPw, contact, email, phone,
  });
  setPartnerToken(data.token);
  S.role = 'partner';
  S.company = data.company;
  return data;
}

export async function logout() {
  if (S.role === 'kanoa') { try { await sb().auth.signOut(); } catch {} }
  setPartnerToken(null);
  S.role = null; S.company = null; S.adminEmail = null;
  location.hash = '';
  location.reload();
}
