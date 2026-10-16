-- ============================================================
-- 多段報酬（120）の独立レビュー指摘の修正
--  M1) 行をロックして読み直したときに行が消えていたら（同時に入社が取り消された等）P0409 で止める（黙って0件更新で成功させない）
--  M2) 4つの操作に楽観ロック（p_version）。画面が読んだときの version と違えば P0409 version_conflict
--      （古い画面で、他の人の退職・取り消し・返金の記録を上書きしない）。古い引数の版は消す
--  L2) 権限が無い／行が無いは同じ P0403・同じ理由で返す（行があるかどうかを漏らさない）
--      RA（全件を見られる）が無い行を指定したときだけ P0409（画面の読み込み直しを促す）
--  L6) v2_milestone_save を未ログイン（anon）から呼べないようにする（画面はログイン中に呼ぶ）
-- ============================================================
set check_function_bodies = off;

-- ---------- 古い引数の版を消す（120 の版） ----------
drop function if exists v2_reward_mark_paid(uuid, date, numeric);
drop function if exists v2_reward_unmark_paid(uuid);
drop function if exists v2_reward_record_resignation(uuid, date);
drop function if exists v2_reward_mark_refunded(uuid, date);
drop function if exists v2_reward_lock(uuid);

-- ---------- 報酬の行をロックして読む（権限 → ロック → 行の有無 → version の順に確かめる） ----------
create function v2_reward_lock(p_reward uuid, p_version int) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_ra boolean := v2_is_ra();
begin
  select * into r from v2_rewards where id = p_reward;
  if not found and v_ra then
    raise exception 'not_found' using errcode = 'P0409', hint = 'この報酬の記録が見つかりません。画面を読み込み直してください';
  end if;
  -- 行が無い・権限が無いは同じ返事にする（行があるかどうかを漏らさない）
  if not found
     or (r.payer_company_id is null and not v_ra)
     or (r.payer_company_id is not null and not (coalesce(v2_my_company() = r.payer_company_id, false) and v2_is_owner())) then
    raise exception 'permission_denied' using errcode = 'P0403',
      hint = 'この報酬の記録を変更する権限がありません（KANOAが払う分はKANOA、フロントへの支払いは支払う会社の代表者だけが記録できます）';
  end if;
  select * into r from v2_rewards where id = p_reward for update;   -- 権限を確かめてからロックして読み直す
  if not found then   -- 読み直すまでの間に消えた（入社の取り消し等）
    raise exception 'not_found' using errcode = 'P0409', hint = 'この報酬の記録はほかの操作で消えました。画面を読み込み直してください';
  end if;
  if p_version is null or p_version <> r.version then
    raise exception 'version_conflict' using errcode = 'P0409', hint = '他の人が先に更新しました。画面を読み込み直してください';
  end if;
  return r;
end $$;

-- ---------- 支払済みにする ----------
create function v2_reward_mark_paid(p_reward uuid, p_version int, p_paid_on date, p_expected_payable numeric) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_payable numeric; v_mode text;
begin
  r := v2_reward_lock(p_reward, p_version);
  if r.pay_status = 'paid' then
    raise exception 'already_paid' using errcode = 'P0409', hint = 'すでに支払済みです。画面を読み込み直してください';
  end if;
  if r.pay_status = 'cancelled' then
    raise exception 'cancelled' using errcode = 'P0409', hint = '支払前の退職で全額を差し引いたため、支払はありません（支払済みにはできません）';
  end if;
  v_payable := v2_reward_payable(r);
  if v_payable <= 0 then
    raise exception 'zero_fee' using errcode = 'P0400', hint = '紹介料が0円（未設定）のため、支払済みにはできません';
  end if;
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
    if r.refund_amount > 0 then
      raise exception 'paid_before_resigned' using errcode = 'P0400',
        hint = '退職より前の支払いは、先に「支払済み」を記録してから退職を記録してください（返金の扱いになります）';
    end if;
    -- 差し引き0円: 退職より前の支払い＝支払後の退職（返金0円）として記録する（支払額は同じ。取り消す前の形に戻る）
    v_mode := 'refund';
  end if;
  update v2_rewards set pay_status = 'paid', paid_on = p_paid_on, paid_amount = v_payable,
    refund_mode = coalesce(v_mode, refund_mode), version = p_version
  where id = r.id returning * into r;
  return r;
end $$;

-- ---------- 支払済みの取り消し ----------
create function v2_reward_unmark_paid(p_reward uuid, p_version int) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_reward, p_version);
  if r.pay_status <> 'paid' then
    raise exception 'not_paid' using errcode = 'P0409', hint = 'まだ支払済みになっていません。画面を読み込み直してください';
  end if;
  if r.refund_status is not null then
    raise exception 'refund_recorded' using errcode = 'P0409', hint = '返金が記録されているため、支払済みを取り消せません（先に退職の記録を消してください）';
  end if;
  if r.refund_mode = 'refund' then
    -- 返金0円の返金の扱い → 支払前の退職になるので「差し引き」にそろえる（差し引き額は返金額と同じ＝0円）
    update v2_rewards set pay_status = case when fee_amount - refund_amount <= 0 then 'cancelled' else 'pending' end,
      paid_on = null, paid_amount = null, refund_mode = 'deduct', refund_status = null, refunded_on = null, version = p_version
    where id = r.id returning * into r;
  else
    update v2_rewards set pay_status = 'pending', paid_on = null, paid_amount = null, version = p_version
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- ---------- 退職日の記録（null で記録を消す） ----------
create function v2_reward_record_resignation(p_reward uuid, p_version int, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_rate int; v_amount numeric;
begin
  r := v2_reward_lock(p_reward, p_version);
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
      pay_status = case when pay_status = 'cancelled' then 'pending' else pay_status end, version = p_version
    where id = r.id returning * into r;
    return r;
  end if;
  if p_resigned_on < r.joined_on then
    raise exception 'resigned_before_joined' using errcode = 'P0400', hint = '退職日が入社日より前になっています';
  end if;
  v_rate := v2_refund_rate(r.refund_policy, r.joined_on, p_resigned_on);
  v_amount := round(r.fee_amount * v_rate / 100);
  if r.pay_status = 'paid' then
    -- 支払済みのあとの退職: 返金を受ける
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'refund',
      refund_status = case when v_amount > 0 then 'pending' end, refunded_on = null, version = p_version
    where id = r.id returning * into r;
  else
    -- 支払前の退職: 支払額から差し引く（返金の手続きは無し）。0円になれば支払なし
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'deduct',
      refund_status = null, refunded_on = null,
      pay_status = case when r.fee_amount - v_amount <= 0 then 'cancelled' else 'pending' end, version = p_version
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- ---------- 返金済みにする ----------
create function v2_reward_mark_refunded(p_reward uuid, p_version int, p_refunded_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_reward, p_version);
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
  update v2_rewards set refund_status = 'refunded', refunded_on = p_refunded_on, version = p_version
  where id = r.id returning * into r;
  return r;
end $$;

-- ---------- 実行権限 ----------
revoke all on function v2_reward_lock(uuid, int) from public, anon, authenticated;
revoke all on function v2_reward_mark_paid(uuid, int, date, numeric), v2_reward_unmark_paid(uuid, int),
  v2_reward_record_resignation(uuid, int, date), v2_reward_mark_refunded(uuid, int, date) from public, anon;
grant execute on function v2_reward_mark_paid(uuid, int, date, numeric), v2_reward_unmark_paid(uuid, int),
  v2_reward_record_resignation(uuid, int, date), v2_reward_mark_refunded(uuid, int, date) to authenticated;

-- L6) マイルストーンの更新は、ログイン中の人だけ（選考詳細の画面がログイン中に呼ぶ）
revoke execute on function v2_milestone_save(uuid, int, date, date, text) from public, anon;
grant execute on function v2_milestone_save(uuid, int, date, date, text) to authenticated;
