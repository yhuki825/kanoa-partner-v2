// 認証: ログイン・起動時の復元・ログアウト
// 本人の役割（RA/CA）と会社は v2_members から引く（権限の正本はDB）
import { sb } from './supabase.js';
import { S } from './store.js';
import { loginEmail } from './config.js';

// ログイン中の本人を v2_members から読み込む。V2のアカウントでなければ false
export async function loadMe() {
  const { data: s } = await sb().auth.getSession();
  const uid = s?.session?.user?.id;
  if (!uid) return false;
  const { data: m, error } = await sb().from('v2_members')
    .select('*, company:v2_companies(id, code, tier, name, status)')
    .eq('user_id', uid).maybeSingle();
  if (error) throw error;
  if (!m || m.status !== 'active') return false;
  if (m.role === 'ca' && m.company?.status !== 'active') return false;
  S.role = m.role;
  S.member = m;
  S.company = m.company || null;
  return true;
}

// ID（CA）またはメールアドレス（RA）でログイン
export async function login(idOrEmail, pw) {
  const v = String(idOrEmail || '').trim();
  const email = v.includes('@') ? v : loginEmail(v);
  const { error } = await sb().auth.signInWithPassword({ email, password: pw });
  if (error) throw new Error('IDまたはパスワードが違います。');
  if (!await loadMe()) {
    await sb().auth.signOut();
    throw new Error('このアカウントはまだV2で使えるように登録されていません。');
  }
}

export async function changePassword(newPw) {
  if (String(newPw).length < 8) throw new Error('パスワードは8文字以上にしてください。');
  const { error } = await sb().auth.updateUser({ password: newPw });
  if (error) throw new Error(`パスワードを変更できませんでした（${error.message}）`);
  const { error: e2 } = await sb().rpc('v2_clear_must_change_pw');
  if (e2) throw new Error(`変更の記録に失敗しました（${e2.message}）`);
  if (S.member) S.member.must_change_pw = false;
}

// 本人確認として現在のパスワードで入り直してから変更する
export async function changePasswordWithCurrent(currentPw, newPw) {
  const { data: s } = await sb().auth.getSession();
  const email = s?.session?.user?.email;
  const { error } = await sb().auth.signInWithPassword({ email, password: currentPw });
  if (error) throw new Error('現在のパスワードが違います。');
  await changePassword(newPw);
}

export async function logout() {
  try { await sb().auth.signOut(); } catch {}
  location.hash = '';
  location.reload();
}
