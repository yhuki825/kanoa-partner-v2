// 金額の計算（消費税）。この計算はここだけで行い、画面ごとに書かない
// 紹介料・返金額は税抜で保存し、表示のときに消費税10%（1円未満切り捨て）を足して税込にする（V1と同じ）
export const TAX_PERCENT = 10;

// 税抜の額 → { net: 税抜, tax: 消費税, total: 税込 }。null/空は null のまま返す
export function withTax(amount) {
  if (amount == null || amount === '') return { net: null, tax: null, total: null };
  const net = Number(amount);
  const tax = Math.floor((net * TAX_PERCENT) / 100);   // 小数の誤差を避けるため、0.1 を掛けずに整数で計算する
  return { net, tax, total: net + tax };
}
export const taxOf = (amount) => withTax(amount).tax;
export const totalOf = (amount) => withTax(amount).total;

// 返金規定（[{months, rate}]）を読める文に。月数の短い順
export function refundPolicyLines(policy) {
  return [...(Array.isArray(policy) ? policy : [])].sort((a, b) => a.months - b.months)
    .map((p) => `入社日から${p.months}か月以内の退職：${p.rate}%返金`);
}

// 金額の入力欄（円）を読む。空欄は null。1円単位の0以上の整数（1兆円未満）でなければ日本語のエラーを投げる（DBも同じ条件で拒否する）
// 入力欄（要素）を渡すこと: type=number の欄は「５０,０００」「1,000」のような読めない入力を空欄（''）として返すため、
// 要素の validity.badInput を見ないと「未入力」と取り違える
export const YEN_MAX = 1000000000000;
export function parseYen(input, label = '金額') {
  const bad = () => new Error(`${label}は、半角数字だけで1円単位の0以上の整数を入力してください（カンマ・小数・全角数字は使えません）。`);
  // 入力欄が見つからない＝画面の作りの不具合。黙って「空欄」として扱わない
  if (input === null || input === undefined) throw new Error(`${label}の入力欄が見つかりません（画面の不具合です。お手数ですが報告してください）。`);
  if (input && typeof input === 'object' && input.validity?.badInput) throw bad();
  const s = String(input && typeof input === 'object' ? input.value : (input ?? '')).trim();
  if (s === '') return null;
  if (!/^\d+$/.test(s)) throw bad();
  const n = Number(s);
  if (!Number.isSafeInteger(n) || n >= YEN_MAX) throw new Error(`${label}が大きすぎます（1兆円未満で入力してください）。`);
  return n;
}
