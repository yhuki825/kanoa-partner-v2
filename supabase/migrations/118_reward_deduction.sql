-- ============================================================
-- 報酬: 支払前の退職は「支払額から差し引く」（2026-10-16 事業主決定）
--  ・退職を記録したとき、まだ支払っていなければ refund_mode = 'deduct'（返金の手続きは無し）
--      支払額 = 紹介料 − 返金額（差し引き額）。0円になったら pay_status = 'cancelled'（支払なし）
--  ・支払済みのあとに記録したら refund_mode = 'refund'（これまでどおり返金待ち → 返金済み）
--  ・支払額は列に持たない（紹介料 − 差し引き額で毎回出す）
--  ・差し引き後の額で支払済みにしたものは、退職の記録を消す／直す前に「支払済みを取り消す」が必要
-- ============================================================
set check_function_bodies = off;

alter table v2_rewards add column refund_mode text check (refund_mode in ('deduct','refund'));
-- 既存の退職の記録（118 より前の方式＝返金）は 'refund' にする（適用時点で該当0行）
update v2_rewards set refund_mode = 'refund', version = version where resigned_on is not null and refund_mode is null;

alter table v2_rewards drop constraint v2_rewards_pay_status_check;
alter table v2_rewards add constraint v2_rewards_pay_status_check check (pay_status in ('pending','paid','cancelled'));
alter table v2_rewards add constraint v2_rewards_mode check (
  (resigned_on is null) = (refund_mode is null)                       -- 退職の記録があるときだけ方式を持つ
  and (refund_mode is distinct from 'deduct' or refund_status is null)  -- 差し引きは返金の手続きを持たない
  and (pay_status <> 'cancelled' or (refund_mode = 'deduct' and refund_amount = fee_amount)));  -- 支払なし＝全額差し引き

-- ---------- 支払済みにする（支払なし＝cancelled は不可） ----------
create or replace function v2_reward_mark_paid(p_app uuid, p_paid_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_app);
  if r.pay_status = 'paid' then
    raise exception 'already_paid' using errcode = 'P0409', hint = 'すでに支払済みです。画面を読み込み直してください';
  end if;
  if r.pay_status = 'cancelled' then
    raise exception 'cancelled' using errcode = 'P0409', hint = '支払前の退職で全額を差し引いたため、支払はありません（支払済みにはできません）';
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

-- ---------- 退職日の記録（null で記録を消す） ----------
create or replace function v2_reward_record_resignation(p_app uuid, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_rate int; v_amount numeric;
begin
  r := v2_reward_lock(p_app);
  if r.refund_status = 'refunded' then
    raise exception 'already_refunded' using errcode = 'P0409', hint = '返金済みのため、退職の記録は変更できません';
  end if;
  -- 差し引き後の額で支払済み: 支払額が確定しているので、退職の記録は消せない・直せない
  if r.refund_mode = 'deduct' and r.pay_status = 'paid' then
    raise exception 'deduction_paid' using errcode = 'P0409',
      hint = '支払額が差し引き後の額で確定しているため取り消せません（先に「支払済みを取り消す」を行ってください）';
  end if;
  if p_resigned_on is null then
    update v2_rewards set resigned_on = null, refund_rate = null, refund_amount = null, refund_status = null,
      refunded_on = null, refund_mode = null,
      pay_status = case when pay_status = 'cancelled' then 'pending' else pay_status end, version = version
    where application_id = p_app returning * into r;
    return r;
  end if;
  if p_resigned_on < r.joined_on then
    raise exception 'resigned_before_joined' using errcode = 'P0400', hint = '退職日が入社日より前になっています';
  end if;
  v_rate := v2_refund_rate(r.refund_policy, r.joined_on, p_resigned_on);
  v_amount := round(r.fee_amount * v_rate / 100);
  if r.pay_status = 'paid' then
    -- 支払済みのあとの退職: 返金を受ける（これまでどおり）
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'refund',
      refund_status = case when v_amount > 0 then 'pending' end, refunded_on = null, version = version
    where application_id = p_app returning * into r;
  else
    -- 支払前の退職: 支払額から差し引く（返金の手続きは無し）。0円になれば支払なし
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'deduct',
      refund_status = null, refunded_on = null,
      pay_status = case when r.fee_amount - v_amount <= 0 then 'cancelled' else 'pending' end, version = version
    where application_id = p_app returning * into r;
  end if;
  return r;
end $$;

-- v2_reward_unmark_paid は変更なし: 差し引きの報酬は refund_status が空なので取り消せる（差し引きは残る）。
-- 返金の報酬は、返金待ち・返金済みがあれば取り消せない（これまでどおり）
-- v2_reward_mark_refunded も変更なし: 差し引きの報酬には返金待ちが無いので、返金済みにはできない
