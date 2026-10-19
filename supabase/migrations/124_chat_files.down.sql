-- 124_chat_files.sql を元に戻す（チャットのファイル添付をやめる。125・126 の手直しも一緒に戻す）
-- ※ v2_msg_send と v2_thread_messages は、124 適用前にDBから読んだ本体そのまま（2026-10-19）
--    prosrc の md5: v2_msg_send=e9f36810f11c982da39169f3cc0a7fd0, v2_thread_messages=f3334b4c1b86f7da4e3510a5c3431021
-- ※ 置いたファイル（v2-files の chat/ 以下）は消えない。必要ならストレージの画面から消す
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 126: 消し残しの一覧の関数（v2_message_files.object_id は下の drop table で一緒に消える）
drop function if exists v2_my_chat_files_pending_removal(uuid);
drop policy if exists v2_files_chat_sel on storage.objects;
drop policy if exists v2_files_chat_ins on storage.objects;
drop policy if exists v2_files_chat_del on storage.objects;
drop function if exists v2_msg_send(uuid, uuid, text, text, uuid, jsonb);
drop function if exists v2_thread_messages(uuid, uuid, timestamptz, uuid, int);
drop function if exists v2_chat_path_ok(text), v2_chat_file_visible(text), v2_chat_file_orphan(text);
drop table if exists v2_message_files;
-- ファイルだけのメッセージは、戻すと制約に反するので「削除済み」にする（行は消さない）
update v2_messages set deleted = true, pinned = false, version = version where file_count > 0 and coalesce(nullif(trim(body), ''), stamp) is null and not deleted;
alter table v2_messages drop constraint v2_messages_content;
alter table v2_messages add constraint v2_messages_content check (deleted or coalesce(nullif(trim(body), ''), stamp) is not null);
alter table v2_messages drop column file_count;
-- 置き場で受け付ける種類から、124 で足した GIF・WebP を外す（ほかの種類と並び順はそのまま）
update storage.buckets set allowed_mime_types = array(
  select m from unnest(allowed_mime_types) with ordinality as t(m, i) where m not in ('image/gif','image/webp') order by i)
where id = 'v2-files';
CREATE OR REPLACE FUNCTION public.v2_msg_send(p_app uuid, p_thread uuid, p_body text, p_stamp text DEFAULT NULL::text, p_reply_to uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := v2_thread_side(p_app, p_thread); v_id uuid; v_body text := nullif(trim(coalesce(p_body, '')), '');
begin
  if s is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りには書き込めません'; end if;
  if p_stamp is not null and p_stamp not in ('👍','🙏','🎉','💪','😄','🙇','✨','⭕','❌','⏰') then
    raise exception 'bad_stamp' using errcode = 'P0400', hint = 'このスタンプは使えません';
  end if;
  if (v_body is null) = (p_stamp is null) then
    raise exception 'empty' using errcode = 'P0400', hint = 'メッセージかスタンプのどちらか一方を送ってください';
  end if;
  if p_reply_to is not null and not exists (select 1 from v2_messages where id = p_reply_to and application_id = p_app and thread_company_id = p_thread) then
    raise exception 'bad_reply' using errcode = 'P0400';
  end if;
  insert into v2_messages(application_id, thread_company_id, sender_member_id, side, body, stamp, reply_to)
  values (p_app, p_thread, (v2_me()).id, s, v_body, p_stamp, p_reply_to) returning id into v_id;
  perform v2_thread_mark_read(p_app, p_thread);
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.v2_thread_messages(p_app uuid, p_thread uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200)
 RETURNS TABLE(id uuid, side text, sender_name text, mine boolean, body text, stamp text, reply_to uuid, reactions jsonb, pinned boolean, edited boolean, deleted boolean, created_at timestamp with time zone, read_by_other boolean, version integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      (m.side = my_side and other_read is not null and other_read >= m.created_at), m.version
    from v2_messages m join v2_members mb on mb.id = m.sender_member_id
    where m.application_id = p_app and m.thread_company_id = p_thread
      and (p_before is null or (m.created_at, m.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by m.created_at desc, m.id desc limit least(greatest(p_limit, 1), 200)
  ) x order by x.created_at, x.id;
end $function$;

revoke all on function v2_msg_send(uuid, uuid, text, text, uuid), v2_thread_messages(uuid, uuid, timestamptz, uuid, int) from public, anon;
grant execute on function v2_msg_send(uuid, uuid, text, text, uuid), v2_thread_messages(uuid, uuid, timestamptz, uuid, int) to authenticated;
-- （125・126 の手直しも上の drop policy／drop function／drop table で一緒に消える）
