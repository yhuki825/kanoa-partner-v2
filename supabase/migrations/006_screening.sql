-- 選考ステータスをV1のキー体系に統一（entry/screening/interview/offer/joined/rejected/declined）
set check_function_bodies = off;

update candidates set status = 'entry' where status = '確認中';

create or replace function v2_relay_decide(p_candidate uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := v2_company_id();
  v_cand candidates%rowtype;
  v_next uuid;
begin
  select * into v_cand from candidates where id = p_candidate for update;
  if not found then raise exception 'candidate not found'; end if;
  if v_cand.stage <> 'relay' then raise exception 'not in relay stage'; end if;

  if v_company is not null then
    if v_cand.holder_id is distinct from v_company then raise exception 'not the holder'; end if;
    if p_action = 'accept' then raise exception 'accept is KANOA only'; end if;
  elsif v2_is_admin() then
    if v_cand.holder_id is not null then raise exception 'not arrived at KANOA'; end if;
  else
    raise exception 'not authorized';
  end if;

  if p_action = 'forward' then
    select parent_id into v_next from companies where id = v_cand.holder_id;
    update candidates set holder_id = v_next where id = p_candidate;
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, v_company, 'forwarded', p_note);
  elsif p_action = 'reject' then
    update candidates set stage = 'rejected' where id = p_candidate;
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, v_company, 'rejected', p_note);
  elsif p_action = 'accept' then
    update candidates set stage = 'screening', status = coalesce(status, 'entry'), seen_kanoa = false
    where id = p_candidate;
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, null, 'accepted', p_note);
  else
    raise exception 'unknown action: %', p_action;
  end if;
end $$;
