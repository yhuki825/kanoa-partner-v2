// 選考チャットの添付ファイル（PDF・画像）。置き場は v2-files の chat/{選考ID}/{会話の会社ID}/{ランダム}.{拡張子}
// ・誰が置けて誰が開けるかはDB（置き場の権限）が判定する。ここは画面側の事前チェックと、開くためのURLだけ
// ・大きさ・種類はDBの送信関数も置き場の記録で確かめ直す（画面のチェックを抜けても通らない）
import { sb } from '../supabase.js';
import { userError } from './db.js';
import { TYPES, checkChatFile } from './chat-file-rules.js';
export { CHAT_MAX_FILES, CHAT_MAX_BYTES, CHAT_ACCEPT, isImage, fmtSize, checkChatFile } from './chat-file-rules.js';

const BUCKET = 'v2-files';

// 置く（送信の直前）。戻り値を v2_msg_send の p_files に渡す
export async function uploadChatFile(appId, threadId, file) {
  checkChatFile(file);
  const path = `chat/${appId}/${threadId}/${crypto.randomUUID()}${TYPES[file.type]}`;
  const up = await sb().storage.from(BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw userError(up.error, `「${file.name}」をアップロードできませんでした`);
  return { path, name: file.name };
}

// 送信に失敗したとき・メッセージを削除したときの後始末（紐づかなかった or 削除したメッセージの、自分のファイルだけDBが消すのを許す）
// 失敗しても例外は投げない（画面の本来のエラー表示を上書きしない）。消せなかった場所を返す（全部消せたら空の配列）
// 消し残しは、次に会話を開いたときに retryChatFileRemoval が消し直す
export async function removeChatFiles(paths, { quiet = false } = {}) {
  if (!paths.length) return [];
  try {
    const { data, error } = await sb().storage.from(BUCKET).remove(paths);
    if (error) { if (!quiet) console.warn('添付ファイルを置き場から消せませんでした', error); return [...paths]; }
    // 権限で消せなかったものはエラーにならず、消えた一覧に入らないだけなので、突き合わせる
    const gone = new Set((data || []).map((d) => d.name));
    const left = paths.filter((p) => !gone.has(p));
    if (left.length && !quiet) console.warn('添付ファイルの一部を置き場から消せませんでした', left);
    return left;
  } catch (e) {
    if (!quiet) console.warn('添付ファイルを置き場から消せませんでした', e);
    return [...paths];
  }
}

// 消し残しの消し直し（削除したメッセージのファイル・送信に紐づかないまま1時間を過ぎたファイル。自分が置いたものだけ）
// 会話を開いたときに1回だけ呼ぶ。うまくいかなくても何も表示しない（次の来訪でまた試す）
export async function retryChatFileRemoval(appId) {
  try {
    const { data, error } = await sb().rpc('v2_my_chat_files_pending_removal', { p_app: appId });
    if (error || !Array.isArray(data) || !data.length) return;
    await removeChatFiles(data.map((d) => (typeof d === 'string' ? d : d?.v2_my_chat_files_pending_removal)).filter(Boolean), { quiet: true });
  } catch { /* 黙って次回に回す */ }
}

// 開くためのURL（10分有効のものを8分使い回す。定期取得のたびに作り直さない。短くしておくのは、
// メッセージの削除で実体が消せなかった場合にも、手元に残ったURLで開ける時間を短くするため）
const cache = new Map();
export async function chatFileUrls(paths) {
  const now = Date.now();
  const need = [...new Set(paths)].filter((p) => !(cache.get(p)?.exp > now));
  if (need.length) {
    const { data, error } = await sb().storage.from(BUCKET).createSignedUrls(need, 600);
    if (!error) data.forEach((d) => { if (d.signedUrl && d.path) cache.set(d.path, { url: d.signedUrl, exp: now + 8 * 60 * 1000 }); });
  }
  return Object.fromEntries(paths.map((p) => [p, cache.get(p)?.url || null]));
}
export const cachedChatUrl = (path) => { const c = cache.get(path); return c && c.exp > Date.now() ? c.url : null; };
