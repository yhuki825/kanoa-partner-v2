// 選考チャットの添付ファイルの決まり（種類・大きさ・数）。DBにも画面部品にも触れない（node でも確かめられる）
// サーバー側（v2_msg_send）も同じ決まりで、置き場の記録を見て確かめ直す
export const CHAT_MAX_FILES = 5;
export const CHAT_MAX_BYTES = 10 * 1024 * 1024;
export const TYPES = { 'application/pdf': '.pdf', 'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/webp': '.webp' };
export const CHAT_ACCEPT = `${Object.keys(TYPES).join(',')},.pdf,.jpg,.jpeg,.png,.gif,.webp`;

export const isImage = (mime) => String(mime || '').startsWith('image/');
export function fmtSize(n) {
  const b = Number(n) || 0;
  if (b < 1024) return `${b}B`;
  if (b < 1024 * 1024) return `${Math.round(b / 1024)}KB`;
  return `${(b / 1024 / 1024).toFixed(1)}MB`;
}

// 送る前の確認（種類・大きさ）。だめなら理由つきで止める
export function checkChatFile(file) {
  if (!TYPES[file.type]) throw new Error(`「${file.name}」は送れません。送れるのはPDFと画像（JPEG・PNG・GIF・WebP）だけです。`);
  if (!file.size) throw new Error(`「${file.name}」は中身が空です。`);
  if (file.size > CHAT_MAX_BYTES) throw new Error(`「${file.name}」は10MBを超えています（${fmtSize(file.size)}）。`);
}
