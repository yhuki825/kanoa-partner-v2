-- ============================================================
-- 報酬の修正（115 のレビュー指摘）
--  1) 入社日のぶれ: 入社日は「最後の段階の実施日」だけから決める
--     ・最後の段階を実施日なしで「通過」にしたら、その段階の実施日に今日を入れる（入社日が見える形で固定される）
--     ・報酬の入社日を直すのは、最後の段階を保存したときだけ。他の段階の保存では報酬に触れない
--     ・支払済み／退職・返金の記録がある報酬の入社日は変えない（P0409で止める。黙って変えない）
--  2) 日付の前後: 支払日 >= 入社日、返金日 >= 支払日（退職日 >= 入社日 は 115 のまま）
--  3) 金額は1円単位: 紹介料・表示額・報酬額・返金額に整数の制約（適用前に既存行がすべて整数であることを確認済み）
--  4) 返金規定の保存に楽観ロック（p_version）。2引数の版は消す
--  5) 報酬の記録を残す: 選考を消しても報酬は消えない（restrict）。使っていない note 列を消す
--     （1次パートナーも報酬の行を読めるため、社内メモの列を置かない）
-- ============================================================
set check_function_bodies = off;

-- ---------- 5) 報酬の記録を残す ----------
alter table v2_rewards drop constraint v2_rewards_application_id_fkey;
alter table v2_rewards add constraint v2_rewards_application_id_fkey
  foreign key (application_id) references v2_applications(id) on delete restrict;
alter table v2_rewards drop column note;

-- ---------- 3) 金額は1円単位 ----------
alter table v2_job_kanoa_fees add constraint v2_job_kanoa_fees_fee_whole check (fee = trunc(fee));
alter table v2_job_shares     add constraint v2_job_shares_fee_override_whole check (fee_override = trunc(fee_override));
alter table v2_job_offers     add constraint v2_job_offers_fee_display_whole check (fee_display = trunc(fee_display));
alter table v2_rewards        add constraint v2_rewards_fee_amount_whole check (fee_amount = trunc(fee_amount));
alter table v2_rewards        add constraint v2_rewards_refund_amount_whole check (refund_amount = trunc(refund_amount));

-- ---------- 4) 返金規定の保存（RAだけ・楽観ロック） ----------
drop function if exists v2_job_refund_policy_save(uuid, jsonb);
create or replace function v2_job_refund_policy_save(p_job uuid, p_policy jsonb, p_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_policy jsonb; v_cur int; v_n int;
begin
  if not v2_is_ra() then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '返金規定を変更できるのはKANOAだけです';
  end if;
  if not exists (select 1 from v2_jobs where id = p_job) then
    raise exception 'not_found' using errcode = 'P0404', hint = '求人が見つかりません';
  end if;
  v_policy := v2_refund_policy_normalize(p_policy);
  select version into v_cur from v2_job_refund_policies where job_id = p_job for update;
  if found then
    -- 画面が読んだときの version と違えば拒否（他の人の変更を古い内容で上書きしない）
    if p_version is null or p_version <> v_cur then
      raise exception 'version_conflict' using errcode = 'P0409', hint = '他の人が先に更新しました。画面を読み込み直してください';
    end if;
    update v2_job_refund_policies set policy = v_policy, version = p_version where job_id = p_job;
  else
    if p_version is not null then
      raise exception 'version_conflict' using errcode = 'P0409', hint = '他の人が先に更新しました。画面を読み込み直してください';
    end if;
    insert into v2_job_refund_policies(job_id, policy) values (p_job, v_policy) on conflict (job_id) do nothing;
    get diagnostics v_n = row_count;
    if v_n = 0 then   -- 同時に別の人が作った
      raise exception 'version_conflict' using errcode = 'P0409', hint = '他の人が先に更新しました。画面を読み込み直してください';
    end if;
  end if;
  return v_policy;
end $$;
revoke all on function v2_job_refund_policy_save(uuid, jsonb, int) from public, anon;
grant execute on function v2_job_refund_policy_save(uuid, jsonb, int) to authenticated;

-- ---------- 2) 日付の前後 ----------
create or replace function v2_reward_mark_paid(p_app uuid, p_paid_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_app);
  if r.pay_status = 'paid' then
    raise exception 'already_paid' using errcode = 'P0409', hint = 'すでに支払済みです。画面を読み込み直してください';
  end if;
  if p_paid_on is null then
    raise exception 'no_date' using errcode = 'P0400', hint = '支払日を入れてください';
  end if;
  if p_paid_on < r.joined_on then
    raise exception 'paid_before_joined' using errcode = 'P0400', hint = '支払日が入社日より前になっています';
  end if;
  update v2_rewards set pay_status = 'paid', paid_on = p_paid_on, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;

create or replace function v2_reward_mark_refunded(p_app uuid, p_refunded_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_app);
  if r.refund_status is distinct from 'pending' then
    raise exception 'no_pending_refund' using errcode = 'P0409', hint = '返金待ちの記録がありません。画面を読み込み直してください';
  end if;
  if r.pay_status <> 'paid' then
    raise exception 'not_paid' using errcode = 'P0409', hint = '支払済みにしてから返金済みにしてください';
  end if;
  if p_refunded_on is null then
    raise exception 'no_date' using errcode = 'P0400', hint = '返金日を入れてください';
  end if;
  if p_refunded_on < r.paid_on then
    raise exception 'refunded_before_paid' using errcode = 'P0400', hint = '返金日が支払日より前になっています';
  end if;
  update v2_rewards set refund_status = 'refunded', refunded_on = p_refunded_on, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;

-- ---------- 1) 入社日のぶれを止める ----------
-- 既存の確認・動作は 106 のまま。変えたのは「最後の段階の実施日の自動記入」と「-- 報酬」以下だけ
create or replace function v2_milestone_save(p_id uuid, p_version int, p_scheduled date, p_done date, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare me record; ms v2_milestones%rowtype; a v2_applications%rowtype; v_failed boolean; v_all boolean;
        rw v2_rewards%rowtype; v_last int; v_done date; v_joined date; v_payee uuid; v_fee numeric;
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
  -- 最後の段階を実施日なしで「通過」にしたら、今日を実施日として残す（入社日を見える形で固定する）
  select max(seq) into v_last from v2_milestones where application_id = a.id;
  v_done := case when ms.seq = v_last and p_result = 'passed' and p_done is null then current_date else p_done end;
  update v2_milestones set scheduled_on = p_scheduled, done_on = v_done, result = p_result, version = p_version
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

  -- 報酬（設計書14）: 社内求人で全段階が通過＝入社 → 1次パートナーへの成約報酬を、その時点の額・返金規定で固定して記録
  if coalesce(v_all, false) and not coalesce(v_failed, false) then
    if a.kind = 'internal' then
      select * into rw from v2_rewards where application_id = a.id for update;
      if not found then
        select done_on into v_joined from v2_milestones where application_id = a.id and seq = v_last;
        v_joined := coalesce(v_joined, current_date);   -- 116 より前に実施日なしで通過にした段階だけが該当
        select co.id into v_payee from v2_application_parties p join v2_companies co on co.id = p.company_id
        where p.application_id = a.id and co.tier = 1 limit 1;
        if v_payee is not null then   -- KANOA自身の求職者（1次がいない）は対象外
          v_fee := coalesce((select fee_override from v2_job_shares where job_id = a.job_id and company_id = v_payee),
                            (select fee from v2_job_kanoa_fees where job_id = a.job_id), 0);
          insert into v2_rewards(application_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount, refund_policy)
          values (a.id, v_payee, a.job_id, a.candidate_id, v_joined, v_fee,
                  coalesce((select policy from v2_job_refund_policies where job_id = a.job_id), '[]'));
        end if;
      elsif ms.seq = v_last and rw.joined_on is distinct from v_done then
        -- 入社日（最後の段階の実施日）を直した場合だけ。支払・退職・返金の記録があれば止める（黙って変えない）
        if rw.pay_status = 'paid' then
          raise exception 'reward_locked' using errcode = 'P0409',
            hint = '支払済みの報酬がある選考は、入社日を変更できません（先に報酬の画面で「支払済みを取り消す」を行ってください）';
        end if;
        if rw.resigned_on is not null or rw.refund_status is not null then
          raise exception 'reward_locked' using errcode = 'P0409',
            hint = '退職が記録された報酬がある選考は、入社日を変更できません（先に報酬の画面で退職の記録を消してください）';
        end if;
        update v2_rewards set joined_on = v_done, version = version where application_id = a.id;
      end if;
    end if;
  else
    select * into rw from v2_rewards where application_id = a.id for update;
    if found then
      -- 入社の判定を取り消した場合: 支払・退職・返金の記録が無ければ報酬の行を消す。あれば止める（お金の記録を宙に浮かせない）
      if rw.pay_status = 'paid' then
        raise exception 'reward_locked' using errcode = 'P0409',
          hint = '支払済みの報酬がある選考は、入社の判定を取り消せません（先に報酬の画面で「支払済みを取り消す」を行ってください）';
      end if;
      if rw.resigned_on is not null or rw.refund_status is not null then
        raise exception 'reward_locked' using errcode = 'P0409',
          hint = '退職・返金が記録された報酬がある選考は、入社の判定を取り消せません（先に報酬の画面で退職の記録を消してください）';
      end if;
      delete from v2_rewards where application_id = a.id;
    end if;
  end if;
end $$;
