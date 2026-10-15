// 画面横断の最小限の状態（権限の判断はDBが行う。ここは表示用）
export const S = {
  role: null,      // 'ra' | 'ca' | null
  member: null,    // v2_members の自分の行
  company: null,   // CA: 自社 { id, code, tier, name }
};
