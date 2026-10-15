// 書類の保存・取得・削除（V2専用の非公開置き場 v2-files）
// パス: candidates/{求職者ID}/{ランダム}.{拡張子}（日本語のファイル名はDBにだけ持つ）
import { sb } from '../supabase.js';
import { S } from '../store.js';
import { userError } from './db.js';

const BUCKET = 'v2-files';
export const MAX_BYTES = 20 * 1024 * 1024;
export const ACCEPT = '.pdf,.jpg,.jpeg,.png,.heic,.doc,.docx,.xls,.xlsx';

export async function uploadCandidateFile(candidateId, kind, file) {
  if (file.size > MAX_BYTES) throw new Error(`「${file.name}」は20MBを超えています。`);
  const ext = (/\.[A-Za-z0-9]+$/.exec(file.name) || [''])[0].toLowerCase();
  const path = `candidates/${candidateId}/${crypto.randomUUID()}${ext}`;
  const up = await sb().storage.from(BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
  if (up.error) throw userError(up.error, `「${file.name}」をアップロードできませんでした`);
  const { data, error } = await sb().from('v2_candidate_files').insert({
    candidate_id: candidateId, kind, name: file.name, size: file.size, mime: file.type, storage_path: path,
    uploaded_by: S.member.id,
  }).select().single();
  if (error) {
    await sb().storage.from(BUCKET).remove([path]);   // 記録できなかったファイルを残さない
    throw userError(error, `「${file.name}」を登録できませんでした`);
  }
  return data;
}

export async function openFile(row) {
  const { data, error } = await sb().storage.from(BUCKET).createSignedUrl(row.storage_path, 300);
  if (error || !data?.signedUrl) throw userError(error, 'ファイルを開けませんでした');
  window.open(data.signedUrl, '_blank', 'noopener');
}

export async function deleteFile(row) {
  const { error } = await sb().from('v2_candidate_files').delete().eq('id', row.id);
  if (error) throw userError(error, '削除できませんでした');
  await sb().storage.from(BUCKET).remove([row.storage_path]);
}
