-- 131: 選考一覧の絞り込み（130）の手直し（レビュー 2026-10-19）
-- M1  v2_selection_list の p_limit に 200000 を渡すと 200 件の上限を超えられた → 上限は常に 200
-- M2  v2_selection_counts が件数を数えるためだけに一覧の全列（紹介元・進み具合）を全行ぶん作っていた
--     → 見える範囲・タブ・検索の判定だけを持つ軽い関数 v2_selection_hits に切り出し、一覧も件数もこれを使う
-- L3  終わった選考（closed）を「内定獲得」にするのは全段階を通過した（result = 'passed'）ときだけ
-- ※ v2_selection_hits / v2_selection_category は呼び出し元に展開（インライン化）されるよう、
--    SECURITY INVOKER・search_path 指定なし・参照先はすべて public. 付きにしている
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 戻すときは 130_selection_filter.down.sql（131 で増えた v2_selection_hits も消す）
set check_function_bodies = off;

create or replace function public.v2_selection_category(p_id uuid, p_stage text, p_result text) returns text
language sql stable as $$
  select case
    when p_stage = 'relay' then 'before'
    when p_stage in ('rejected', 'withdrawn') or (p_stage = 'closed' and p_result = 'failed') then 'lost'
    when p_stage = 'closed' and p_result = 'passed' then 'offer'
    when exists (select 1 from public.v2_milestones m where m.application_id = p_id and m.result = 'passed' and m.name like '%内定%') then 'offer'
    else 'active' end
$$;

-- タブ（見える範囲）と検索語に当たる選考。一覧と件数の共通の土台
create or replace function public.v2_selection_hits(p_tab text, p_q text)
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text,
               client_name text, external_url text, wait_me boolean, holder_company_id uuid, updated_at timestamptz,
               is_ra boolean, my_cid uuid)
language sql stable security invoker as $$
  with me as (select public.v2_my_company() cid, public.v2_is_ra() ra),
  base as (
    select a.id, a.kind, a.stage, a.result, a.candidate_id, c.name as cand_name,
           coalesce(j.title, a.external_title, '（求人名なし）') as jt,
           coalesce(cl.name, a.external_company, '') as cn,
           a.external_url,
           (a.stage = 'relay' and ((me.ra and a.holder_company_id is null) or a.holder_company_id = me.cid)) as wait_me,
           a.holder_company_id, a.updated_at,
           me.ra as is_ra, me.cid as my_cid
    from public.v2_applications a
    join public.v2_candidates c on c.id = a.candidate_id
    left join public.v2_jobs j on j.id = a.job_id
    left join public.v2_clients cl on cl.id = j.client_id
    cross join me
    where case when p_tab = 'mine'
               then (case when me.ra then a.applied_by_company is null else a.applied_by_company = me.cid end)
               else (case when me.ra then a.applied_by_company is not null and a.kanoa_visible
                          else a.applied_by_company is distinct from me.cid end) end
  )
  select * from base
  where coalesce(p_q, '') = '' or cand_name ilike '%' || p_q || '%' or jt ilike '%' || p_q || '%' or cn ilike '%' || p_q || '%'
$$;

-- 一覧（引数・列・並び・total は 130 と同じ。上限は常に 200 件）
create or replace function public.v2_selection_list(p_tab text, p_q text default '', p_limit int default 50, p_offset int default 0,
                                                    p_filter text default 'all')
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text,
               client_name text, external_url text, source_label text, waiting_me boolean, holder_is_kanoa boolean,
               milestones jsonb, updated_at timestamptz, total bigint)
language sql stable set search_path = public as $$
  select h.id, h.kind, h.stage, h.result, h.candidate_id, h.candidate_name, h.job_title, h.client_name, h.external_url,
    (select co.name || '（' || co.code || '）' from public.v2_application_parties p join public.v2_companies co on co.id = p.company_id
      where p.application_id = h.id and (case when h.is_ra then co.tier = 1 else co.parent_id = h.my_cid end) limit 1),
    h.wait_me, h.holder_company_id is null,
    (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'result', m.result, 'scheduled_on', m.scheduled_on, 'done_on', m.done_on) order by m.seq), '[]')
       from public.v2_milestones m where m.application_id = h.id),
    h.updated_at, count(*) over ()
  from public.v2_selection_hits(p_tab, p_q) h
  where coalesce(p_filter, 'all') = 'all' or public.v2_selection_category(h.id, h.stage, h.result) = p_filter
  order by h.wait_me desc, h.updated_at desc
  limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$$;

-- 絞り込みの件数（タブと検索語は一覧と同じ条件。一覧の列は作らない）
create or replace function public.v2_selection_counts(p_tab text, p_q text default '')
returns table (category text, n bigint)
language sql stable set search_path = public as $$
  select public.v2_selection_category(h.id, h.stage, h.result), count(*)
  from public.v2_selection_hits(p_tab, p_q) h
  group by 1
$$;

revoke all on function public.v2_selection_category(uuid, text, text), public.v2_selection_hits(text, text),
  public.v2_selection_list(text, text, int, int, text), public.v2_selection_counts(text, text) from public, anon;
grant execute on function public.v2_selection_category(uuid, text, text), public.v2_selection_hits(text, text),
  public.v2_selection_list(text, text, int, int, text), public.v2_selection_counts(text, text) to authenticated;
