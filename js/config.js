// 接続設定・定数（V1と同じSupabaseを共有。V2のものはすべて v2 接頭辞）
export const CONFIG = {
  SB_URL: 'https://oicpfsfvywdhdriqehyr.supabase.co',
  SB_ANON_KEY: 'sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms',
};

export const APP_NAME = 'KANOA Partner Portal';

// CAのログインID（例 A00001-01）→ ログイン用の内部メール。Edge Function の loginEmail と同一規則
export function loginEmail(loginId) {
  return `${String(loginId).trim().toLowerCase()}@id.kanoa-portal.invalid`;
}

// 階層番号→頭文字（1=A .. 26=Z, 27=AA ..）。DBの v2_tier_prefix と同一規則
export function tierPrefix(tier) {
  let n = tier, s = '';
  while (n > 0) { s = String.fromCharCode(64 + ((n - 1) % 26 + 1)) + s; n = Math.floor((n - 1) / 26); }
  return s;
}
export function tierLabel(tier) { return `${tierPrefix(tier)}ライン`; }
