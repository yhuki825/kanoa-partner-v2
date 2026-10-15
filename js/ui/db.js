// DB書き込みの共通部品
// ・更新は「変える列だけ」＋読んだときの version を送る（他人の変更を古い値で上書きしない）
// ・DBのエラーを日本語にして投げる（黙って失敗させない）
import { sb } from '../supabase.js';

export function userError(e, fallback = '保存に失敗しました') {
  if (!e) return new Error(fallback);
  const code = e.code || '';
  let msg;
  if (code === 'P0409') msg = '他の人が先に更新しました。画面を読み込み直してから、もう一度操作してください。';
  else if (code === 'P0403') msg = e.hint || 'この操作は権限がありません。';
  else if (code === '42501') msg = 'この操作は権限がありません。';
  else if (code === '23505') msg = '同じ内容がすでに登録されています。';
  else msg = `${fallback}（${e.message || code || '不明なエラー'}）`;
  const err = new Error(msg);
  err.detail = { code, message: e.message, hint: e.hint, details: e.details };
  return err;
}

// 1行を更新して、更新後の行を返す
export async function updateRow(table, row, patch) {
  const { data, error } = await sb().from(table)
    .update({ ...patch, version: row.version }).eq('id', row.id).select().single();
  if (error) throw userError(error);
  return data;
}

export async function insertRow(table, values) {
  const { data, error } = await sb().from(table).insert(values).select().single();
  if (error) throw userError(error);
  return data;
}

export async function deleteRow(table, id) {
  const { error } = await sb().from(table).delete().eq('id', id);
  if (error) throw userError(error, '削除に失敗しました');
}
