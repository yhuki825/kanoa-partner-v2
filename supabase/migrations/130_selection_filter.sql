-- 選考一覧の絞り込み（2026-10-19 ユーザー要望）: 全て／選考応募前／選考中／内定獲得／落選・辞退
--  before = 選考応募前（リレー中: 直上・KANOAの受入待ち）
--  offer  = 内定獲得（名前に「内定」を含む段階を通過した進行中の選考、または全段階を通過して完了＝入社）
--  lost   = 落選・辞退（見送り・辞退・不通過）
--  active = 選考中（上のどれでもない進行中の選考）
set check_function_bodies = off;

create or replace function v2_selection_category(p_id uuid, p_stage text, p_result text) returns text
language sql stable set search_path = public as $$
  select case
    when p_stage = 'relay' then 'before'
    when p_stage in ('rejected', 'withdrawn') or (p_stage = 'closed' and p_result = 'failed') then 'lost'
    when p_stage = 'closed' then 'offer'
    when exists (select 1 from v2_milestones m where m.application_id = p_id and m.result = 'passed' and m.name like '%内定%') then 'offer'
    else 'active' end
$$;

drop function if exists v2_selection_list(text, text, int, int);
create function v2_selection_list(p_tab text, p_q text default '', p_limit int default 50, p_offset int default 0,
                                  p_filter text default 'all')
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text,
               client_name text, external_url text, source_label text, waiting_me boolean, holder_is_kanoa boolean,
               milestones jsonb, updated_at timestamptz, total bigint)
language sql stable set search_path = public as $$
  with me as (select v2_my_company() cid, v2_is_ra() ra),
  base as (
    select a.*, c.name as cand_name,
           coalesce(j.title, a.external_title, '（求人名なし）') as jt,
           coalesce(cl.name, a.external_company, '') as cn,
           (a.stage = 'relay' and ((me.ra and a.holder_company_id is null) or a.holder_company_id = me.cid)) as wait_me,
           me.ra as is_ra, me.cid as my_cid
    from v2_applications a
    join v2_candidates c on c.id = a.candidate_id
    left join v2_jobs j on j.id = a.job_id
    left join v2_clients cl on cl.id = j.client_id
    cross join me
    where case when p_tab = 'mine'
               then (case when me.ra then a.applied_by_company is null else a.applied_by_company = me.cid end)
               else (case when me.ra then a.applied_by_company is not null and a.kanoa_visible
                          else a.applied_by_company is distinct from me.cid end) end
  ), hit as (
    select * from base
    where (coalesce(p_q, '') = '' or cand_name ilike '%' || p_q || '%' or jt ilike '%' || p_q || '%' or cn ilike '%' || p_q || '%')
      and (coalesce(p_filter, 'all') = 'all' or v2_selection_category(base.id, base.stage, base.result) = p_filter)
  )
  select h.id, h.kind, h.stage, h.result, h.candidate_id, h.cand_name, h.jt, h.cn, h.external_url,
    (select co.name || '（' || co.code || '）' from v2_application_parties p join v2_companies co on co.id = p.company_id
      where p.application_id = h.id and (case when h.is_ra then co.tier = 1 else co.parent_id = h.my_cid end) limit 1),
    h.wait_me, h.holder_company_id is null,
    (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'result', m.result, 'scheduled_on', m.scheduled_on, 'done_on', m.done_on) order by m.seq), '[]')
       from v2_milestones m where m.application_id = h.id),
    h.updated_at, count(*) over ()
  from hit h order by h.wait_me desc, h.updated_at desc
  limit least(greatest(p_limit, 1), case when p_limit >= 200000 then 200000 else 200 end) offset greatest(p_offset, 0)
$$;

-- 絞り込みの件数（タブと検索語は一覧と同じ条件）
create or replace function v2_selection_counts(p_tab text, p_q text default '')
returns table (category text, n bigint)
language sql stable set search_path = public as $$
  select v2_selection_category(x.id, x.stage, x.result), count(*)
  from v2_selection_list(p_tab, p_q, 200000, 0, 'all') x
  group by 1
$$;

revoke all on function v2_selection_category(uuid, text, text), v2_selection_list(text, text, int, int, text),
  v2_selection_counts(text, text) from public, anon;
grant execute on function v2_selection_category(uuid, text, text), v2_selection_list(text, text, int, int, text),
  v2_selection_counts(text, text) to authenticated;
