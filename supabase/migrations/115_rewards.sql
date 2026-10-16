-- ============================================================
-- 第5段階（後半）: 報酬（設計書 14。2026-10-16 決定）
--  ・成約報酬だけ。社内求人の選考の「最後の段階が通過」＝入社で発生（入社日＝その段階の実施日）
--  ・支払先は経路上の1次パートナー。KANOA自身の求職者・外部求人は対象外
--  ・入社確定時の紹介料（税抜）と返金規定を、報酬の記録に固定する（後で求人の設定を変えても過去分は変わらない）
--  ・見える人: RAは全件／1次パートナーは自社が支払先の分だけ（閲覧のみ）／2次以降は見えない
--    → 2次以降も読める v2_applications・v2_jobs には列を足さず、別の表にする（列ごと見えてしまうため）
--  ・書き込みはRAだけの関数（RPC）から。表を直接書き換えさせない
-- ============================================================
set check_function_bodies = off;

-- ---------- 求人ごとの返金規定（KANOA⇔1次の契約条件） ----------
-- policy: [{"months":1,"rate":100},{"months":3,"rate":50}] … 入社日から◯か月以内の退職なら◯%返金
create table v2_job_refund_policies (
  job_id uuid primary key references v2_jobs(id) on delete cascade,
  id uuid unique not null default gen_random_uuid(),      -- 操作記録（v2_audit）用
  policy jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create trigger v2_job_refund_policies_touch before insert or update on v2_job_refund_policies for each row execute function v2_touch();
create trigger v2_job_refund_policies_audit after insert or update or delete on v2_job_refund_policies for each row execute function v2_audit();

-- ---------- 報酬（選考1件につき1行。入社確定時に作られる） ----------
create table v2_rewards (
  application_id uuid primary key references v2_applications(id) on delete cascade,
  id uuid unique not null default gen_random_uuid(),      -- 操作記録（v2_audit）用
  payee_company_id uuid not null references v2_companies(id),   -- 支払先（1次パートナー）
  job_id uuid not null references v2_jobs(id),
  candidate_id uuid not null references v2_candidates(id),
  joined_on date not null,                                -- 入社日
  fee_amount numeric not null check (fee_amount >= 0),    -- 紹介料（税抜）。入社確定時の額で固定
  refund_policy jsonb not null default '[]',              -- 入社確定時の返金規定で固定
  pay_status text not null default 'pending' check (pay_status in ('pending','paid')),
  paid_on date,
  resigned_on date,                                       -- 退職日
  refund_rate int check (refund_rate between 0 and 100),
  refund_amount numeric check (refund_amount >= 0),       -- 返金額（税抜）
  refund_status text check (refund_status in ('pending','refunded')),
  refunded_on date,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  constraint v2_rewards_paid check ((pay_status = 'paid') = (paid_on is not null)),
  constraint v2_rewards_resign check ((resigned_on is null) = (refund_rate is null) and (resigned_on is null) = (refund_amount is null)),
  constraint v2_rewards_refund check (refund_status is null or resigned_on is not null),
  constraint v2_rewards_refunded check ((refund_status = 'refunded') = (refunded_on is not null))
);
create index v2_rewards_payee on v2_rewards(payee_company_id);
create trigger v2_rewards_touch before insert or update on v2_rewards for each row execute function v2_touch();
create trigger v2_rewards_audit after insert or update or delete on v2_rewards for each row execute function v2_audit();

-- ---------- 返金規定の形を確かめて、月数の昇順に並べ直す（形が違えばエラー） ----------
create or replace function v2_refund_policy_normalize(p jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare e jsonb; v_out jsonb := '[]'; v_months int[] := '{}'; m numeric; r numeric;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定の形が正しくありません';
  end if;
  if jsonb_array_length(p) > 20 then
    raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定は20行までです';
  end if;
  for e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(e) <> 'object' then
      raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定の各行には「◯か月以内」と「◯%」を数字で入れてください';
    end if;
    if exists (select 1 from jsonb_object_keys(e) k where k not in ('months','rate'))
       or jsonb_typeof(e->'months') is distinct from 'number' or jsonb_typeof(e->'rate') is distinct from 'number' then
      raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定の各行には「◯か月以内」と「◯%」を数字で入れてください';
    end if;
    m := (e->>'months')::numeric; r := (e->>'rate')::numeric;
    if m <> trunc(m) or m < 1 or m > 120 then
      raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定の月数は1〜120の整数で入れてください';
    end if;
    if r <> trunc(r) or r < 0 or r > 100 then
      raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定の返金率は0〜100の整数（%）で入れてください';
    end if;
    if m::int = any(v_months) then
      raise exception 'bad_refund_policy' using errcode = 'P0400', hint = '返金規定に同じ月数の行が2つあります';
    end if;
    v_months := v_months || m::int;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('months', (x->>'months')::numeric::int, 'rate', (x->>'rate')::numeric::int)
                            order by (x->>'months')::numeric), '[]')
    into v_out from jsonb_array_elements(p) x;
  return v_out;
end $$;

-- 退職日から返金率を出す: 月数の昇順で「退職日 <= 入社日 + ◯か月」を満たす最初の行の率。無ければ0
create or replace function v2_refund_rate(p_policy jsonb, p_joined date, p_resigned date) returns int
language sql immutable set search_path = public as $$
  select coalesce((
    select (x->>'rate')::int from jsonb_array_elements(coalesce(p_policy, '[]')) x
    where p_resigned <= p_joined + ((x->>'months')::int * interval '1 month')
    order by (x->>'months')::int limit 1), 0)
$$;

-- ---------- 返金規定の保存（RAだけ。無ければ作る） ----------
create or replace function v2_job_refund_policy_save(p_job uuid, p_policy jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_policy jsonb;
begin
  if not v2_is_ra() then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '返金規定を変更できるのはKANOAだけです';
  end if;
  if not exists (select 1 from v2_jobs where id = p_job) then
    raise exception 'not_found' using errcode = 'P0404', hint = '求人が見つかりません';
  end if;
  v_policy := v2_refund_policy_normalize(p_policy);
  insert into v2_job_refund_policies(job_id, policy) values (p_job, v_policy)
  on conflict (job_id) do update set policy = excluded.policy, version = v2_job_refund_policies.version;
  return v_policy;
end $$;

-- ---------- 報酬の操作（RAだけ） ----------
create or replace function v2_reward_lock(p_app uuid) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype;
begin
  if not v2_is_ra() then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '報酬の記録を変更できるのはKANOAだけです';
  end if;
  select * into r from v2_rewards where application_id = p_app for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0404', hint = 'この選考の報酬の記録が見つかりません。画面を読み込み直してください';
  end if;
  return r;
end $$;

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
  update v2_rewards set pay_status = 'paid', paid_on = p_paid_on, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;

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
  update v2_rewards set pay_status = 'pending', paid_on = null, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;

-- 退職日の記録（null で記録を消す）。返金率・返金額は入社時に固定した返金規定から計算する
create or replace function v2_reward_record_resignation(p_app uuid, p_resigned_on date) returns v2_rewards
language plpgsql security definer set search_path = public as $$
declare r v2_rewards%rowtype; v_rate int; v_amount numeric;
begin
  r := v2_reward_lock(p_app);
  if r.refund_status = 'refunded' then
    raise exception 'already_refunded' using errcode = 'P0409', hint = '返金済みのため、退職の記録は変更できません';
  end if;
  if p_resigned_on is null then
    update v2_rewards set resigned_on = null, refund_rate = null, refund_amount = null, refund_status = null,
      refunded_on = null, version = version
    where application_id = p_app returning * into r;
    return r;
  end if;
  if p_resigned_on < r.joined_on then
    raise exception 'resigned_before_joined' using errcode = 'P0400', hint = '退職日が入社日より前になっています';
  end if;
  v_rate := v2_refund_rate(r.refund_policy, r.joined_on, p_resigned_on);
  v_amount := round(r.fee_amount * v_rate / 100);
  update v2_rewards set resigned_on = p_resigned_on, refund_rate = v_rate, refund_amount = v_amount,
    refund_status = case when v_amount > 0 then 'pending' end, refunded_on = null, version = version
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
  update v2_rewards set refund_status = 'refunded', refunded_on = p_refunded_on, version = version
  where application_id = p_app returning * into r;
  return r;
end $$;

-- ---------- マイルストーンの更新に、報酬の記録（入社確定）と取り消しを足す ----------
-- 既存の確認・動作は 106 のまま。足したのは「-- 報酬」以下だけ
create or replace function v2_milestone_save(p_id uuid, p_version int, p_scheduled date, p_done date, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare me record; ms v2_milestones%rowtype; a v2_applications%rowtype; v_failed boolean; v_all boolean;
        rw v2_rewards%rowtype; v_has_reward boolean; v_joined date; v_payee uuid; v_fee numeric;
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

  -- 報酬（設計書14）: 社内求人で全段階が通過＝入社 → 1次パートナーへの成約報酬を、その時点の額・返金規定で固定して記録
  select * into rw from v2_rewards where application_id = a.id for update;
  v_has_reward := found;
  if coalesce(v_all, false) and not coalesce(v_failed, false) then
    if a.kind = 'internal' then
      select done_on into v_joined from v2_milestones where application_id = a.id order by seq desc limit 1;
      v_joined := coalesce(v_joined, current_date);
      if not v_has_reward then
        select co.id into v_payee from v2_application_parties p join v2_companies co on co.id = p.company_id
        where p.application_id = a.id and co.tier = 1 limit 1;
        if v_payee is not null then   -- KANOA自身の求職者（1次がいない）は対象外
          v_fee := coalesce((select fee_override from v2_job_shares where job_id = a.job_id and company_id = v_payee),
                            (select fee from v2_job_kanoa_fees where job_id = a.job_id), 0);
          insert into v2_rewards(application_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount, refund_policy)
          values (a.id, v_payee, a.job_id, a.candidate_id, v_joined, v_fee,
                  coalesce((select policy from v2_job_refund_policies where job_id = a.job_id), '[]'));
        end if;
      elsif rw.joined_on is distinct from v_joined then
        -- 入社日（最後の段階の実施日）を直した場合: 返金の計算が変わるため、退職の記録があるときは止める
        if rw.resigned_on is not null then
          raise exception 'reward_locked' using errcode = 'P0409',
            hint = '退職が記録された報酬がある選考は、入社日を変更できません（先に報酬の画面で退職の記録を消してください）';
        end if;
        update v2_rewards set joined_on = v_joined, version = version where application_id = a.id;
      end if;
    end if;
  elsif v_has_reward then
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
end $$;

-- ============================================================
-- RLS（読み取りのみ。書き込みは上の関数だけ）
-- 判定は行自身の列で行う（2026-10-15 の失敗記録）
-- ============================================================
alter table v2_rewards enable row level security;
alter table v2_job_refund_policies enable row level security;

-- 報酬: RAは全件。CAは自社が支払先の行だけ（支払先は常に1次なので、2次以降には1行も見えない）
create policy v2_rewards_sel on v2_rewards for select using (
  v2_is_ra() or (payee_company_id is not null and payee_company_id = v2_my_company()));

-- 返金規定: RAは全件。CAは1次パートナーで、その求人を提示されている場合だけ
create policy v2_job_refund_policies_sel on v2_job_refund_policies for select using (
  v2_is_ra()
  or (exists (select 1 from v2_companies c where c.id = v2_my_company() and c.tier = 1)
      and v2_job_visible(job_id, v2_my_company())));

revoke insert, update, delete, truncate on v2_rewards, v2_job_refund_policies from anon, authenticated;

revoke all on function v2_refund_policy_normalize(jsonb), v2_refund_rate(jsonb, date, date), v2_reward_lock(uuid)
  from public, anon, authenticated;
revoke all on function v2_job_refund_policy_save(uuid, jsonb), v2_reward_mark_paid(uuid, date), v2_reward_unmark_paid(uuid),
  v2_reward_record_resignation(uuid, date), v2_reward_mark_refunded(uuid, date) from public, anon;
grant execute on function v2_job_refund_policy_save(uuid, jsonb), v2_reward_mark_paid(uuid, date), v2_reward_unmark_paid(uuid),
  v2_reward_record_resignation(uuid, date), v2_reward_mark_refunded(uuid, date) to authenticated;
