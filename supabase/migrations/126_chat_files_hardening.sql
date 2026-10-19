-- ============================================================
-- チャットの添付: 独立レビューの指摘への手直し（124・125 の続き。2026-10-19）
--  M1 送信後の中身のすり替え防止
--     ・送信時に置き場の記録の id（object_id）も一緒に覚え、開けるのは「その id の実体がまだその場所にある」ときだけ
--     ・送信済みの場所には、もう誰も置けない（置き直し・上書き（upsert）も含む）
--     ・送信の関数は、置き場の記録の行を押さえて（for update）から確かめ・紐づける
--       ※押さえる前に始まっていた削除は、押さえた後に終わる（その場合ファイルが見つからず送信は止まる）。
--         押さえた後に始まった削除は、送信の確定を待ってから進むことがある（その場合は添付が開けなくなるだけで、
--         上の2つにより別の中身に差し替わることはない）
--  M2 削除したメッセージのファイル・紐づかなかったファイルを、置いた本人の次の来訪で消し直せるようにする
--  L1 置ける場所の形を厳しくする（chat/{選考ID}/{会話の会社ID}/{ランダムなUUID}.{pdf|jpg|png|gif|webp}）
--  L7 ファイル名から文字の向きを変える制御文字（U+202A〜U+202E・U+2066〜U+2069）を取り除く
-- ============================================================
set check_function_bodies = off;

-- ---------- M1(a) 置き場の記録の id を持つ ----------
alter table v2_message_files add column object_id uuid;
-- すでに送ったものは、今その場所にある実体の id を入れる（実体が無いものは空のまま＝開けない）
update v2_message_files f set object_id = o.id
from storage.objects o where o.bucket_id = 'v2-files' and o.name = f.storage_path and f.object_id is null;

-- ---------- M1(c)・L1 置ける場所 ----------
create or replace function v2_chat_path_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) is distinct from 4 or parts[1] <> 'chat' then return false; end if;
  -- 選考ID・会話の会社IDは、UUIDの正規の形（小文字・ハイフン入り）だけ
  if parts[2] <> parts[2]::uuid::text or parts[3] <> parts[3]::uuid::text then return false; end if;
  -- ファイル名は「ランダムなUUID＋拡張子」だけ（画面は crypto.randomUUID() と決まった拡張子で作る）
  if parts[4] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png|gif|webp)$' then return false; end if;
  -- 送信済みの場所には置けない（消してから置き直して中身を差し替えるのを防ぐ）
  if exists (select 1 from v2_message_files where storage_path = p_name) then return false; end if;
  return v2_thread_side(parts[2]::uuid, parts[3]::uuid) is not null;
exception when others then return false;
end $$;

-- ---------- M1(b) 開けるのは、送信時に確かめた実体（同じ id）がまだその場所にあるときだけ ----------
create or replace function v2_chat_file_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from v2_message_files f join v2_messages m on m.id = f.message_id
                 where f.storage_path = p_name and not m.deleted
                   and exists (select 1 from storage.objects o
                               where o.id = f.object_id and o.bucket_id = 'v2-files' and o.name = f.storage_path)
                   and v2_thread_side(f.application_id, f.thread_company_id) is not null)
$$;

-- ---------- M1(a)(d)・L7 送信（引数は 124 と同じ。本体だけ差し替える） ----------
create or replace function v2_msg_send(p_app uuid, p_thread uuid, p_body text, p_stamp text default null, p_reply_to uuid default null,
                                       p_files jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s text := v2_thread_side(p_app, p_thread); v_id uuid; v_body text := nullif(trim(coalesce(p_body, '')), '');
        v_n int := 0; f jsonb; v_obj record; v_path text; v_name text; v_paths text[] := '{}'; me uuid := (v2_me()).id;
begin
  if s is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りには書き込めません'; end if;
  if p_stamp is not null and p_stamp not in ('👍','🙏','🎉','💪','😄','🙇','✨','⭕','❌','⏰') then
    raise exception 'bad_stamp' using errcode = 'P0400', hint = 'このスタンプは使えません';
  end if;
  if p_files is not null and jsonb_typeof(p_files) <> 'array' then
    raise exception 'bad_files' using errcode = 'P0400', hint = '添付ファイルの指定が正しくありません';
  end if;
  v_n := coalesce(jsonb_array_length(p_files), 0);
  if v_n > 5 then
    raise exception 'too_many_files' using errcode = 'P0400', hint = '一度に送れるファイルは5つまでです';
  end if;
  if v_n > 0 and p_stamp is not null then
    raise exception 'stamp_with_files' using errcode = 'P0400', hint = 'スタンプとファイルは一緒に送れません';
  end if;
  if v_body is null and p_stamp is null and v_n = 0 then
    raise exception 'empty' using errcode = 'P0400', hint = 'メッセージ・スタンプ・ファイルのどれかを送ってください';
  end if;
  if v_body is not null and p_stamp is not null then
    raise exception 'empty' using errcode = 'P0400', hint = 'メッセージかスタンプのどちらか一方を送ってください';
  end if;
  if p_reply_to is not null and not exists (select 1 from v2_messages where id = p_reply_to and application_id = p_app and thread_company_id = p_thread) then
    raise exception 'bad_reply' using errcode = 'P0400';
  end if;

  insert into v2_messages(application_id, thread_company_id, sender_member_id, side, body, stamp, reply_to, file_count)
  values (p_app, p_thread, me, s, v_body, p_stamp, p_reply_to, v_n) returning id into v_id;

  -- 添付: 置いた場所・本人・大きさ・種類は、画面の申告ではなく置き場の記録で確かめる
  for f in select * from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) loop
    v_path := f->>'path';
    -- 文字の向きを変える制御文字は取り除く（ファイル名の見た目で拡張子を偽らせない）
    v_name := nullif(trim(regexp_replace(coalesce(f->>'name', ''), '[‪-‮⁦-⁩]', '', 'g')), '');
    if v_path is null or v_path not like 'chat/' || p_app || '/' || p_thread || '/%' or v_path = any(v_paths) then
      raise exception 'bad_file_path' using errcode = 'P0400', hint = '添付ファイルの置き場所が正しくありません。もう一度選び直してください';
    end if;
    -- 置き場の記録の行を押さえてから確かめる（確かめてから紐づけるまでの間に消されないように）
    select so.id, so.owner_id, (so.metadata->>'size')::bigint as size, so.metadata->>'mimetype' as mime into v_obj
    from storage.objects so where so.bucket_id = 'v2-files' and so.name = v_path
    for update;
    if not found or v_obj.owner_id is distinct from auth.uid()::text then
      raise exception 'bad_file' using errcode = 'P0400', hint = '添付ファイルが見つかりません。もう一度選び直してください';
    end if;
    if v_obj.size is null or v_obj.size > 10485760 then
      raise exception 'file_too_large' using errcode = 'P0400', hint = '1つのファイルは10MBまでです';
    end if;
    if v_obj.mime is null or v_obj.mime not in ('application/pdf','image/jpeg','image/png','image/gif','image/webp') then
      raise exception 'bad_file_type' using errcode = 'P0400', hint = '送れるのはPDFと画像（JPEG・PNG・GIF・WebP）だけです';
    end if;
    if exists (select 1 from v2_message_files where storage_path = v_path) then
      raise exception 'file_used' using errcode = 'P0400', hint = 'このファイルはすでに送信済みです';
    end if;
    insert into v2_message_files(message_id, application_id, thread_company_id, name, size, mime, storage_path, uploaded_by, object_id)
    values (v_id, p_app, p_thread, left(coalesce(v_name, 'ファイル'), 200), v_obj.size, v_obj.mime, v_path, me, v_obj.id);
    v_paths := v_paths || v_path;
  end loop;

  perform v2_thread_mark_read(p_app, p_thread);
  return v_id;
end $$;

-- ---------- M2(b) 置き場から消し直すべき、自分が置いたファイル ----------
-- 削除したメッセージのもの・送信に紐づかないまま1時間を過ぎたもの。返すのは自分が置いたものだけ
-- （画面は会話を開いたときに1回呼び、返った場所を置き場の削除で消す。消せるかどうかは置き場の権限が改めて判定する）
create or replace function v2_my_chat_files_pending_removal(p_app uuid) returns setof text
language sql stable security definer set search_path = public as $$
  select o.name from storage.objects o
  where auth.uid() is not null
    and o.bucket_id = 'v2-files' and o.owner_id = auth.uid()::text
    and o.name like 'chat/' || p_app::text || '/%'
    and (exists (select 1 from v2_message_files f join v2_messages m on m.id = f.message_id
                 where f.storage_path = o.name and m.deleted)
         or (not exists (select 1 from v2_message_files f where f.storage_path = o.name)
             and o.created_at < now() - interval '1 hour'))
  order by o.created_at
  limit 1000
$$;

-- ---------- 実行権限（124 と同じ。新しい関数も同じ扱い） ----------
revoke all on function v2_msg_send(uuid, uuid, text, text, uuid, jsonb), v2_chat_path_ok(text), v2_chat_file_visible(text),
  v2_my_chat_files_pending_removal(uuid) from public, anon;
grant execute on function v2_msg_send(uuid, uuid, text, text, uuid, jsonb), v2_chat_path_ok(text), v2_chat_file_visible(text),
  v2_my_chat_files_pending_removal(uuid) to authenticated;
