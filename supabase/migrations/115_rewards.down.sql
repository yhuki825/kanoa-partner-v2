-- 115_rewards.sql・116_rewards_fixes.sql・117_rewards_fixes2.sql を元に戻す（報酬・返金規定のデータも消える）
-- ※ 116/117 が自動で入れた「最後の段階の実施日」（v2_milestones.done_on）はデータとして残り、戻らない
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 1) v2_milestone_save を 115 適用前の本体に戻す（2026-10-16 にDBから読んだ本体そのまま。prosrc の md5 = 89ae6e5da71f90df5474bf9b10f97d92）
CREATE OR REPLACE FUNCTION public.v2_milestone_save(p_id uuid, p_version integer, p_scheduled date, p_done date, p_result text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me record; ms v2_milestones%rowtype; a v2_applications%rowtype; v_failed boolean; v_all boolean;
begin
  me := v2_actor();
  select * into ms from v2_milestones where id = p_id;
  if not found then raise exception 'not_found'; end if;
  select * into a from v2_applications where id = ms.application_id for update;
  if a.kind = 'internal' and not (me.role = 'ra' and a.kanoa_visible) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '社内求人の選考の進み具合はKANOAが更新します';
  end if;
  if a.kind = 'external' and not v2_owns(a.applied_by_company) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '外部求人の選考は、登録した会社が更新します';
  end if;
  if a.stage not in ('active','closed') then
    raise exception 'not_open' using errcode = 'P0409', hint = 'この選考は進行中ではありません';
  end if;
  if p_result not in ('pending','passed','failed') then raise exception 'bad_result'; end if;
  update v2_milestones set scheduled_on = p_scheduled, done_on = p_done, result = p_result, version = p_version
  where id = p_id;   -- version が違えば v2_touch が衝突エラーにする
  -- 選考全体の状態を段階の結果から決める（不通過が1つ→終了・不通過／全段階通過→終了・通過）
  select bool_or(result = 'failed'), bool_and(result = 'passed') into v_failed, v_all
  from v2_milestones where application_id = a.id;
  update v2_applications set
    stage = case when v_failed or v_all then 'closed' else 'active' end,
    result = case when v_failed then 'failed' when v_all then 'passed' else null end,
    version = version
  where id = a.id;
  insert into v2_application_events(application_id, company_id, member_id, action, note)
  values (a.id, me.company_id, me.member_id, 'milestone',
          ms.name || '：' || case p_result when 'passed' then '通過' when 'failed' then '不通過' else '未定' end);
end $function$
;

-- 2) 116 で既存の表に足した「1円単位」の制約を外す
alter table v2_job_kanoa_fees drop constraint if exists v2_job_kanoa_fees_fee_whole;
alter table v2_job_shares     drop constraint if exists v2_job_shares_fee_override_whole;
alter table v2_job_offers     drop constraint if exists v2_job_offers_fee_display_whole;

-- 3) 115・116 で足した関数と表を消す
drop function if exists v2_job_refund_policy_save(uuid, jsonb), v2_job_refund_policy_save(uuid, jsonb, int), v2_reward_mark_paid(uuid, date), v2_reward_unmark_paid(uuid),
  v2_reward_record_resignation(uuid, date), v2_reward_mark_refunded(uuid, date), v2_reward_lock(uuid),
  v2_refund_policy_normalize(jsonb), v2_refund_rate(jsonb, date, date);
drop table if exists v2_rewards, v2_job_refund_policies;
