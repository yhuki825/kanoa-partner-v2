-- ============================================================
-- 多段報酬（設計書 14.1。2026-10-16 決定）
--  ・各社は「直上の会社」から報酬を受け取る。KANOA→1次（これまでどおり）、1次→2次、2次→3次…
--  ・2次以降の額 = 直上の会社がその求人でフロント向けに設定した表示額（v2_job_offers.fee_display）。入社確定時に固定
--    表示額の行が無い段は、報酬の行を作らない（額を作り出さない）。公開を止めていても、設定された額があれば使う
--  ・返金規定は、KANOAが求人に登録したものを全段に当てはめる（入社確定時に固定。KANOA→1次と同じもの）
--  ・支払前の退職は差し引き／支払後は返金（118・119 と同じ）。記録は各段の「支払う側」がつける
--    （KANOAが退職を記録しても、下の段には自動で反映しない＝未決定のため）
--  ・書き込み: KANOAが払う行 = RA ／ 会社が払う行 = 支払う会社の代表者だけ
--  ・見える範囲: RAは全件 ／ 受け取る会社・支払う会社のメンバーは、その行だけ（2次からKANOA→1次の行は見えない）
--  ・119 の独立レビュー Low: 0円は支払済みにできない／返金の扱いは支払済みのときだけ（制約）／
--    返金0円で支払済みを取り消した後、本来の支払日で支払済みに戻せる
--  ・関数の引数は選考ID（p_app）から報酬の行ID（p_reward）に変える（1つの選考に行が複数になるため）
-- ============================================================
set check_function_bodies = off;

-- ---------- 1) 1つの選考に、段ごとの報酬の行 ----------
alter table v2_rewards add column payer_company_id uuid references v2_companies(id);   -- 支払う会社（null = KANOA）
alter table v2_rewards drop constraint v2_rewards_pkey;
alter table v2_rewards drop constraint v2_rewards_id_key;
alter table v2_rewards add constraint v2_rewards_pkey primary key (id);
alter table v2_rewards alter column application_id set not null;
alter table v2_rewards add constraint v2_rewards_app_payee unique (application_id, payee_company_id);
alter table v2_rewards add constraint v2_rewards_app_payer unique nulls not distinct (application_id, payer_company_id);
alter table v2_rewards add constraint v2_rewards_payer_not_payee check (payer_company_id is distinct from payee_company_id);
create index v2_rewards_payer on v2_rewards(payer_company_id);

-- ---------- 2) 返金の扱いは支払済みのときだけ（Low b。適用前に違反0行を確認済み） ----------
alter table v2_rewards add constraint v2_rewards_refund_paid check (refund_mode is distinct from 'refund' or pay_status = 'paid');

-- ---------- 3) 2次以降の行を作る（KANOA→1次の行から。入社日・返金規定はその行と同じ） ----------
-- 経路上の各社（2次以降）について、直上の会社がこの求人でフロント向けに設定した額で作る。設定が無い段は作らない
create or replace function v2_reward_make_chain(p_app uuid) returns void
language sql security definer set search_path = public as $$
  insert into v2_rewards(application_id, payer_company_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount, refund_policy)
  select r.application_id, co.parent_id, co.id, r.job_id, r.candidate_id, r.joined_on, o.fee_display, r.refund_policy
  from v2_rewards r
  join v2_application_parties p on p.application_id = r.application_id
  join v2_companies co on co.id = p.company_id and co.tier > 1
  join v2_application_parties pp on pp.application_id = r.application_id and pp.company_id = co.parent_id   -- 直上の会社も経路上にいること
  join v2_job_offers o on o.job_id = r.job_id and o.company_id = co.parent_id
  where r.application_id = p_app and r.payer_company_id is null
$$;

-- 既存のKANOA→1次の行に、下の段の行を足す（1回だけ。適用時点ではテストデータの1行だけ）
select v2_reward_make_chain(application_id) from v2_rewards where payer_company_id is null;

-- ---------- 4) 報酬の行をロックして読む（権限: KANOAが払う行=RA／会社が払う行=その会社の代表者） ----------
drop function if exists v2_reward_lock(uuid);
create function v2_reward_lock(p_reward uuid) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  select * into r from v2_rewards where id = p_reward;
  if not found then
    raise exception 'not_found' using errcode = 'P0404', hint = 'この報酬の記録が見つかりません。画面を読み込み直してください';
  end if;
  if r.payer_company_id is null then
    if not v2_is_ra() then
      raise exception 'permission_denied' using errcode = 'P0403', hint = 'KANOAからの報酬の記録を変更できるのはKANOAだけです';
    end if;
  elsif not (coalesce(v2_my_company() = r.payer_company_id, false) and v2_is_owner()) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = 'フロントへの支払いを記録できるのは、支払う会社の代表者だけです';
  end if;
  select * into r from v2_rewards where id = p_reward for update;   -- 権限を確かめてからロックして読み直す
  return r;
end $$;

-- ---------- 5) 支払済みにする（Low a: 0円は不可／Low c: 返金0円の取り消し後は本来の支払日で戻せる） ----------
drop function if exists v2_reward_mark_paid(uuid, date, numeric);
create function v2_reward_mark_paid(p_reward uuid, p_paid_on date, p_expected_payable numeric) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_payable numeric; v_mode text;
begin
  r := v2_reward_lock(p_reward);
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
    refund_mode = coalesce(v_mode, refund_mode), version = version
  where id = r.id returning * into r;
  return r;
end $$;

-- ---------- 6) 支払済みの取り消し（119 と同じ。行IDで） ----------
drop function if exists v2_reward_unmark_paid(uuid);
create function v2_reward_unmark_paid(p_reward uuid) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_reward);
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
    where id = r.id returning * into r;
  else
    update v2_rewards set pay_status = 'pending', paid_on = null, paid_amount = null, version = version
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- ---------- 7) 退職日の記録（118 と同じ。行IDで。null で記録を消す） ----------
drop function if exists v2_reward_record_resignation(uuid, date);
create function v2_reward_record_resignation(p_reward uuid, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_rate int; v_amount numeric;
begin
  r := v2_reward_lock(p_reward);
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

-- ---------- 8) 返金済みにする（117 と同じ。行IDで） ----------
drop function if exists v2_reward_mark_refunded(uuid, date);
create function v2_reward_mark_refunded(p_reward uuid, p_refunded_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  r := v2_reward_lock(p_reward);
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
  where id = r.id returning * into r;
  return r;
end $$;

-- ---------- 9) 入社日の変更・入社の取り消しの前に、どの段にもお金の記録が無いことを確かめる ----------
-- KANOA→1次の行を先に見る（RAが報酬の画面で直せる）。会社が払う行は、その会社に頼む必要があるので会社コードを出す
create or replace function v2_rewards_assert_open(p_app uuid, p_cancel boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_what text := case when p_cancel then '入社の判定を取り消せません' else '入社日を変更できません' end;
begin
  for r in select rw.payer_company_id, rw.pay_status, rw.resigned_on, rw.refund_status, co.code as payer_code
           from v2_rewards rw left join v2_companies co on co.id = rw.payer_company_id
           where rw.application_id = p_app order by rw.payer_company_id nulls first, co.code loop
    if r.pay_status = 'paid' then
      raise exception 'reward_locked' using errcode = 'P0409', hint = case when r.payer_company_id is null
        then '支払済みの報酬がある選考は、' || v_what || '（先に報酬の画面で「支払済みを取り消す」を行ってください）'
        else 'フロントへの支払いが支払済みになっている選考は、' || v_what || '（支払った会社 ' || r.payer_code
             || ' に、パートナー管理で「支払済みを取り消す」を行うよう依頼してください）' end;
    end if;
    if r.resigned_on is not null or r.refund_status is not null then
      raise exception 'reward_locked' using errcode = 'P0409', hint = case when r.payer_company_id is null
        then case when p_cancel then '退職・返金が記録された報酬がある選考は、' else '退職が記録された報酬がある選考は、' end
             || v_what || '（先に報酬の画面で退職の記録を消してください）'
        else 'フロントへの支払いに退職が記録されている選考は、' || v_what || '（支払った会社 ' || r.payer_code
             || ' に、パートナー管理で退職の記録を消すよう依頼してください）' end;
    end if;
  end loop;
end $$;

-- ---------- 10) マイルストーンの更新（117 の本体に、下の段の行の作成・全段の入社日の更新／取り消しを足す） ----------
-- 既存の確認・動作は 117 のまま。変えたのは「-- 報酬」以下（行が段ごとに複数になったため）
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
    -- 最後の段階（＝入社）を保存するときだけ、この選考の報酬の行（全段）をロックして読む（入社日が変わりうるため）
    perform 1 from v2_rewards where application_id = a.id for update;
    select * into rw from v2_rewards where application_id = a.id order by payer_company_id nulls first limit 1;
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

  -- 報酬（設計書14・14.1）: 社内求人で全段階が通過＝入社 → 各段の成約報酬を、その時点の額・返金規定で固定して記録
  if a.kind <> 'internal' then return; end if;
  if coalesce(v_all, false) and not coalesce(v_failed, false) then
    if ms.seq <> v_last then
      -- 最後以外の段階の保存: 報酬があれば触れない（ロックもしない）。無ければ作る
      -- （選考の行をロックしているので、同じ選考の段階の保存どうしは順番に処理される）
      select * into rw from v2_rewards where application_id = a.id order by payer_company_id nulls first limit 1;
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
        -- 2次以降: 直上の会社がフロント向けに設定した額で（設定の無い段は作らない）
        perform v2_reward_make_chain(a.id);
      end if;
    elsif ms.seq = v_last and rw.joined_on is distinct from v_done then
      -- 入社日（最後の段階の実施日）を直した場合だけ。どの段にも支払・退職・返金の記録が無いときだけ、全段の入社日を直す
      perform v2_rewards_assert_open(a.id, false);
      update v2_rewards set joined_on = v_done, version = version where application_id = a.id;
    end if;
  else
    -- 入社の判定を取り消した場合（報酬の行を消しうるので、ここではロックする）:
    -- どの段にも支払・退職・返金の記録が無ければ全段の報酬の行を消す。あれば止める（お金の記録を宙に浮かせない）
    perform 1 from v2_rewards where application_id = a.id for update;
    if found then
      perform v2_rewards_assert_open(a.id, true);
      delete from v2_rewards where application_id = a.id;
    end if;
  end if;
end $$;

-- ---------- 11) 直上の会社（2次以降の報酬画面で「誰から受け取るか」を出すため。自社の直上の1社だけ） ----------
create or replace function v2_my_upline() returns table (code text, name text)
language sql stable security definer set search_path = public as $$
  select p.code, p.name from v2_companies c join v2_companies p on p.id = c.parent_id where c.id = v2_my_company()
$$;

-- ============================================================
-- RLS（読み取りのみ。書き込みは上の関数だけ）。判定は行自身の列で行う
-- RAは全件／受け取る会社のメンバー／支払う会社のメンバー。それ以外の組の行は見えない
-- ============================================================
drop policy if exists v2_rewards_sel on v2_rewards;
create policy v2_rewards_sel on v2_rewards for select using (
  v2_is_ra()
  or (payee_company_id is not null and payee_company_id = v2_my_company())
  or (payer_company_id is not null and payer_company_id = v2_my_company()));

revoke all on function v2_reward_make_chain(uuid), v2_reward_lock(uuid), v2_rewards_assert_open(uuid, boolean)
  from public, anon, authenticated;
revoke all on function v2_reward_mark_paid(uuid, date, numeric), v2_reward_unmark_paid(uuid),
  v2_reward_record_resignation(uuid, date), v2_reward_mark_refunded(uuid, date), v2_my_upline() from public, anon;
grant execute on function v2_reward_mark_paid(uuid, date, numeric), v2_reward_unmark_paid(uuid),
  v2_reward_record_resignation(uuid, date), v2_reward_mark_refunded(uuid, date), v2_my_upline() to authenticated;
