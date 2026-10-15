-- 修正: 求職者の登録直後の読み返しが拒否される問題
-- 原因: 読み取りの権限判定が「表から同じ行を探し直す」関数だったため、
--       登録と同じ瞬間にはまだその行が見えず、拒否されていた（INSERT ... RETURNING）
-- 対処: 行そのものの持ち主の欄で判定する（第3段階で「届いた選考」の条件を or で足す）
drop policy if exists v2_candidates_sel on v2_candidates;
drop policy if exists v2_candidates_upd on v2_candidates;

create or replace function v2_owns(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (p_owner is not null and p_owner = v2_my_company()) or (p_owner is null and v2_is_ra())
$$;
grant execute on function v2_owns(uuid) to authenticated;

create policy v2_candidates_sel on v2_candidates for select using (v2_owns(owner_company_id));
create policy v2_candidates_upd on v2_candidates for update
  using (v2_owns(owner_company_id)) with check (v2_owns(owner_company_id));
