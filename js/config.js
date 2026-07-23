// 接続設定・定数（V1と同じSupabaseプロジェクトを使用。V2は新テーブル群で並行稼働）
export const CONFIG = {
  SB_URL: 'https://oicpfsfvywdhdriqehyr.supabase.co',
  SB_ANON_KEY: 'sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms',
};

export const APP_NAME = 'KANOA Partner Portal';
export const TOKEN_KEY = 'kanoa_v2_partner_token';   // パートナーJWTの保存先

// 階層番号→頭文字（1=A .. 26=Z, 27=AA ..）。DBの v2_tier_prefix と同一規則
export function tierPrefix(tier) {
  let n = tier, s = '';
  while (n > 0) { s = String.fromCharCode(64 + ((n - 1) % 26 + 1)) + s; n = Math.floor((n - 1) / 26); }
  return s;
}
export function tierLabel(tier) { return `${tierPrefix(tier)}ライン`; }
