-- ============================================================
-- 多段報酬の運用ルール（設計書 14.1。2026-10-16 ユーザー決定「全部推奨どおり」）
--  1) 退職の自動反映: ある段で退職を記録・変更・削除すると、その下の段（フロントへの支払い）にも同じ退職日を反映する
--     （二度手間防止。退職は求職者についての1つの事実のため）。反映しない行: 返金済み／差し引き後の額で支払済み（額が確定済み）
--     記録を消すときは、消す前と同じ退職日が入っている下の段だけを消す（下の段が独自に直した日付は消さない）
--  2) フロント向け紹介料が未設定の段も、紹介料0円（未設定）の行を作る（下の段にも入社が見えるように）。
--     支払う側が後から「紹介料を入れる」で額を入れる（0円の行のときだけ。支払前の退職があれば差し引きも計算し直す）
--  3) 支払う会社が利用停止中（または利用中の代表者がいない）とき、その会社が払う行はKANOA（RA）が代わりに記録できる
--  4) 2次以降にもKANOAの返金規定（自分の行に固定された分）が見える（変更なし。設計書14の表を直した）
-- ============================================================
set check_function_bodies = off;

-- ---------- 支払う会社が記録できない状態か（利用停止中／利用中の代表者がいない）。内部用 ----------
create or replace function v2_reward_payer_stuck(p_payer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_payer is not null and (
    not exists (select 1 from v2_companies where id = p_payer and status = 'active')
    or not exists (select 1 from v2_members where company_id = p_payer and role = 'ca' and is_owner and status = 'active'))
$$;

-- 画面用（RAだけ true になりうる）: RAの報酬の画面で「KANOAが代わりに記録する行」を絞るのに使う（PostgRESTの計算列）
create or replace function v2_payer_stuck(r v2_rewards) returns boolean
language sql stable security definer set search_path = public as $$
  select v2_is_ra() and v2_reward_payer_stuck(r.payer_company_id)
$$;

-- ---------- 報酬の行をロックして読む（121 に「支払う会社が記録できない状態ならRAも可」を足す） ----------
create or replace function v2_reward_lock(p_reward uuid, p_version int) returns v2_rewards
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
     or (r.payer_company_id is not null
         and not (coalesce(v2_my_company() = r.payer_company_id, false) and v2_is_owner())
         and not (v_ra and v2_reward_payer_stuck(r.payer_company_id))) then
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

-- ---------- 退職日を1行に書く（権限・状態の確認は呼ぶ側。内部用） ----------
create or replace function v2_reward_apply_resignation(p_id uuid, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_rate int; v_amount numeric;
begin
  select * into r from v2_rewards where id = p_id;
  if p_resigned_on is null then
    update v2_rewards set resigned_on = null, refund_rate = null, refund_amount = null, refund_status = null,
      refunded_on = null, refund_mode = null,
      pay_status = case when pay_status = 'cancelled' then 'pending' else pay_status end, version = version
    where id = r.id returning * into r;
    return r;
  end if;
  v_rate := v2_refund_rate(r.refund_policy, r.joined_on, p_resigned_on);
  v_amount := round(r.fee_amount * v_rate / 100);
  if r.pay_status = 'paid' then
    -- 支払済みのあとの退職: 返金を受ける
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'refund',
      refund_status = case when v_amount > 0 then 'pending' end, refunded_on = null, version = version
    where id = r.id returning * into r;
  else
    -- 支払前の退職: 支払額から差し引く（返金の手続きは無し）。0円になれば支払なし
    update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount, refund_mode = 'deduct',
      refund_status = null, refunded_on = null,
      pay_status = case when r.fee_amount - v_amount <= 0 then 'cancelled' else 'pending' end, version = version
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- ---------- 退職日の記録（null で記録を消す）。下の段にも反映する ----------
create or replace function v2_reward_record_resignation(p_reward uuid, p_version int, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; d record; v_old date; v_tier int;
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
  if p_resigned_on is not null and p_resigned_on < r.joined_on then
    raise exception 'resigned_before_joined' using errcode = 'P0400', hint = '退職日が入社日より前になっています';
  end if;
  v_old := r.resigned_on;
  -- version は画面が読んだものとロックで一致を確認済み。書き込みで v2_touch が1つ上げる
  r := v2_reward_apply_resignation(r.id, p_resigned_on);

  -- 下の段（受け取る会社の階層が深い行）へ反映。上の段から順にロックする（どの経路でも同じ順＝行き詰まりを作らない）
  select tier into v_tier from v2_companies where id = r.payee_company_id;
  for d in select rw.id, rw.resigned_on, rw.refund_status, rw.refund_mode, rw.pay_status, rw.joined_on
           from v2_rewards rw join v2_companies pe on pe.id = rw.payee_company_id
           where rw.application_id = r.application_id and pe.tier > v_tier
           order by pe.tier, rw.id for update of rw loop
    -- 額が確定している行は動かさない（返金済み／差し引き後の額で支払済み）
    continue when d.refund_status = 'refunded' or (d.refund_mode = 'deduct' and d.pay_status = 'paid');
    if p_resigned_on is null then
      continue when d.resigned_on is distinct from v_old;   -- 消すのは、同じ退職日が入っている行だけ
    else
      continue when d.resigned_on = p_resigned_on or p_resigned_on < d.joined_on;
    end if;
    perform v2_reward_apply_resignation(d.id, p_resigned_on);
  end loop;
  return r;
end $$;

-- ---------- 紹介料を入れる（紹介料0円＝未設定の行だけ。支払う側が後から額を決める） ----------
create or replace function v2_reward_set_fee(p_reward uuid, p_version int, p_fee numeric) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_amount numeric;
begin
  r := v2_reward_lock(p_reward, p_version);
  if r.fee_amount <> 0 then
    raise exception 'fee_already_set' using errcode = 'P0409', hint = '紹介料はすでに入っています（入社が確定した時点の額で固定です）。画面を読み込み直してください';
  end if;
  if r.pay_status = 'paid' or r.refund_status is not null then
    raise exception 'not_open' using errcode = 'P0409', hint = '支払・返金の記録がある行の紹介料は入れられません。画面を読み込み直してください';
  end if;
  if p_fee is null or p_fee <> trunc(p_fee) or p_fee <= 0 or p_fee >= 1000000000000 then
    raise exception 'bad_fee' using errcode = 'P0400', hint = '紹介料は1円以上・1兆円未満の整数（税抜）で入れてください';
  end if;
  if r.resigned_on is null then
    update v2_rewards set fee_amount = p_fee, version = p_version where id = r.id returning * into r;
  else
    -- 支払前の退職がある: 固定済みの返金率で差し引きを計算し直す
    v_amount := round(p_fee * r.refund_rate / 100);
    update v2_rewards set fee_amount = p_fee, refund_amount = v_amount, refund_mode = 'deduct',
      pay_status = case when p_fee - v_amount <= 0 then 'cancelled' else 'pending' end, version = p_version
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- ---------- 2次以降の行を作る（フロント向けの額が未設定の段も、0円＝未設定で作る） ----------
create or replace function v2_reward_make_chain(p_app uuid) returns void
language sql security definer set search_path = public as $$
  insert into v2_rewards(application_id, payer_company_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount, refund_policy)
  select r.application_id, co.parent_id, co.id, r.job_id, r.candidate_id, r.joined_on, coalesce(o.fee_display, 0), r.refund_policy
  from v2_rewards r
  join v2_application_parties p on p.application_id = r.application_id
  join v2_companies co on co.id = p.company_id and co.tier > 1
  join v2_application_parties pp on pp.application_id = r.application_id and pp.company_id = co.parent_id   -- 直上の会社も経路上にいること
  left join v2_job_offers o on o.job_id = r.job_id and o.company_id = co.parent_id
  where r.application_id = p_app and r.payer_company_id is null
$$;

-- ---------- 入社日の変更・取り消しの前の確認（支払う会社が記録できない状態なら、KANOAが代わりに直せると案内） ----------
create or replace function v2_rewards_assert_open(p_app uuid, p_cancel boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_what text := case when p_cancel then '入社の判定を取り消せません' else '入社日を変更できません' end; v_who text;
begin
  for r in select rw.payer_company_id, rw.pay_status, rw.resigned_on, rw.refund_status, co.code as payer_code
           from v2_rewards rw left join v2_companies co on co.id = rw.payer_company_id
           where rw.application_id = p_app order by rw.payer_company_id nulls first, co.code loop
    v_who := case when v2_reward_payer_stuck(r.payer_company_id)
      then '支払う会社 ' || r.payer_code || ' は記録できない状態のため、KANOAが報酬の画面の「KANOAが代わりに記録するフロントへの支払い」で'
      else '支払った会社 ' || r.payer_code || ' に、パートナー管理で' end;
    if r.pay_status = 'paid' then
      raise exception 'reward_locked' using errcode = 'P0409', hint = case when r.payer_company_id is null
        then '支払済みの報酬がある選考は、' || v_what || '（先に報酬の画面で「支払済みを取り消す」を行ってください）'
        else 'フロントへの支払いが支払済みになっている選考は、' || v_what || '（' || v_who || '「支払済みを取り消す」を行ってください）' end;
    end if;
    if r.resigned_on is not null or r.refund_status is not null then
      raise exception 'reward_locked' using errcode = 'P0409', hint = case when r.payer_company_id is null
        then case when p_cancel then '退職・返金が記録された報酬がある選考は、' else '退職が記録された報酬がある選考は、' end
             || v_what || '（先に報酬の画面で退職の記録を消してください）'
        else 'フロントへの支払いに退職が記録されている選考は、' || v_what || '（' || v_who || '退職の記録を消してください）' end;
    end if;
  end loop;
end $$;

-- ---------- 実行権限 ----------
revoke all on function v2_reward_payer_stuck(uuid), v2_reward_apply_resignation(uuid, date) from public, anon, authenticated;
revoke all on function v2_reward_lock(uuid, int), v2_reward_make_chain(uuid), v2_rewards_assert_open(uuid, boolean)
  from public, anon, authenticated;
revoke all on function v2_payer_stuck(v2_rewards), v2_reward_set_fee(uuid, int, numeric),
  v2_reward_record_resignation(uuid, int, date) from public, anon;
grant execute on function v2_payer_stuck(v2_rewards), v2_reward_set_fee(uuid, int, numeric),
  v2_reward_record_resignation(uuid, int, date) to authenticated;
