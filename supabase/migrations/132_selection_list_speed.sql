-- 132: 選考一覧の速さ（2026-10-19 ユーザー指摘「絞り込みのたびに読み込み中が出る」）
--  原因: 一覧が求職者・選考の段階などの表の「見える範囲（RLS）」の判定を1行ごとに実行していた（判定の関数が行ごとに
--        会社・KANOAかどうかを引き直す）。実測で1回あたり約0.15〜0.3秒、データが増えるほど遅くなる
--  直し方: 一覧・件数・土台の関数を SECURITY DEFINER にし、見える範囲は選考の表の RLS（v2_applications_sel）と
--        同じ条件を、自社・KANOAかどうかを1回だけ求めてから明示的に当てる。求職者・求人・段階・紹介元は、
--        見える選考に付いているものだけを読む（RLS と同じ範囲。求職者は「選考を通して見える」、段階は「選考が見える」）
--  見える範囲は変えない（直す前と後で、A社・RA の一覧の全列の md5 が一致することを確認）
--  土台（v2_selection_hits）と分類（v2_selection_category）は一覧・件数の中からだけ使う（画面からは呼べない）
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 戻すときは 131_selection_filter_fixes.sql を流し直す（関数の引数・列は同じ）
set check_function_bodies = off;

create or replace function public.v2_selection_category(p_id uuid, p_stage text, p_result text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_stage = 'relay' then 'before'
    when p_stage in ('rejected', 'withdrawn') or (p_stage = 'closed' and p_result = 'failed') then 'lost'
    when p_stage = 'closed' and p_result = 'passed' then 'offer'
    when exists (select 1 from v2_milestones m where m.application_id = p_id and m.result = 'passed' and m.name like '%内定%') then 'offer'
    else 'active' end
$$;

create or replace function public.v2_selection_hits(p_tab text, p_q text)
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text,
               client_name text, external_url text, wait_me boolean, holder_company_id uuid, updated_at timestamptz,
               is_ra boolean, my_cid uuid)
language sql stable security definer set search_path = public as $$
  with me as materialized (select v2_my_company() cid, v2_is_ra() ra),
  base as (
    select a.id, a.kind, a.stage, a.result, a.candidate_id, c.name as cand_name,
           coalesce(j.title, a.external_title, '（求人名なし）') as jt,
           coalesce(cl.name, a.external_company, '') as cn,
           a.external_url,
           (a.stage = 'relay' and ((me.ra and a.holder_company_id is null) or a.holder_company_id = me.cid)) as wait_me,
           a.holder_company_id, a.updated_at,
           me.ra as is_ra, me.cid as my_cid
    from v2_applications a
    join v2_candidates c on c.id = a.candidate_id
    left join v2_jobs j on j.id = a.job_id
    left join v2_clients cl on cl.id = j.client_id
    cross join me
    -- 見える範囲: v2_applications_sel と同じ（経路上の会社 or KANOAに届いた選考をRAが）
    where (exists (select 1 from v2_application_parties p where p.application_id = a.id and p.company_id = me.cid)
           or (me.ra and a.kanoa_visible))
      and case when p_tab = 'mine'
               then (case when me.ra then a.applied_by_company is null else a.applied_by_company = me.cid end)
               else (case when me.ra then a.applied_by_company is not null and a.kanoa_visible
                          else a.applied_by_company is distinct from me.cid end) end
  )
  select * from base
  where coalesce(p_q, '') = '' or cand_name ilike '%' || p_q || '%' or jt ilike '%' || p_q || '%' or cn ilike '%' || p_q || '%'
$$;

create or replace function public.v2_selection_list(p_tab text, p_q text default '', p_limit int default 50, p_offset int default 0,
                                                    p_filter text default 'all')
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text,
               client_name text, external_url text, source_label text, waiting_me boolean, holder_is_kanoa boolean,
               milestones jsonb, updated_at timestamptz, total bigint)
language sql stable security definer set search_path = public as $$
  select h.id, h.kind, h.stage, h.result, h.candidate_id, h.candidate_name, h.job_title, h.client_name, h.external_url,
    (select co.name || '（' || co.code || '）' from v2_application_parties p join v2_companies co on co.id = p.company_id
      where p.application_id = h.id and (case when h.is_ra then co.tier = 1 else co.parent_id = h.my_cid end) limit 1),
    h.wait_me, h.holder_company_id is null,
    (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'result', m.result, 'scheduled_on', m.scheduled_on, 'done_on', m.done_on) order by m.seq), '[]')
       from v2_milestones m where m.application_id = h.id),
    h.updated_at, count(*) over ()
  from v2_selection_hits(p_tab, p_q) h
  where coalesce(p_filter, 'all') = 'all' or v2_selection_category(h.id, h.stage, h.result) = p_filter
  order by h.wait_me desc, h.updated_at desc
  limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$$;

create or replace function public.v2_selection_counts(p_tab text, p_q text default '')
returns table (category text, n bigint)
language sql stable security definer set search_path = public as $$
  select v2_selection_category(h.id, h.stage, h.result), count(*)
  from v2_selection_hits(p_tab, p_q) h
  group by 1
$$;

revoke all on function public.v2_selection_category(uuid, text, text), public.v2_selection_hits(text, text)
  from public, anon, authenticated;
revoke all on function public.v2_selection_list(text, text, int, int, text), public.v2_selection_counts(text, text) from public, anon;
grant execute on function public.v2_selection_list(text, text, int, int, text), public.v2_selection_counts(text, text) to authenticated;
