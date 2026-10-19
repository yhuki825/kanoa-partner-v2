-- 130_selection_filter.sql を元に戻す（選考一覧の絞り込みをやめる。一覧の関数は 130 適用前の本体そのまま。2026-10-19 にDBから読んだもの）
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- ※ 131_selection_filter_fixes.sql で増えた v2_selection_hits もここで消す（131 を当てていなくても動く）
drop function if exists v2_selection_counts(text, text);
drop function if exists v2_selection_list(text, text, int, int, text);
drop function if exists v2_selection_category(uuid, text, text);
drop function if exists v2_selection_hits(text, text);
CREATE OR REPLACE FUNCTION public.v2_selection_list(p_tab text, p_q text DEFAULT ''::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text, job_title text, client_name text, external_url text, source_label text, waiting_me boolean, holder_is_kanoa boolean, milestones jsonb, updated_at timestamp with time zone, total bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    select * from base where coalesce(p_q, '') = '' or cand_name ilike '%' || p_q || '%' or jt ilike '%' || p_q || '%' or cn ilike '%' || p_q || '%'
  )
  select h.id, h.kind, h.stage, h.result, h.candidate_id, h.cand_name, h.jt, h.cn, h.external_url,
    (select co.name || '（' || co.code || '）' from v2_application_parties p join v2_companies co on co.id = p.company_id
      where p.application_id = h.id and (case when h.is_ra then co.tier = 1 else co.parent_id = h.my_cid end) limit 1),
    h.wait_me, h.holder_company_id is null,
    (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'result', m.result, 'scheduled_on', m.scheduled_on, 'done_on', m.done_on) order by m.seq), '[]')
       from v2_milestones m where m.application_id = h.id),
    h.updated_at, count(*) over ()
  from hit h order by h.wait_me desc, h.updated_at desc
  limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$function$;
grant execute on function v2_selection_list(text, text, int, int) to anon, authenticated;
