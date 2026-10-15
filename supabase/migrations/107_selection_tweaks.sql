-- 選考の小修正
-- 1) 経路の記録: 段階の結果・外部求人の登録は「コメント」ではなく事実なので、全員に見せる
-- 2) 判断待ちの件数（メニューのバッジ・ホームの「今日やること」用）
set check_function_bodies = off;

create or replace function v2_application_events_for(p_app uuid)
returns table (action text, company_id uuid, company_label text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare my uuid := v2_my_company(); ra boolean := v2_is_ra(); my_parent uuid;
begin
  if not v2_app_visible(p_app) then return; end if;
  select parent_id into my_parent from v2_companies where id = my;
  return query
  select e.action, e.company_id,
    case when e.company_id is null then 'KANOA'
         when e.company_id = my then '自社'
         when ra or co.parent_id = my then co.name || '（' || co.code || '）'
         when e.company_id = my_parent then 'アップライン'
         else 'パートナー' end,
    case when e.action in ('milestone','registered_external') then e.note
         when ra or e.company_id is not distinct from my
           or e.company_id = my_parent or co.parent_id = my
           or (e.company_id is null and my_parent is null)
         then e.note else null end,
    e.created_at
  from v2_application_events e left join v2_companies co on co.id = e.company_id
  where e.application_id = p_app order by e.created_at;
end $$;

create or replace function v2_waiting_count() returns bigint
language sql stable security invoker set search_path = public as $$
  select count(*) from v2_applications a
  where a.stage = 'relay' and (
    (v2_is_ra() and a.holder_company_id is null and a.kanoa_visible)
    or (a.holder_company_id is not null and a.holder_company_id = v2_my_company()))
$$;
grant execute on function v2_waiting_count() to authenticated;
