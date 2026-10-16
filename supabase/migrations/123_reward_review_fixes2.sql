-- ============================================================
-- 122（多段報酬の運用ルール）のレビュー指摘の修正
--  1) 行き詰まり（デッドロック）の防止: v2_milestone_save は「選考（v2_applications）→ 報酬の行」の順にロックする。
--     退職の記録（下の段への反映あり）も、先に選考の行をロックしてから報酬の行をロックする（どちらも 選考 → 報酬 の順になる）
--     ※ 報酬の行が無い id なら選考は何もロックされず、v2_reward_lock がこれまでどおり止める（P0403／RAなら P0409）
--  2) 退職の記録が無い行で「退職の記録を消す」を行ったとき、下の段（退職日の無い行）を空の更新で動かさない
--     （version が上がって画面が古くなる・操作の記録が無駄に増えるのを防ぐ）
-- ============================================================
set check_function_bodies = off;

-- ---------- 退職日の記録（null で記録を消す）。下の段にも反映する ----------
create or replace function v2_reward_record_resignation(p_reward uuid, p_version int, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; d record; v_old date; v_tier int;
begin
  -- ロックの順: 選考の行 → この報酬の行 → 下の段の行（階層の浅い順）。v2_milestone_save も 選考 → 報酬 の順なので行き詰まらない
  perform 1 from v2_applications where id = (select application_id from v2_rewards where id = p_reward) for update;
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

  -- 退職の記録が無いものを消した: 下の段に消すものは無い（空の更新で version を上げない）
  if p_resigned_on is null and v_old is null then
    return r;
  end if;

  -- 下の段（受け取る会社の階層が深い行）へ反映。選考の行は上でロック済み
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

-- ---------- 実行権限（create or replace なので変わらないが、念のため同じ形にそろえる） ----------
revoke all on function v2_reward_record_resignation(uuid, int, date) from public, anon;
grant execute on function v2_reward_record_resignation(uuid, int, date) to authenticated;
