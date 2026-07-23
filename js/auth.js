// 認証: 起動時の復元・ログイン・ログアウト
// 役割の判定は JWT の app_metadata（app_role='partner' なら企業、それ以外は管理者候補）
import { sb, callFn } from './supabase.js';
import { S } from './store.js';

const COMPANY_KEY = 'kanoa_v2_company';   // 表示用の企業情報キャッシュ（権限はRLSが担保）

function applyPartner(meta, cached) {
  S.role = 'partner';
  S.company = {
    id: meta.company_id, tier: meta.tier, code: meta.code,
    name: cached?.name || '',
  };
}

// 起動時: 保存済みセッションを復元して S に反映。戻り値 true=ログイン済み
export async function restoreAuth() {
  try {
    const { data } = await sb().auth.getSession();
    const user = data?.session?.user;
    if (!user) return false;
    const meta = user.app_metadata || {};
    if (meta.app_role === 'partner') {
      let cached = null;
      try { cached = JSON.parse(localStorage.getItem(COMPANY_KEY) || 'null'); } catch {}
      applyPartner(meta, cached);
    } else {
      S.role = 'kanoa';
      S.adminEmail = user.email || null;
    }
    return true;
  } catch { return false; }
}

export async function adminLogin(email, pw) {
  const { error } = await sb().auth.signInWithPassword({ email, password: pw });
  if (error) throw new Error('メールアドレスまたはパスワードが違います。');
  S.role = 'kanoa';
  S.adminEmail = email;
}

async function applySession(data) {
  const { error } = await sb().auth.setSession({
    access_token: data.access_token, refresh_token: data.refresh_token,
  });
  if (error) throw new Error('セッションの確立に失敗しました。もう一度お試しください。');
  S.role = 'partner';
  S.company = data.company;
  try { localStorage.setItem(COMPANY_KEY, JSON.stringify(data.company)); } catch {}
}

export async function partnerLogin(code, pw) {
  const data = await callFn('partner-login', { code, pw });
  await applySession(data);
  return data;  // must_change_pw を呼び出し側で確認
}

// 招待の受諾（初回ログイン）
export async function partnerAccept({ code, tempPw, newPw, contact, email, phone }) {
  const data = await callFn('invite-accept', {
    code, temp_pw: tempPw, new_pw: newPw, contact, email, phone,
  });
  await applySession(data);
  return data;
}

export async function logout() {
  try { await sb().auth.signOut(); } catch {}
  try { localStorage.removeItem(COMPANY_KEY); } catch {}
  S.role = null; S.company = null; S.adminEmail = null;
  location.hash = '';
  location.reload();
}
