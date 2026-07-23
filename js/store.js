// 画面横断の最小限の状態
export const S = {
  role: null,        // 'kanoa' | 'partner' | null
  company: null,     // パートナー時: { id, tier, code, name }
  adminEmail: null,  // 管理者時
};

const listeners = new Set();
export function onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }
export function emit() { listeners.forEach((fn) => fn(S)); }
