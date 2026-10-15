-- 修正: 外部求人の選考に「会話」が作れてしまっていた
-- 外部求人は登録した会社の中だけの選考なので、連絡の相手はいない（設計書 3.5 / Q1）
set check_function_bodies = off;
create or replace function v2_thread_side(p_app uuid, p_thread uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare my uuid := v2_my_company(); l record;
begin
  if exists (select 1 from v2_applications where id = p_app and kind = 'external') then return null; end if;
  select id, tier, parent_id into l from v2_companies where id = p_thread;
  if not found then return null; end if;
  if not exists (select 1 from v2_application_parties where application_id = p_app and company_id = p_thread) then
    return null;
  end if;
  if my is not null and my = p_thread then return 'self'; end if;
  if l.parent_id is not null then
    if my is not null and my = l.parent_id
       and exists (select 1 from v2_application_parties where application_id = p_app and company_id = my) then
      return 'up';
    end if;
  elsif v2_is_ra() and exists (select 1 from v2_applications where id = p_app and kanoa_visible) then
    return 'up';
  end if;
  return null;
end $$;
