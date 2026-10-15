-- 選考チャット: 相手の会社のメッセージには送信者の名前を返さない（2026-10-15 ユーザー指定）
-- 同じ側（自社）の同僚の名前は返す
set check_function_bodies = off;

create or replace function v2_thread_messages(p_app uuid, p_thread uuid, p_before timestamptz default null,
                                              p_before_id uuid default null, p_limit int default 200)
returns table (id uuid, side text, sender_name text, mine boolean, body text, stamp text, reply_to uuid,
               reactions jsonb, pinned boolean, edited boolean, deleted boolean, created_at timestamptz,
               read_by_other boolean, version int)
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
      (m.side = my_side and other_read is not null and other_read >= m.created_at), m.version
    from v2_messages m join v2_members mb on mb.id = m.sender_member_id
    where m.application_id = p_app and m.thread_company_id = p_thread
      and (p_before is null or (m.created_at, m.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by m.created_at desc, m.id desc limit least(greatest(p_limit, 1), 200)
  ) x order by x.created_at, x.id;
end $$;

