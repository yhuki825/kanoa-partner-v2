-- 選考チャットのタブ順を直す（アップラインとの連絡 → 紹介元との連絡）
set check_function_bodies = off;

create or replace function v2_my_threads(p_app uuid)
returns table (thread_company_id uuid, my_side text, partner_label text, unread bigint, last_read_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := (v2_me()).id;
begin
  return query
  select p.company_id, s.side,
    case when s.side = 'self'
         then coalesce((select up.name || '（' || up.code || '）' from v2_companies up where up.id = c.parent_id), 'KANOA')
         else c.name || '（' || c.code || '）' end,
    (select count(*) from v2_messages m where m.application_id = p_app and m.thread_company_id = p.company_id
       and m.side <> s.side and not m.deleted
       and m.created_at > coalesce((select r.last_read_at from v2_thread_reads r where r.application_id = p_app
                                    and r.thread_company_id = p.company_id and r.member_id = me), '-infinity')),
    (select r.last_read_at from v2_thread_reads r where r.application_id = p_app and r.thread_company_id = p.company_id and r.member_id = me)
  from v2_application_parties p
  join v2_companies c on c.id = p.company_id
  cross join lateral (select v2_thread_side(p_app, p.company_id) as side) s
  where p.application_id = p_app and s.side is not null
  order by (s.side = 'self') desc;   -- 「アップラインとの連絡」を先、「紹介元との連絡」を後に
end $$;

