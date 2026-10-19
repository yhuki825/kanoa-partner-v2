-- 135: 未読の連絡の件数（v2_chat_unread）の速さ（2026-10-19 ユーザー指摘「メニューの切り替えにラグ」）
--  原因: 関係する会話ごとに v2_thread_side（中で表を何度も引く）と、自社・KANOAかどうかの判定を1行ごとに実行していた
--        （KANOAで約0.2秒。メニューのバッジ・ホーム・選考の画面で毎回呼ばれる）
--  直し方: 自社・KANOAかどうか・自分を1回だけ求め、v2_thread_side と同じ条件（外部求人は対象外／会話の会社が経路上にいる／
--        上側に届いている／自社なら self・直上なら up・KANOAなら1次の会話で up）をまとめて当てる
--        結果は前と同一（各アカウントで md5 一致を確認）
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
set check_function_bodies = off;

create or replace function public.v2_chat_unread()
returns table (application_id uuid, unread bigint)
language sql stable security definer set search_path = public as $$
  with me as materialized (select v2_my_company() cid, v2_is_ra() ra, (v2_me()).id mid),
  th as (
    select p.application_id, p.company_id as tid,
           case when me.cid is not null and p.company_id = me.cid then 'self'
                when co.parent_id is not null and me.cid is not null and co.parent_id = me.cid then 'up'
                when co.parent_id is null and me.ra then 'up' end as side
    from v2_application_parties p
    join v2_companies co on co.id = p.company_id
    join v2_applications a on a.id = p.application_id
    cross join me
    where (p.company_id = me.cid
           or p.company_id in (select id from v2_companies where parent_id = me.cid)
           or (me.ra and co.tier = 1))
      and a.kind is distinct from 'external'
      -- 上側（直上の会社 or KANOA）にこの選考が届いているか
      and case when co.parent_id is not null
               then exists (select 1 from v2_application_parties pp where pp.application_id = p.application_id and pp.company_id = co.parent_id)
               else a.kanoa_visible end
  )
  select th.application_id, count(m.id)
  from th cross join me
  join v2_messages m on m.application_id = th.application_id and m.thread_company_id = th.tid
   and m.side <> th.side and not m.deleted
   and m.created_at > coalesce((select r.last_read_at from v2_thread_reads r where r.application_id = th.application_id
                                and r.thread_company_id = th.tid and r.member_id = me.mid), '-infinity')
  where th.side is not null
  group by th.application_id
$$;
