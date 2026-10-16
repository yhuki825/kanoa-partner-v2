-- ============================================================
-- 報酬の修正 第2弾（116 の独立レビュー指摘）
--  1) 日付は日本時間: 自動で入れる日付（最後の段階の実施日・入社日）は (now() at time zone 'Asia/Tokyo')::date
--     （DBの時刻はUTCのため、current_date では朝9時まで前日になる）。自動記入は社内求人の選考だけ（外部求人は 106 のまま）
--  2) 入社日を動かさない: 報酬があるときに最後の段階を実施日なしで保存し直しても、実施日には報酬の入社日を入れる
--     報酬を作るときに最後の段階の実施日が空なら、入社日を書き戻す。過去分の書き戻し（1回だけ）
--  3) 金額: NaN・Infinity・極端な値を拒否（制約名は 116 と同じ。down で外せるように）
--  5) 報酬の行のロックは、変わりうるときだけ（最後の段階の保存・報酬がまだ無いとき・入社の取り消し）
-- ============================================================
set check_function_bodies = off;

-- ---------- 3) 金額: 1円単位・0以上・1兆円未満（NaN と Infinity はここで弾かれる） ----------
alter table v2_job_kanoa_fees drop constraint v2_job_kanoa_fees_fee_whole;
alter table v2_job_kanoa_fees add constraint v2_job_kanoa_fees_fee_whole
  check (fee = trunc(fee) and fee >= 0 and fee < 1000000000000);
alter table v2_job_shares drop constraint v2_job_shares_fee_override_whole;
alter table v2_job_shares add constraint v2_job_shares_fee_override_whole
  check (fee_override = trunc(fee_override) and fee_override >= 0 and fee_override < 1000000000000);
alter table v2_job_offers drop constraint v2_job_offers_fee_display_whole;
alter table v2_job_offers add constraint v2_job_offers_fee_display_whole
  check (fee_display = trunc(fee_display) and fee_display >= 0 and fee_display < 1000000000000);
alter table v2_rewards drop constraint v2_rewards_fee_amount_whole;
alter table v2_rewards add constraint v2_rewards_fee_amount_whole
  check (fee_amount = trunc(fee_amount) and fee_amount >= 0 and fee_amount < 1000000000000);
alter table v2_rewards drop constraint v2_rewards_refund_amount_whole;
alter table v2_rewards add constraint v2_rewards_refund_amount_whole
  check (refund_amount = trunc(refund_amount) and refund_amount >= 0 and refund_amount < 1000000000000);

-- ---------- 2) 過去分の書き戻し（報酬があるのに最後の段階の実施日が空のもの → 入社日を入れる） ----------
update v2_milestones m set done_on = r.joined_on, version = m.version
from v2_rewards r
where m.application_id = r.application_id and m.result = 'passed' and m.done_on is null
  and m.seq = (select max(x.seq) from v2_milestones x where x.application_id = r.application_id);

-- ---------- 1) 2) 5) マイルストーンの更新 ----------
-- 既存の確認・動作は 106 のまま。変えたのは「社内求人の最後の段階の実施日の自動記入」と「-- 報酬」以下だけ
create or replace function v2_milestone_save(p_id uuid, p_version int, p_scheduled date, p_done date, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare me record; ms v2_milestones%rowtype; a v2_applications%rowtype; v_failed boolean; v_all boolean;
        rw v2_rewards%rowtype; v_has boolean := false; v_last int; v_done date; v_joined date; v_payee uuid; v_fee numeric;
        v_today date := (now() at time zone 'Asia/Tokyo')::date;   -- 日本時間の今日（DBの時刻はUTC）
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
  select max(seq) into v_last from v2_milestones where application_id = a.id;
  v_done := p_done;
  if a.kind = 'internal' and ms.seq = v_last then
    -- 最後の段階（＝入社）を保存するときだけ報酬の行をロックして読む（入社日が変わりうるため）
    select * into rw from v2_rewards where application_id = a.id for update;
    v_has := found;
    -- 実施日なしで「通過」: 報酬があればその入社日、無ければ日本時間の今日を実施日として残す（入社日を動かさない・見える形で固定）
    if p_result = 'passed' and p_done is null then
      v_done := case when v_has then rw.joined_on else v_today end;
    end if;
  end if;
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
  if a.kind <> 'internal' then return; end if;
  if coalesce(v_all, false) and not coalesce(v_failed, false) then
    if ms.seq <> v_last then
      -- 最後以外の段階の保存: 報酬があれば触れない（ロックもしない）。無ければ作る
      -- （選考の行をロックしているので、同じ選考の段階の保存どうしは順番に処理される）
      select * into rw from v2_rewards where application_id = a.id;
      v_has := found;
    end if;
    if not v_has then
      select done_on into v_joined from v2_milestones where application_id = a.id and seq = v_last;
      select co.id into v_payee from v2_application_parties p join v2_companies co on co.id = p.company_id
      where p.application_id = a.id and co.tier = 1 limit 1;
      if v_payee is not null then   -- KANOA自身の求職者（1次がいない）は対象外
        if v_joined is null then   -- 実施日が空なら日本時間の今日を入社日にして、最後の段階にも書き戻す
          v_joined := v_today;
          update v2_milestones set done_on = v_joined, version = version where application_id = a.id and seq = v_last;
        end if;
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
  else
    -- 入社の判定を取り消した場合（報酬の行を消しうるので、ここではロックする）:
    -- 支払・退職・返金の記録が無ければ報酬の行を消す。あれば止める（お金の記録を宙に浮かせない）
    select * into rw from v2_rewards where application_id = a.id for update;
    if found then
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
