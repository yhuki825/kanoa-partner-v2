-- ============================================================
-- 選考チャットのファイル添付（2026-10-19 ユーザー要望「PDFや画像を双方とも送れるように」）
--  ・送れるもの: PDF・画像（JPEG/PNG/GIF/WebP）。1回に5ファイルまで、1ファイル10MBまで
--  ・置き場: v2-files の chat/{選考ID}/{会話の会社ID}/{ランダム}.{拡張子}（日本語のファイル名はDBにだけ持つ）
--  ・見られるのは、その会話の2社（v2_thread_side が通る人）だけ。削除したメッセージのファイルは誰も開けない
--  ・流れ: 画面がファイルを置く（その会話の人だけ置ける）→ v2_msg_send に置いた場所を渡す
--         → 関数が「本人が置いた・その会話の場所・10MB以下・PDF/画像」をサーバー側の記録で確かめてから紐づける
--  ・送信に失敗して紐づかなかったファイルは、置いた本人が消せる（画面が後始末する）
-- ============================================================
set check_function_bodies = off;

-- 置き場で受け付ける種類に GIF・WebP を足す（PDF・JPEG・PNG はすでにある）
update storage.buckets set allowed_mime_types = array(select distinct unnest(allowed_mime_types || array['image/gif','image/webp']))
where id = 'v2-files';

-- ---------- 添付ファイルの記録 ----------
alter table v2_messages add column file_count int not null default 0 check (file_count between 0 and 5);
alter table v2_messages drop constraint v2_messages_content;
alter table v2_messages add constraint v2_messages_content
  check (deleted or coalesce(nullif(trim(body), ''), stamp) is not null or file_count > 0);

create table v2_message_files (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references v2_messages(id) on delete cascade,
  application_id uuid not null references v2_applications(id) on delete cascade,
  thread_company_id uuid not null references v2_companies(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  size bigint not null check (size > 0 and size <= 10485760),
  mime text not null check (mime in ('application/pdf','image/jpeg','image/png','image/gif','image/webp')),
  storage_path text not null unique,
  uploaded_by uuid not null references v2_members(id),
  created_at timestamptz not null default now()
);
create index v2_message_files_msg on v2_message_files(message_id);
alter table v2_message_files enable row level security;
-- 読み取りは、その会話の人だけ（メッセージが削除されていないもの）。書き込みは関数だけ
create policy v2_message_files_sel on v2_message_files for select using (
  v2_thread_side(application_id, thread_company_id) is not null
  and exists (select 1 from v2_messages m where m.id = message_id and not m.deleted));
revoke insert, update, delete, truncate on v2_message_files from anon, authenticated;

-- ---------- 置き場の権限（chat/ 以下） ----------
-- その会話の場所か（chat/{選考ID}/{会話の会社ID}/{ファイル}。会話の人だけ true）
create or replace function v2_chat_path_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) <> 4 or parts[1] <> 'chat' or coalesce(parts[4], '') = '' then return false; end if;
  return v2_thread_side(parts[2]::uuid, parts[3]::uuid) is not null;
exception when others then return false;
end $$;
-- 開いてよいファイルか（会話の人で、紐づいたメッセージが削除されていない）
create or replace function v2_chat_file_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from v2_message_files f join v2_messages m on m.id = f.message_id
                 where f.storage_path = p_name and not m.deleted
                   and v2_thread_side(f.application_id, f.thread_company_id) is not null)
$$;
-- 送信に失敗して紐づかなかった、自分が置いたファイルか（後始末で消してよい）
create or replace function v2_chat_file_orphan(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from storage.objects o where o.bucket_id = 'v2-files' and o.name = p_name and o.owner_id = auth.uid()::text)
     and not exists (select 1 from v2_message_files f where f.storage_path = p_name)
$$;

create policy v2_files_chat_sel on storage.objects for select to authenticated using (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'chat' and v2_chat_file_visible(name));
create policy v2_files_chat_ins on storage.objects for insert to authenticated with check (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'chat' and v2_chat_path_ok(name));
create policy v2_files_chat_del on storage.objects for delete to authenticated using (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'chat' and v2_chat_file_orphan(name));

-- ---------- 送信（ファイルを添えられるように。引数 p_files を足すので古い版は消す） ----------
drop function if exists v2_msg_send(uuid, uuid, text, text, uuid);
create function v2_msg_send(p_app uuid, p_thread uuid, p_body text, p_stamp text default null, p_reply_to uuid default null,
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
    v_name := nullif(trim(coalesce(f->>'name', '')), '');
    if v_path is null or v_path not like 'chat/' || p_app || '/' || p_thread || '/%' or v_path = any(v_paths) then
      raise exception 'bad_file_path' using errcode = 'P0400', hint = '添付ファイルの置き場所が正しくありません。もう一度選び直してください';
    end if;
    select so.owner_id, (so.metadata->>'size')::bigint as size, so.metadata->>'mimetype' as mime into v_obj
    from storage.objects so where so.bucket_id = 'v2-files' and so.name = v_path;
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
    insert into v2_message_files(message_id, application_id, thread_company_id, name, size, mime, storage_path, uploaded_by)
    values (v_id, p_app, p_thread, left(coalesce(v_name, 'ファイル'), 200), v_obj.size, v_obj.mime, v_path, me);
    v_paths := v_paths || v_path;
  end loop;

  perform v2_thread_mark_read(p_app, p_thread);
  return v_id;
end $$;

-- ---------- 会話の読み込み（添付ファイルの一覧 files を足す。戻り値の形が変わるので作り直す） ----------
drop function if exists v2_thread_messages(uuid, uuid, timestamptz, uuid, int);
create function v2_thread_messages(p_app uuid, p_thread uuid, p_before timestamptz default null,
                                   p_before_id uuid default null, p_limit int default 200)
returns table (id uuid, side text, sender_name text, mine boolean, body text, stamp text, reply_to uuid,
               reactions jsonb, pinned boolean, edited boolean, deleted boolean, created_at timestamptz,
               read_by_other boolean, version int, files jsonb)
language plpgsql stable security definer set search_path = public as $$
declare my_side text := v2_thread_side(p_app, p_thread); me uuid := (v2_me()).id; other_read timestamptz;
begin
  if my_side is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りは見られません'; end if;
  select max(r.last_read_at) into other_read from v2_thread_reads r join v2_members mb on mb.id = r.member_id
  where r.application_id = p_app and r.thread_company_id = p_thread
    and ((my_side = 'self' and (mb.company_id is distinct from p_thread)) or (my_side = 'up' and mb.company_id = p_thread));
  return query
  select * from (
    select m.id, m.side,
      case when m.side = my_side then mb.name end,   -- 相手の会社の人の名前は返さない（2026-10-15 ユーザー指定）
      m.sender_member_id = me,
      case when m.deleted then null else m.body end, case when m.deleted then null else m.stamp end,
      m.reply_to, case when m.deleted then '[]'::jsonb else m.reactions end, m.pinned, m.edited, m.deleted, m.created_at,
      (m.side = my_side and other_read is not null and other_read >= m.created_at), m.version,
      -- 添付（削除したメッセージのものは返さない）
      case when m.deleted or m.file_count = 0 then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'size', f.size, 'mime', f.mime, 'path', f.storage_path)
                         order by f.created_at, f.id)
        from v2_message_files f where f.message_id = m.id), '[]'::jsonb) end
    from v2_messages m join v2_members mb on mb.id = m.sender_member_id
    where m.application_id = p_app and m.thread_company_id = p_thread
      and (p_before is null or (m.created_at, m.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by m.created_at desc, m.id desc limit least(greatest(p_limit, 1), 200)
  ) x order by x.created_at, x.id;
end $$;

-- ---------- 実行権限 ----------
revoke all on function v2_msg_send(uuid, uuid, text, text, uuid, jsonb), v2_thread_messages(uuid, uuid, timestamptz, uuid, int),
  v2_chat_path_ok(text), v2_chat_file_visible(text), v2_chat_file_orphan(text) from public, anon;
grant execute on function v2_msg_send(uuid, uuid, text, text, uuid, jsonb), v2_thread_messages(uuid, uuid, timestamptz, uuid, int),
  v2_chat_path_ok(text), v2_chat_file_visible(text), v2_chat_file_orphan(text) to authenticated;
