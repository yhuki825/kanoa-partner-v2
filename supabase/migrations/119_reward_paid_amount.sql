-- ============================================================
-- 報酬: 実際に支払った額を記録する（118 の独立レビュー指摘）
--  1) paid_amount: 支払済みにした時点の支払額（税抜）。支払済みのときだけ値を持つ
--  2) 支払済みにするとき、画面が表示していた支払額（p_expected_payable）と今の支払額が違えば止める（P0409）
--  3) 差し引きの報酬で、退職日より前の支払日は拒否（その場合は先に支払済み→退職の順で記録＝返金の扱い）
--  4) 支払済みの取り消しは paid_on と paid_amount を一緒に消す（変更の履歴は操作記録に残る）
--     返金の扱い（返金0円）で支払済みを取り消したら、「支払前の退職＝差し引き」にそろえる
--  5) 守りの制約: 返金・差し引き額 <= 紹介料／差し引きで全額なら必ず支払なし／支払なしは支払額0のときだけ
--  適用前に既存の行がすべて条件を満たすことを確認済み（報酬1行・支払済み0行・違反0行）
-- ============================================================
set check_function_bodies = off;

-- ---------- 1) 実際に支払った額 ----------
alter table v2_rewards add column paid_amount numeric;
-- 既存の支払済みの行は、今の支払額で埋める（適用時点で該当0行）
update v2_rewards set paid_amount = fee_amount - coalesce(case when refund_mode = 'deduct' then refund_amount end, 0), version = version
where pay_status = 'paid' and paid_amount is null;
alter table v2_rewards add constraint v2_rewards_paid_amount_whole
  check (paid_amount = trunc(paid_amount) and paid_amount >= 0 and paid_amount < 1000000000000);
alter table v2_rewards add constraint v2_rewards_paid_amount_set check ((pay_status = 'paid') = (paid_amount is not null));

-- ---------- 5) 守りの制約 ----------
alter table v2_rewards add constraint v2_rewards_refund_le_fee check (refund_amount <= fee_amount);
alter table v2_rewards add constraint v2_rewards_deduct_full check (
  not (refund_mode = 'deduct' and pay_status <> 'cancelled' and refund_amount >= fee_amount and fee_amount > 0));
alter table v2_rewards add constraint v2_rewards_cancelled_zero check (
  pay_status <> 'cancelled' or (refund_mode = 'deduct' and fee_amount - refund_amount = 0));

-- 今の支払額（税抜）= 紹介料 − 差し引き額（差し引きの扱いのときだけ）
create or replace function v2_reward_payable(r v2_rewards) returns numeric
language sql immutable set search_path = public as $$
  select r.fee_amount - coalesce(case when r.refund_mode = 'deduct' then r.refund_amount end, 0)
$$;
revoke all on function v2_reward_payable(v2_rewards) from public, anon, authenticated;

-- ---------- 2) 3) 支払済みにする ----------
drop function if exists v2_reward_mark_paid(uuid, date);
create or replace function v2_reward_mark_paid(p_app uuid, p_paid_on date, p_expected_payable numeric) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_payable numeric;
begin
  r := v2_reward_lock(p_app);
  if r.pay_status = 'paid' then
    raise exception 'already_paid' using errcode = 'P0409', hint = 'すでに支払済みです。画面を読み込み直してください';
  end if;
  if r.pay_status = 'cancelled' then
    raise exception 'cancelled' using errcode = 'P0409', hint = '支払前の退職で全額を差し引いたため、支払はありません（支払済みにはできません）';
  end if;
  v_payable := v2_reward_payable(r);
  if p_expected_payable is null or p_expected_payable <> v_payable then
    raise exception 'payable_changed' using errcode = 'P0409', hint = '支払額が変わりました。画面を読み込み直してください';
  end if;
  if p_paid_on is null then
    raise exception 'no_date' using errcode = 'P0400', hint = '支払日を入れてください';
  end if;
  if p_paid_on < r.joined_on then
    raise exception 'paid_before_joined' using errcode = 'P0400', hint = '支払日が入社日より前になっています';
  end if;
  if r.refund_mode = 'deduct' and p_paid_on < r.resigned_on then
    raise exception 'paid_before_resigned' using errcode = 'P0400',
      hint = '退職より前の支払いは、先に「支払済み」を記録してから退職を記録してください（返金の扱いになります）';
  end if;
  update v2_rewards set pay_status = 'paid', paid_on = p_paid_on, paid_amount = v_payable, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;
revoke all on function v2_reward_mark_paid(uuid, date, numeric) from public, anon;
grant execute on function v2_reward_mark_paid(uuid, date, numeric) to authenticated;

-- ---------- 4) 支払済みの取り消し ----------
create or replace function v2_reward_unmark_paid(p_app uuid) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_app);
  if r.pay_status <> 'paid' then
    raise exception 'not_paid' using errcode = 'P0409', hint = 'まだ支払済みになっていません。画面を読み込み直してください';
  end if;
  if r.refund_status is not null then
    raise exception 'refund_recorded' using errcode = 'P0409', hint = '返金が記録されているため、支払済みを取り消せません（先に退職の記録を消してください）';
  end if;
  if r.refund_mode = 'refund' then
    -- 返金0円の返金の扱い → 支払前の退職になるので「差し引き」にそろえる（差し引き額は返金額と同じ＝0円）
    update v2_rewards set pay_status = case when fee_amount - refund_amount <= 0 then 'cancelled' else 'pending' end,
      paid_on = null, paid_amount = null, refund_mode = 'deduct', refund_status = null, refunded_on = null, version = version
    where application_id = p_app returning * into r;
  else
    update v2_rewards set pay_status = 'pending', paid_on = null, paid_amount = null, version = version
    where application_id = p_app returning * into r;
  end if;
  return r;
end $$;
