-- 134: 求職者一覧の速さ（2026-10-19 ユーザー指摘「メニューの切り替えにラグ」）
--  原因: 一覧の関数が SECURITY INVOKER で、求職者・メモ・担当者の表の見える範囲（RLS）の判定を1行ごとに実行していた
--  直し方: SECURITY DEFINER にし、見える範囲は求職者の表の RLS（v2_candidates_sel = 自社の求職者 or 選考を通して見える）と
--        同じ条件を、自社・KANOAかどうかを1回だけ求めて当てる。メモは自社（KANOAは KANOA）のものだけ、
--        担当者の名前は自社の人（KANOAは全員）だけ。中身は前と同一（各アカウントで全列の md5 一致を確認）
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 戻すとき: 下の関数を 134 より前の本体（SECURITY INVOKER 版。104/106 の v2_candidate_list）に戻す
set check_function_bodies = off;

create or replace function public.v2_candidate_list(p_q text default '', p_limit int default 50, p_offset int default 0)
returns table (id uuid, name text, kana text, birth_date date, gender text, prefecture text, assigned_name text, memo text,
               created_at timestamptz, total bigint)
language sql stable security definer set search_path = public as $$
  with me as materialized (select v2_my_company() cid, v2_is_ra() ra),
  mine as (
    select c.*,
           case when me.ra or m.company_id = me.cid then m.name end as assigned_name,
           (select n.memo from v2_candidate_notes n where n.candidate_id = c.id
              and n.company_id is not distinct from (case when me.ra then null else me.cid end)) as memo
    from v2_candidates c
    cross join me
    left join v2_members m on m.id = c.assigned_member_id
    -- 見える範囲: v2_candidates_sel と同じ（自社の求職者 or 選考を通して見える）
    where (c.owner_company_id is not null and c.owner_company_id = me.cid)
       or (c.owner_company_id is null and me.ra)
       or exists (select 1 from v2_applications a join v2_application_parties p on p.application_id = a.id
                  where a.candidate_id = c.id and p.company_id = me.cid)
       or (me.ra and exists (select 1 from v2_applications a where a.candidate_id = c.id and a.kanoa_visible))
  ), hit as (
    select * from mine where coalesce(p_q, '') = ''
      or name ilike '%' || p_q || '%' or kana ilike '%' || p_q || '%'
      or coalesce(memo, '') ilike '%' || p_q || '%' or coalesce(recommendation, '') ilike '%' || p_q || '%'
      or phone_norm like '%' || regexp_replace(p_q, '[^0-9]', '', 'g') || '%' and regexp_replace(p_q, '[^0-9]', '', 'g') <> ''
  )
  select id, name, kana, birth_date, gender, prefecture, assigned_name, memo, created_at, count(*) over ()
  from hit order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$$;
revoke all on function public.v2_candidate_list(text, int, int) from public, anon;
grant execute on function public.v2_candidate_list(text, int, int) to authenticated;
