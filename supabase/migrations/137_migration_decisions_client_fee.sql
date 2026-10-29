-- 137: 移行の決定（2026-10-29「3〜6は推奨どおり」）と、求人企業からの紹介料の置き場
--  3) 入社日が入っているのに「内定」の3人: 今の扱いのまま（入社日になったら KANOA が記録する）→ 変更なし
--  4) PT000「株式会社テスト」は移さない（KA999・RE999 と同じ）。移さない会社の求職者・紹介フォーム・書類・連絡は
--     「失敗」ではなく「意図して移さない（skipped）」と数える
--  5) 求人企業から KANOA への紹介料（V1 の client_fee）を、KANOA だけが見られる表 v2_job_client_fees に置く
--     （パートナーには見せない。RLS は RA だけ）。移行でも写し、照合に V1 と V2 の合計を出す
--  6) V1 の文字のリアクション（「承知しました」など、V2 で使える5つ以外）は ✅ に置き換える（同じ人の重なりは1つに）
--  ※ 関数は 129 の版（DBに入っている本体）からの書き換え。begin/commit は書いていない
--  戻すとき: 129 の関数を流し直し、drop table v2_job_client_fees（先に関数を戻すこと）
set check_function_bodies = off;

create table if not exists v2_job_client_fees (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references v2_jobs(id) on delete cascade,
  fee numeric not null check (fee = trunc(fee) and fee >= 0 and fee < 1000000000000),   -- 税抜・円
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
drop trigger if exists v2_job_client_fees_touch on v2_job_client_fees;
create trigger v2_job_client_fees_touch before insert or update on v2_job_client_fees for each row execute function v2_touch();
drop trigger if exists v2_job_client_fees_audit on v2_job_client_fees;
create trigger v2_job_client_fees_audit after insert or update or delete on v2_job_client_fees for each row execute function v2_audit();
alter table v2_job_client_fees enable row level security;
drop policy if exists v2_job_client_fees_ra on v2_job_client_fees;
create policy v2_job_client_fees_ra on v2_job_client_fees for all using (v2_is_ra()) with check (v2_is_ra());
revoke all on v2_job_client_fees from anon;

CREATE OR REPLACE FUNCTION public.v2_v1_migrate(p_joined_until date DEFAULT NULL::date, p_activate_members boolean DEFAULT false, p_force_after_cutover boolean DEFAULT false, p_discard_preview_edits boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_until date := coalesce(p_joined_until, (now() at time zone 'Asia/Tokyo')::date);
  v_ra uuid; v_purged jsonb; v_summary jsonb;
  a record; p record; rf record; it record; d record;
  v_code text; v_cid uuid; v_mid uuid; v_jid uuid; v_cand uuid; v_app uuid;
  v_flow jsonb; v_n int; v_is int; v_ii int; v_io int;
  v_joined boolean; v_stage text; v_result text; v_mode text; v_passed int; v_fail int;
  v_sched date; v_txt text; v_kmemo text; v_amemo text; v_state text; v_con text; v_reason text; v_other text;
  v_docs jsonb; v_ext text; v_fid uuid; v_dst text; v_rid uuid; v_fee numeric; v_policy jsonb;
  v_ras uuid[]; v_refid text; v_merged boolean;
begin
  -- RA（KANOA の送信者・お知らせの作成者）
  select id into v_ra from v2_members where role = 'ra' and status = 'active' order by created_at limit 1;
  if v_ra is null then raise exception 'no active RA member'; end if;
  v_ras := array(select id from v2_members where role = 'ra' and status = 'active' order by created_at);
  -- H1(a) 切替の鍵: 代表CAを有効にした（＝切替済み）あとは、明示の指定が無い限り流し直さない
  if v2_v1_cutover_done() and not p_force_after_cutover then
    raise exception 'cutover_locked' using errcode = 'P0409',
      hint = '切替（代表CAの有効化）後の流し直しは止めています。本当に流す場合だけ --force-after-cutover を付けてください（V2 で作られたデータが残っていれば、その場合も止まります）';
  end if;

  -- お試し中の操作を捨てるのは切替前だけ（切替後は本物のデータのため、どの指定でも捨てない）
  if p_discard_preview_edits and v2_v1_cutover_done() then
    raise exception 'discard_after_cutover' using errcode = 'P0409',
      hint = '--discard-preview-edits は切替前だけ使えます（切替後は V2 のデータを捨てません）';
  end if;
  perform v2_v1_triggers(false);
  v_purged := v2_v1_purge(p_discard_preview_edits);

  -- ========== 1) 会社（agencies → v2_companies、代表CA） ==========
  for a in select * from agencies order by joined nulls last, created_at, id loop
    if a.code in ('KA999','RE999','PT000') then
      insert into v2_v1_map values ('agency', a.id, null, 'skipped', 'decision 5 (PT000: 2026-10-29): test/internal account (' || a.code || ') not migrated');
      continue;
    end if;
    select code into v_code from v2_v1_company_codes where agency_id = a.id;
    if v_code is null then
      v_code := v2_next_code(1);
      insert into v2_v1_company_codes(agency_id, code) values (a.id, v_code);
    end if;
    v_cid := v2_v1_uuid('agency', a.id);
    insert into v2_companies(id, code, tier, parent_id, name, status, member_seq, created_at, updated_at)
    values (v_cid, v_code, 1, null, btrim(a.name), case when coalesce(a.status, 'active') = 'active' then 'active' else 'suspended' end, 1,
            coalesce((a.joined::timestamp at time zone 'Asia/Tokyo'), a.created_at, now()), coalesce(a.created_at, now()));
    insert into v2_v1_map values ('agency', a.id, v_cid, 'migrated', null);
    -- 代表CA: V1 のログイン用アカウント（agencies.auth_user_id）に紐づける。お試し中は停止（V2 に入れない）
    if a.auth_user_id is null then
      insert into v2_v1_map values ('owner_member', a.id, null, 'failed', 'agency has no V1 auth user (auth_user_id is null)');
      continue;
    end if;
    begin
      v_mid := v2_v1_uuid('owner_member', a.id);
      insert into v2_members(id, user_id, company_id, role, login_id, name, email, is_owner, status, must_change_pw, created_at, updated_at)
      values (v_mid, a.auth_user_id, v_cid, 'ca', v_code || '-01',
              coalesce(nullif(btrim(a.contact), ''), btrim(a.name)), nullif(btrim(a.email), ''), true,
              case when p_activate_members then 'active' else 'suspended' end, false,
              coalesce((a.joined::timestamp at time zone 'Asia/Tokyo'), a.created_at, now()), now());
      insert into v2_v1_map values ('owner_member', a.id, v_mid, 'migrated', null);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_con = constraint_name;
      insert into v2_v1_map values ('owner_member', a.id, null, 'failed', 'insert failed: ' || v_state || coalesce(' ' || nullif(v_con, ''), ''));
    end;
  end loop;

  -- ========== 2) 求人企業・求人（projects → v2_clients + v2_jobs） ==========
  insert into v2_clients(id, name, created_at, updated_at)
  select v2_v1_uuid('client', btrim(coalesce(nullif(client, ''), name))), btrim(coalesce(nullif(client, ''), name)), min(created_at), max(created_at)
  from projects group by btrim(coalesce(nullif(client, ''), name));
  insert into v2_v1_map(kind, v1_id, v2_id, status)
  select 'client', btrim(coalesce(nullif(client, ''), name)), v2_v1_uuid('client', btrim(coalesce(nullif(client, ''), name))), 'migrated'
  from projects group by btrim(coalesce(nullif(client, ''), name));

  for p in select * from projects order by created_at, id loop
    v_jid := v2_v1_uuid('project', p.id);
    -- 選考フロー: V1 の {t,s} の t を段階名に。最後が「入社」でなければ「入社」を足す（V2 は最後の段階の通過＝入社）
    select coalesce(jsonb_agg(btrim(e->>'t') order by o), '[]') into v_flow
    from jsonb_array_elements(case when jsonb_typeof(p.flow) = 'array' then p.flow else '[]' end) with ordinality x(e, o)
    where coalesce(btrim(e->>'t'), '') <> '';
    if jsonb_array_length(v_flow) = 0 then v_flow := '["書類選考","一次面接","最終面接","内定"]'; end if;
    if not (v_flow ? '入社') then v_flow := v_flow || '["入社"]'; end if;
    insert into v2_jobs(id, client_id, title, description, employment, salary, location, conditions, entry_requirements, flow, checks, status, detail, created_at, updated_at)
    values (v_jid, v2_v1_uuid('client', btrim(coalesce(nullif(p.client, ''), p.name))), btrim(p.name),
      concat_ws(E'\n\n',
        nullif('職種：' || nullif(btrim(p.position), ''), '職種：'),
        nullif(btrim(v2_v1_strip_fee_sections(p.summary)), ''),
        '【採用予定数】' || nullif(btrim(v2_v1_strip_fee_sections(p.headcount)), ''),
        '【選考会】' || nullif(btrim(v2_v1_strip_fee_sections(p.seminar)), ''),
        '【通過のポイント】' || nullif(btrim(v2_v1_strip_fee_sections(p.pass_note)), ''),
        '【実績】' || nullif(btrim(v2_v1_strip_fee_sections(p.case_study)), '')),
      nullif(btrim(p.employment), ''), nullif(btrim(p.salary), ''), nullif(btrim(p.location), ''),
      concat_ws(E'\n\n',
        nullif(btrim(v2_v1_strip_fee_sections(p.conditions)), ''),
        (select '【応募要件】' || E'\n' || string_agg('・' || btrim(x), E'\n' order by o)
           from jsonb_array_elements_text(case when jsonb_typeof(p.requirements) = 'array' then p.requirements else '[]' end) with ordinality r(x, o)
          where btrim(x) <> ''),
        (select '【選考フローの補足】' || E'\n' || string_agg('・' || btrim(e->>'t') || '：' || btrim(e->>'s'), E'\n' order by o)
           from jsonb_array_elements(case when jsonb_typeof(p.flow) = 'array' then p.flow else '[]' end) with ordinality x(e, o)
          where coalesce(btrim(e->>'s'), '') <> '')),
      '["name"]', v_flow,
      jsonb_build_object('spi', coalesce((p.detail->>'checksEnabled')::boolean, p.detail->>'rewardModel' = 'rakuten', false),
                         'compliance', coalesce((p.detail->>'checksEnabled')::boolean, p.detail->>'rewardModel' = 'rakuten', false)),
      case coalesce(p.status, 'open') when 'open' then 'open' when 'closed' then 'closed' else 'paused' end,
      -- 付帯情報（2次以降を含む全パートナーに読める列）: 求職者・選考の説明だけを決めた鍵で写す
      -- 紹介料・KANOA の受取額・返金に関わる鍵（rewardModel / rewardExample / rewardFormula / refundPolicy）、
      -- 社内の切替（checksEnabled → checks に反映済み）、client_fee・ロゴ・送客報酬（referral_reward / reward_type）は入れない
      (select coalesce(jsonb_object_agg(e.k, e.v), '{}')
         from jsonb_each(case when jsonb_typeof(p.detail) = 'object' then p.detail else '{}' end) e(k, v)
        where e.k = any (array['faq','links','docReqs','preDocs','preNote','preTasks','selection','careerNote','careerPath',
                               'incentives','incomeRange','interviewTips','companyOverview','baseSalaryByArea'])
          and e.v <> 'null'::jsonb)
        || jsonb_build_object('v1', jsonb_strip_nulls(jsonb_build_object(
             'project_id', p.id, 'position', p.position, 'headcount', nullif(v2_v1_strip_fee_sections(p.headcount), ''), 'seminar', nullif(v2_v1_strip_fee_sections(p.seminar), ''),
             'pass_note', nullif(v2_v1_strip_fee_sections(p.pass_note), ''), 'case_study', nullif(v2_v1_strip_fee_sections(p.case_study), ''), 'flow', p.flow, 'requirements', p.requirements,
             'color', p.color))),
      coalesce(p.created_at, now()), coalesce(p.created_at, now()));
    -- KANOA→1次の紹介料（成約報酬）
    insert into v2_job_kanoa_fees(job_id, fee, created_at, updated_at)
    values (v_jid, coalesce(p.success_reward, 0), coalesce(p.created_at, now()), coalesce(p.created_at, now()));
    -- 求人企業から KANOA への紹介料（KANOA だけが見られる表。2026-10-29 決定）
    if p.client_fee is not null then
      insert into v2_job_client_fees(job_id, fee, created_at, updated_at)
      values (v_jid, p.client_fee, coalesce(p.created_at, now()), coalesce(p.created_at, now()));
    end if;
    -- 返金規定: V1 の文章「◯か月以内 … ◯%返金」を読めた行だけ（経歴詐称の全額返金は V2 に項目が無い）
    select coalesce(jsonb_agg(jsonb_build_object('months', (m[1])::int, 'rate', (m[2])::int)), '[]') into v_policy
    from jsonb_array_elements_text(case when jsonb_typeof(p.detail->'refundPolicy') = 'array' then p.detail->'refundPolicy' else '[]' end) t(line)
    cross join lateral regexp_match(line, '([0-9]+)\s*か月以内[^0-9]*?([0-9]+)\s*%') m
    where m is not null;
    if jsonb_array_length(v_policy) > 0 then
      insert into v2_job_refund_policies(job_id, policy, created_at, updated_at)
      values (v_jid, v2_refund_policy_normalize(v_policy), coalesce(p.created_at, now()), coalesce(p.created_at, now()));
    end if;
    insert into v2_v1_map values ('project', p.id, v_jid, 'migrated', null);
  end loop;

  -- ========== 3) 公開（assignments → v2_job_shares） ==========
  insert into v2_job_shares(id, job_id, company_id, published, fee_override, created_at, updated_at)
  select v2_v1_uuid('assignment', s.project_id || '|' || s.agency_id), v2_v1_uuid('project', s.project_id), ma.v2_id,
         coalesce(s.published, false), s.suc_override, now(), now()
  from assignments s
  join v2_v1_map ma on ma.kind = 'agency' and ma.v1_id = s.agency_id and ma.status = 'migrated'
  join v2_v1_map mp on mp.kind = 'project' and mp.v1_id = s.project_id and mp.status = 'migrated';
  insert into v2_v1_map(kind, v1_id, v2_id, status, reason)
  select 'assignment', s.project_id || '|' || s.agency_id,
         case when ma.status = 'migrated' then v2_v1_uuid('assignment', s.project_id || '|' || s.agency_id) end,
         case when ma.status = 'migrated' then 'migrated' else 'skipped' end,
         case when ma.status = 'migrated' then null else 'agency not migrated (' || s.agency_id || ')' end
  from assignments s left join v2_v1_map ma on ma.kind = 'agency' and ma.v1_id = s.agency_id;

  -- ========== 4) 送客（referrals → 求職者＋選考＋参加会社＋段階＋メモ） ==========
  for rf in
    select r.*, ma.v2_id as cid, mm.v2_id as mid, mp.v2_id as jid, j.flow as vflow
    from referrals r
    left join v2_v1_map ma on ma.kind = 'agency' and ma.v1_id = r.agency_id and ma.status = 'migrated'
    left join v2_v1_map mm on mm.kind = 'owner_member' and mm.v1_id = r.agency_id and mm.status = 'migrated'
    left join v2_v1_map mp on mp.kind = 'project' and mp.v1_id = r.project_id and mp.status = 'migrated'
    left join v2_jobs j on j.id = mp.v2_id
    order by r.created_at, r.id
  loop
    if rf.cid is null then
      insert into v2_v1_map values ('referral', rf.id, null,
        case when exists (select 1 from v2_v1_map x where x.kind = 'agency' and x.v1_id = rf.agency_id and x.status = 'skipped') then 'skipped' else 'failed' end,
        'agency not migrated (' || coalesce(rf.agency_id, 'null') || ')');
      continue;
    end if;
    if rf.jid is null then
      insert into v2_v1_map values ('referral', rf.id, null, 'failed', 'project not migrated (' || coalesce(rf.project_id, 'null') || ')');
      continue;
    end if;
    -- 段階の位置（求人のフローから。無ければ順番で）
    v_flow := rf.vflow; v_n := jsonb_array_length(v_flow);
    select min(o) into v_is from jsonb_array_elements_text(v_flow) with ordinality x(t, o) where t ~ '書類';
    v_is := coalesce(v_is, 1);
    select min(o) into v_ii from jsonb_array_elements_text(v_flow) with ordinality x(t, o) where t ~ '面接|選考会' and o > v_is;
    v_ii := coalesce(v_ii, least(v_is + 1, v_n - 1));
    select min(o) into v_io from jsonb_array_elements_text(v_flow) with ordinality x(t, o) where t ~ '内定|合否|オファー' and o > v_ii and o < v_n;
    v_io := coalesce(v_io, v_n - 1);
    v_joined := rf.status in ('joined','resigned') or (rf.joined_on is not null and rf.joined_on <= v_until);
    v_result := null; v_passed := 0; v_fail := null; v_mode := 'steps';
    if v_joined then v_stage := 'closed'; v_result := 'passed'; v_passed := v_n;
    elsif rf.status = 'entry' then v_stage := 'relay'; v_mode := 'none';
    elsif rf.status = 'screening' then v_stage := 'active'; v_passed := v_is - 1;
    elsif rf.status = 'interview' then v_stage := 'active'; v_passed := v_ii - 1;
    elsif rf.status = 'offer' then v_stage := 'active'; v_passed := v_io;
    elsif rf.status = 'rejected' then
      if rf.fail_at in ('screening','interview','offer') then
        v_fail := case rf.fail_at when 'screening' then v_is when 'interview' then v_ii else v_io end;
        v_stage := 'closed'; v_result := 'failed'; v_passed := v_fail - 1;
      else v_stage := 'rejected'; v_mode := 'none';   -- 送客済の段階での見送り（KANOA の受入前）
      end if;
    elsif rf.status = 'declined' then
      v_stage := 'withdrawn';
      if rf.fail_at in ('screening','interview','offer') then
        v_passed := case rf.fail_at when 'screening' then v_is when 'interview' then v_ii else v_io end - 1;
      else v_mode := 'none';
      end if;
    else
      insert into v2_v1_map values ('referral', rf.id, null, 'failed', 'unknown V1 status: ' || coalesce(rf.status, 'null'));
      continue;
    end if;

    -- KANOA だけが見るメモ（管理者メモ＋V1 の付帯情報）／紹介した会社だけが見るメモ
    v_txt := concat_ws(E'\n',
      '紹介元：' || nullif(btrim(rf.source_company), ''),
      '住所：' || nullif(btrim(rf.address), ''),
      '選考会日：' || nullif(btrim(rf.session), ''),
      case when coalesce(rf.spi_status, 'none') <> 'none' or coalesce(rf.compliance_status, 'none') <> 'none'
           then 'SPI：' || v2_v1_check_label(rf.spi_status) || '／コンプライアンスチェック：' || v2_v1_check_label(rf.compliance_status) end,
      case when rf.joined_on is not null and not v_joined then '入社予定日：' || to_char(rf.joined_on, 'YYYY-MM-DD') end,
      case when coalesce(rf.resigned, false) or rf.resigned_on is not null then '退職：' || coalesce(to_char(rf.resigned_on, 'YYYY-MM-DD'), '日付なし')
           || case when coalesce(rf.resign_fraud, false) then '（経歴詐称）' else '' end end,
      'メモ：' || nullif(btrim(rf.note), ''));
    -- KANOA のメモ = 管理者メモ ＋ 引継ぎ（支払ステータスは KANOA だけ）
    v_kmemo := nullif(concat_ws(E'\n\n', nullif(btrim(rf.admin_note), ''),
      '― V1から引継ぎ ―' || E'\n' || nullif(concat_ws(E'\n', nullif(v_txt, ''), '支払ステータス（V1）：' || nullif(btrim(rf.pay_status), '')), '')), '');
    v_amemo := '― V1から引継ぎ ―' || E'\n' || nullif(v_txt, '');

    v_cand := v2_v1_uuid('candidate', rf.id);
    v_app := v2_v1_uuid('referral', rf.id);
    begin
      insert into v2_candidates(id, owner_company_id, assigned_member_id, name, kana, phone, email, prefecture, desired_location,
                                created_by, created_at, updated_at)
      values (v_cand, rf.cid, rf.mid, coalesce(nullif(btrim(rf.name), ''), '（氏名未入力）'), nullif(btrim(rf.kana), ''),
              nullif(btrim(rf.phone), ''), nullif(btrim(rf.email), ''), v2_v1_prefecture(rf.address), nullif(btrim(rf.area), ''),
              rf.mid, coalesce(rf.created_at, now()), coalesce(rf.created_at, now()));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_con = constraint_name;
      select string_agg(m.v1_id, ',') into v_other from v2_v1_map m
      join v2_candidates c on c.id = case when m.kind = 'referral' then v2_v1_uuid('candidate', m.v1_id) else m.v2_id end
      where m.kind in ('referral','intake') and m.status = 'migrated' and v_con = 'v2_candidates_phone_uq'
        and c.phone_norm = regexp_replace(coalesce(rf.phone, ''), '[^0-9]', '', 'g');
      insert into v2_v1_map values ('referral', rf.id, null, 'failed',
        'candidate blocked: ' || v_state || coalesce(' ' || nullif(v_con, ''), '')
        || case when v_other is not null then ' (same phone as V1 ' || v_other || ')'
                when v_con = 'v2_candidates_phone_uq' then ' (same phone as a V2 candidate not created by this migration)' else '' end);
      continue;
    end;
    if v_kmemo is not null then
      insert into v2_candidate_notes(id, candidate_id, company_id, memo, created_at, updated_at)
      values (v2_v1_uuid('note:kanoa', rf.id), v_cand, null, v_kmemo, rf.created_at, rf.created_at);
    end if;
    if v_amemo is not null then
      insert into v2_candidate_notes(id, candidate_id, company_id, memo, created_at, updated_at)
      values (v2_v1_uuid('note:company', rf.id), v_cand, rf.cid, v_amemo, rf.created_at, rf.created_at);
    end if;

    insert into v2_applications(id, candidate_id, kind, job_id, applied_by_company, applied_by_member, holder_company_id,
                                kanoa_visible, stage, result, created_at, updated_at)
    values (v_app, v_cand, 'internal', rf.jid, rf.cid, rf.mid, null, true, v_stage, v_result,
            coalesce(rf.created_at, now()),
            greatest(coalesce(rf.created_at, now()),
                     coalesce((select max(m.created_at) from messages m where m.ref_id = rf.id), '-infinity'),
                     coalesce((select max(l.created_at) from reflog l where l.ref_id = rf.id), '-infinity')));
    insert into v2_application_parties values (v_app, rf.cid);
    if v_mode = 'steps' then
      v_sched := v2_v1_session_date(rf.session, rf.created_at);
      insert into v2_milestones(application_id, seq, name, scheduled_on, done_on, result, created_at, updated_at)
      select v_app, o::int, t,
             case when o = v_n and rf.joined_on is not null then rf.joined_on
                  when o = v_ii and v_sched is not null then v_sched end,
             case when o = v_n and v_joined then coalesce(rf.joined_on, (now() at time zone 'Asia/Tokyo')::date) end,   -- V2 と同じ: 日付が無ければ今日
             case when o <= v_passed then 'passed' when o = v_fail then 'failed' else 'pending' end,
             rf.created_at, rf.created_at
      from jsonb_array_elements_text(v_flow) with ordinality x(t, o);
    end if;
    -- 経路: 紹介した会社の応募（V1 の送客登録のコメントがあれば付ける）
    insert into v2_application_events(application_id, company_id, member_id, action, note, created_at)
    values (v_app, rf.cid, rf.mid, 'applied',
            (select nullif(btrim(l.detail), '') from reflog l where l.ref_id = rf.id and l.action = '送客登録' order by l.created_at limit 1),
            coalesce(rf.created_at, now()));
    insert into v2_v1_map values ('referral', rf.id, v_app, 'migrated',
      case when rf.joined_on is not null and not v_joined then 'joined_on ' || rf.joined_on || ' is after ' || v_until || ': kept as offer (入社 scheduled)' end);
  end loop;

  -- V1 の操作履歴（reflog）→ 経路の記録（段階の事実として。送客登録は上の applied に含めた）
  insert into v2_application_events(application_id, company_id, member_id, action, note, created_at)
  select m.v2_id, case when l.by_role = 'kanoa' then null else ap.applied_by_company end,
         case when l.by_role = 'kanoa' then v_ra else ap.applied_by_member end,
         'milestone', '（V1）' || l.action || coalesce('：' || nullif(btrim(l.detail), ''), ''), l.created_at
  from reflog l join v2_v1_map m on m.kind = 'referral' and m.v1_id = l.ref_id and m.status = 'migrated'
  join v2_applications ap on ap.id = m.v2_id
  where l.action <> '送客登録';
  insert into v2_v1_map(kind, v1_id, v2_id, status, reason)
  select 'reflog', l.id, m.v2_id,
         case when m.status = 'migrated' then 'migrated' else 'skipped' end,
         case when m.status is distinct from 'migrated' then 'referral not migrated (' || l.ref_id || ')'
              when l.action = '送客登録' then 'merged into the applied event' end
  from reflog l left join v2_v1_map m on m.kind = 'referral' and m.v1_id = l.ref_id;

  -- ========== 5) 入社 → 報酬（KANOA→1次・支払待ち。V2 の v2_milestone_save と同じ式で固定） ==========
  for rf in
    select r.*, m.v2_id as app_id, ap.candidate_id, ap.job_id, ap.applied_by_company as cid
    from referrals r join v2_v1_map m on m.kind = 'referral' and m.v1_id = r.id and m.status = 'migrated'
    join v2_applications ap on ap.id = m.v2_id and ap.stage = 'closed' and ap.result = 'passed'
    order by r.created_at
  loop
    v_fee := coalesce((select fee_override from v2_job_shares where job_id = rf.job_id and company_id = rf.cid),
                      (select fee from v2_job_kanoa_fees where job_id = rf.job_id), 0);
    v_rid := v2_v1_uuid('reward', rf.id);
    insert into v2_rewards(id, application_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount, refund_policy, created_at, updated_at)
    values (v_rid, rf.app_id, rf.cid, rf.job_id, rf.candidate_id,
            (select done_on from v2_milestones where application_id = rf.app_id order by seq desc limit 1), v_fee,
            coalesce((select policy from v2_job_refund_policies where job_id = rf.job_id), '[]'), now(), now());
    perform v2_reward_make_chain(rf.app_id);
    if rf.resigned_on is not null then perform v2_reward_apply_resignation(v_rid, rf.resigned_on); end if;
    insert into v2_v1_map values ('reward', rf.id, v_rid, 'migrated',
      case when rf.pay_status is not null then 'V1 pay_status=' || rf.pay_status || ' (no pay record in V1; kept pending)' end);
  end loop;

  -- ========== 6) 紹介フォーム（intake）: 確認待ち → 求職者（選考なし）／承認済み・見送りは移さない ==========
  for it in
    select i.*, ma.v2_id as cid, mm.v2_id as mid,
           case when jsonb_typeof(i.docs) = 'string' then (i.docs #>> '{}')::jsonb
                when jsonb_typeof(i.docs) = 'array' then i.docs else '[]'::jsonb end as dl
    from intake i
    left join v2_v1_map ma on ma.kind = 'agency' and ma.v1_id = i.agency_id and ma.status = 'migrated'
    left join v2_v1_map mm on mm.kind = 'owner_member' and mm.v1_id = i.agency_id and mm.status = 'migrated'
    order by i.created_at, i.id
  loop
    if it.status = 'approved' then
      insert into v2_v1_map values ('intake', it.id, null, 'skipped',
        'decision 4: approved, already a referral (' || coalesce(it.ref_id, 'no ref_id') || ')'
        || case when not exists (select 1 from referrals r where r.id = it.ref_id) then ' - referral no longer exists in V1' else '' end);
      continue;
    elsif it.status = 'rejected' then
      insert into v2_v1_map values ('intake', it.id, null, 'skipped', 'decision 4: rejected intake');
      continue;
    elsif it.status <> 'pending' then
      insert into v2_v1_map values ('intake', it.id, null, 'failed', 'unknown intake status: ' || it.status);
      continue;
    end if;
    if it.cid is null then
      insert into v2_v1_map values ('intake', it.id, null,
        case when exists (select 1 from v2_v1_map x where x.kind = 'agency' and x.v1_id = it.agency_id and x.status = 'skipped') then 'skipped' else 'failed' end,
        'agency not migrated (' || coalesce(it.agency_id, 'null') || ')');
      continue;
    end if;
    v_txt := concat_ws(E'\n',
      '紹介元：' || nullif(btrim(coalesce(nullif(it.company, ''), it.source)), ''),
      case when nullif(btrim(it.company), '') is not null and nullif(btrim(it.source), '') is not null and btrim(it.company) <> btrim(it.source)
           then '集客元：' || btrim(it.source) end,
      '住所：' || nullif(btrim(it.address), ''),
      '希望案件（V1）：' || (select name from projects where id = it.project_id),
      'メモ：' || nullif(btrim(it.note), ''),
      'V1の紹介フォームで受付（確認待ち）：' || to_char(it.created_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD'));
    v_cand := v2_v1_uuid('intake', it.id); v_merged := false; v_refid := null;
    begin
      insert into v2_candidates(id, owner_company_id, assigned_member_id, name, kana, phone, email, prefecture, desired_location,
                                created_by, created_at, updated_at)
      values (v_cand, it.cid, it.mid, coalesce(nullif(btrim(it.name), ''), '（氏名未入力）'), nullif(btrim(it.kana), ''),
              nullif(btrim(it.phone), ''), nullif(btrim(it.email), ''), v2_v1_prefecture(it.address), nullif(btrim(it.area), ''),
              it.mid, coalesce(it.created_at, now()), coalesce(it.created_at, now()));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_con = constraint_name;
      -- 同じ会社の、電話番号が同じ移行済みの求職者（V1 の送客）がいれば、そちらにメモと添付を付ける（同じ人の二重登録はしない）
      if v_con = 'v2_candidates_phone_uq' then
        select m.v1_id into v_refid from v2_v1_map m join v2_candidates c on c.id = v2_v1_uuid('candidate', m.v1_id)
        where m.kind = 'referral' and m.status = 'migrated' and c.owner_company_id = it.cid
          and c.phone_norm = regexp_replace(coalesce(it.phone, ''), '[^0-9]', '', 'g')
        order by m.v1_id limit 1;
      end if;
      if v_refid is null then
        select string_agg(m.v1_id, ',') into v_other from v2_v1_map m
        join v2_candidates c on c.id = case when m.kind = 'referral' then v2_v1_uuid('candidate', m.v1_id) else m.v2_id end
        where m.kind in ('referral','intake') and m.status = 'migrated' and v_con = 'v2_candidates_phone_uq'
          and c.phone_norm = regexp_replace(coalesce(it.phone, ''), '[^0-9]', '', 'g');
        insert into v2_v1_map values ('intake', it.id, null, 'failed',
          'candidate blocked: ' || v_state || coalesce(' ' || nullif(v_con, ''), '')
          || case when v_other is not null then ' (same phone as V1 ' || v_other || ', other company)'
                  when v_con = 'v2_candidates_phone_uq' then ' (same phone as a V2 candidate not created by this migration)' else '' end);
        insert into v2_v1_map(kind, v1_id, v2_id, status, reason)
        select 'intake_doc', it.id || '/' || coalesce(e->>'id', e->>'path', o::text), null,
               case when exists (select 1 from documents dd where dd.storage_path = e->>'path') then 'skipped' else 'failed' end,
               case when exists (select 1 from documents dd where dd.storage_path = e->>'path')
                    then 'same file is referenced by V1 documents (migrated there)'
                    else 'intake candidate blocked (' || it.id || ')' end
        from jsonb_array_elements(it.dl) with ordinality x(e, o)
        on conflict do nothing;
        continue;
      end if;
      v_merged := true;
      v_cand := v2_v1_uuid('candidate', v_refid);
    end;
    if v_merged then
      update v2_candidate_notes set memo = memo || E'\n\n' || '― V1の紹介フォーム（確認待ち・' || it.id || '）―' || E'\n' || v_txt
      where id = v2_v1_uuid('note:company', v_refid);
      if not found then
        insert into v2_candidate_notes(id, candidate_id, company_id, memo, created_at, updated_at)
        values (v2_v1_uuid('note:company', v_refid), v_cand, it.cid, '― V1の紹介フォーム（確認待ち・' || it.id || '）―' || E'\n' || v_txt,
                it.created_at, it.created_at);
      end if;
      insert into v2_v1_map values ('intake', it.id, v_cand, 'migrated',
        'merged into the candidate of V1 ' || v_refid || ' (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq)');
    else
      -- 選考が無い求職者は持ち主の会社にしか見えない（V2 の権限）ので、メモも持ち主の会社の分だけ
      insert into v2_candidate_notes(id, candidate_id, company_id, memo, created_at, updated_at)
      values (v2_v1_uuid('note:intake', it.id), v_cand, it.cid, '― V1から引継ぎ ―' || E'\n' || v_txt, it.created_at, it.created_at);
      insert into v2_v1_map values ('intake', it.id, v_cand, 'migrated', 'decision 4: pending intake -> candidate without application');
    end if;
    -- 紹介フォームの添付（intake.docs）。documents にも載っている同じファイルは documents 側で移す
    for d in select e, o from jsonb_array_elements(it.dl) with ordinality x(e, o) loop
      v_txt := it.id || '/' || coalesce(d.e->>'id', d.e->>'path', d.o::text);
      if exists (select 1 from documents dd where dd.storage_path = d.e->>'path') then
        insert into v2_v1_map values ('intake_doc', v_txt, null, 'skipped', 'same file is referenced by V1 documents (migrated there)') on conflict do nothing;
        continue;
      end if;
      if not exists (select 1 from storage.objects o where o.bucket_id = 'candidate-docs' and o.name = d.e->>'path') then
        insert into v2_v1_map values ('intake_doc', v_txt, null, 'failed', 'file not found in candidate-docs') on conflict do nothing;
        continue;
      end if;
      v_fid := v2_v1_uuid('intake_doc', v_txt);
      v_ext := coalesce('.' || lower(substring(d.e->>'path' from '\.([A-Za-z0-9]{1,8})$')), '');
      v_dst := 'candidates/' || v_cand || '/' || v_fid || v_ext;
      insert into v2_candidate_files(id, candidate_id, kind, name, size, mime, storage_path, uploaded_by, created_at, updated_at)
      select v_fid, v_cand, v2_v1_file_kind(d.e->>'kind'), coalesce(nullif(d.e->>'name', ''), 'file' || v_ext),
             coalesce((o.metadata->>'size')::bigint, (d.e->>'size')::bigint), coalesce(o.metadata->>'mimetype', d.e->>'type'),
             v_dst, it.mid, coalesce(it.created_at, now()), coalesce(it.created_at, now())
      from storage.objects o where o.bucket_id = 'candidate-docs' and o.name = d.e->>'path';
      insert into v2_v1_map values ('intake_doc', v_txt, v_fid, 'migrated', null,
        (select jsonb_build_object('src', o.name, 'dst', v_dst, 'size', (o.metadata->>'size')::bigint, 'mime', o.metadata->>'mimetype')
           from storage.objects o where o.bucket_id = 'candidate-docs' and o.name = d.e->>'path'))
      on conflict do nothing;
    end loop;
  end loop;

  -- ========== 7) 書類（documents → v2_candidate_files。ファイルの実体は run_migration.sh がコピー） ==========
  insert into v2_candidate_files(id, candidate_id, kind, name, size, mime, storage_path, uploaded_by, created_at, updated_at)
  select v2_v1_uuid('document', dc.id), v2_v1_uuid('candidate', dc.referral_id), v2_v1_file_kind(dc.kind),
         coalesce(nullif(btrim(dc.name), ''), 'file'), coalesce(dc.size, (o.metadata->>'size')::bigint), coalesce(dc.mime, o.metadata->>'mimetype'),
         'candidates/' || v2_v1_uuid('candidate', dc.referral_id) || '/' || v2_v1_uuid('document', dc.id)
           || coalesce('.' || lower(substring(dc.storage_path from '\.([A-Za-z0-9]{1,8})$')), ''),
         case when dc.uploaded_by = 'kanoa' then v_ra else (select v2_id from v2_v1_map where kind = 'owner_member' and v1_id = dc.uploaded_by and status = 'migrated') end,
         coalesce(dc.created_at, now()), coalesce(dc.created_at, now())
  from documents dc
  join v2_v1_map m on m.kind = 'referral' and m.v1_id = dc.referral_id and m.status = 'migrated'
  join storage.objects o on o.bucket_id = 'candidate-docs' and o.name = dc.storage_path;
  insert into v2_v1_map
  select 'document', dc.id,
         case when f.id is not null then f.id end,
         case when f.id is not null then 'migrated' when m.status = 'skipped' then 'skipped' else 'failed' end,
         case when f.id is not null then null
              when m.status is distinct from 'migrated' then 'referral not migrated (' || coalesce(dc.referral_id, 'null') || ')'
              else 'file not found in candidate-docs' end,
         case when f.id is not null then jsonb_build_object('src', dc.storage_path, 'dst', f.storage_path, 'size', f.size, 'mime', f.mime) end,
         now()
  from documents dc
  left join v2_v1_map m on m.kind = 'referral' and m.v1_id = dc.referral_id
  left join v2_candidate_files f on f.id = v2_v1_uuid('document', dc.id);

  -- ========== 8) 連絡（messages → 選考のチャット。KANOA⇔1次のスレッド） ==========
  insert into v2_messages(id, application_id, thread_company_id, sender_member_id, side, body, stamp, reply_to, reactions,
                          pinned, edited, deleted, created_at, updated_at)
  select v2_v1_uuid('message', ms.id), m.v2_id, ap.applied_by_company,
         case when ms.sender = 'kanoa' then v_ra else ap.applied_by_member end,
         case when ms.sender = 'kanoa' then 'up' else 'self' end,
         case when coalesce(ms.deleted, false) then null
              when ms.stamp is not null and btrim(ms.body) in ('👍','🙏','🎉','💪','😄','🙇','✨','⭕','❌','⏰') then null
              else ms.body end,
         case when coalesce(ms.deleted, false) then null
              when ms.stamp is not null and btrim(ms.body) in ('👍','🙏','🎉','💪','😄','🙇','✨','⭕','❌','⏰') then btrim(ms.body) end,
         null,
         case when coalesce(ms.deleted, false) or jsonb_typeof(ms.reactions) <> 'object' then '[]'::jsonb
              else coalesce((select jsonb_agg(jsonb_build_object('emoji', em, 'member_id', mid) order by em, ord)
                             from (select distinct on (em, mid) em, mid, ord from (
                               select case when e.key in ('👍','✅','🙏','😄','🎉') then e.key else '✅' end as em, x.mid, w.ord
                               from jsonb_each(ms.reactions) e
                               cross join lateral jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value else '[]' end) with ordinality w(who, ord)
                               cross join lateral (select case when w.who = 'kanoa' then v_ra
                                                               else (select v2_id from v2_v1_map where kind = 'owner_member' and v1_id = w.who and status = 'migrated') end as mid) x
                              where x.mid is not null) z0 order by em, mid, ord) z), '[]'::jsonb) end,
         coalesce(ms.pinned, false) and not coalesce(ms.deleted, false), coalesce(ms.edited, false), coalesce(ms.deleted, false),
         coalesce(ms.created_at, now()), coalesce(ms.created_at, now())
  from messages ms
  join v2_v1_map m on m.kind = 'referral' and m.v1_id = ms.ref_id and m.status = 'migrated'
  join v2_applications ap on ap.id = m.v2_id
  where ms.ref_id is not null and (ms.sender = 'kanoa' or ap.applied_by_member is not null);
  -- 返信先（同じスレッドに移せたものだけ）
  update v2_messages v set reply_to = v2_v1_uuid('message', ms.reply_to)
  from messages ms
  where v.id = v2_v1_uuid('message', ms.id) and ms.reply_to is not null
    and exists (select 1 from v2_messages t where t.id = v2_v1_uuid('message', ms.reply_to)
                and t.application_id = v.application_id and t.thread_company_id = v.thread_company_id);
  insert into v2_v1_map(kind, v1_id, v2_id, status, reason)
  select 'message', ms.id, v.id,
         case when v.id is not null then 'migrated' when ms.ref_id is null then 'skipped'
              when exists (select 1 from v2_v1_map m where m.kind = 'referral' and m.v1_id = ms.ref_id and m.status = 'skipped') then 'skipped' else 'failed' end,
         case when v.id is not null then null
              when ms.ref_id is null then 'decision 3: company-level message exported to migration/exports/v1_company_messages.csv'
              when not exists (select 1 from v2_v1_map m where m.kind = 'referral' and m.v1_id = ms.ref_id and m.status = 'migrated')
                then 'referral not migrated (' || ms.ref_id || ')'
              else 'no owner member to send as' end
  from messages ms left join v2_messages v on v.id = v2_v1_uuid('message', ms.id);

  -- 既読: V1 の read をそのまま再現（V1 で既読のものは既読。未読のものだけ未読のまま）
  -- KANOA（RA）と代表CA の両方に、スレッドごとの「最後に読んだ時刻」を入れる＝移行でバッジが溢れない
  insert into v2_thread_reads(application_id, thread_company_id, member_id, last_read_at)
  select t.application_id, t.thread_company_id, w.member_id,
         coalesce(min(v.created_at) filter (where v.side <> w.side and not coalesce(ms.read, false) and not v.deleted) - interval '1 millisecond',
                  max(v.created_at))
  from (select distinct application_id, thread_company_id from v2_messages
        where id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')) t
  join v2_applications ap on ap.id = t.application_id
  cross join lateral (select r.id, 'up' from unnest(v_ras) r(id) union all select ap.applied_by_member, 'self') w(member_id, side)
  join v2_messages v on v.application_id = t.application_id and v.thread_company_id = t.thread_company_id
  join messages ms on v2_v1_uuid('message', ms.id) = v.id
  where w.member_id is not null
  group by t.application_id, t.thread_company_id, w.member_id
  on conflict (application_id, thread_company_id, member_id) do update set last_read_at = excluded.last_read_at;

  -- ========== 9) お知らせ ==========
  insert into v2_notices(id, title, body, audience, target_company_ids, pinned, status, published_at, author_id, created_at, updated_at)
  select v2_v1_uuid('notice', n.id), coalesce(nullif(btrim(n.title), ''), '（無題）'), coalesce(n.body, ''),
         case when coalesce(n.audience, 'all') = 'all' then 'all' else 'selected' end,
         case when coalesce(n.audience, 'all') = 'all' then '{}'::uuid[]
              else coalesce((select array_agg(m.v2_id) from jsonb_array_elements_text(case when jsonb_typeof(n.agency_ids) = 'array' then n.agency_ids else '[]' end) x(ag)
                             join v2_v1_map m on m.kind = 'agency' and m.v1_id = x.ag and m.status = 'migrated'), '{}') end,
         coalesce(n.pinned, false),
         case when n.status = 'published' then 'published' else 'draft' end,
         case when n.status = 'published' then coalesce(n.created_at, now()) end,
         v_ra, coalesce(n.created_at, now()),
         coalesce(case when n.updated_on ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$' then (n.updated_on || ':00+09')::timestamptz end, n.created_at, now())
  from notices n;
  insert into v2_v1_map(kind, v1_id, v2_id, status) select 'notice', n.id, v2_v1_uuid('notice', n.id), 'migrated' from notices n;
  -- V1 の時点で出ていたお知らせは、移行した会社の代表CAとすべての RA には既読にしておく（未読バッジが溢れないように）
  insert into v2_notice_reads(notice_id, member_id, read_at)
  select v2_v1_uuid('notice', n.id), w.mid, coalesce(n.created_at, now())
  from notices n
  cross join (select v2_id from v2_v1_map where kind = 'owner_member' and status = 'migrated' union select unnest(v_ras)) w(mid)
  where n.status = 'published'
  on conflict do nothing;

  -- ========== 10) 移さないもの（設計どおり） ==========
  insert into v2_v1_map(kind, v1_id, status, reason) select 'task', id, 'skipped', 'not migrated by design (V1 tasks)' from tasks;
  insert into v2_v1_map(kind, v1_id, status, reason) select 'tracker_link', token, 'skipped', 'not migrated by design (07-23: tracker_links not rebuilt)' from tracker_links;

  perform v2_v1_triggers(true);

  select jsonb_object_agg(kind, s) into v_summary from (
    select kind, jsonb_object_agg(status, n) s from (select kind, status, count(*) n from v2_v1_map group by 1, 2) x group by kind) y;
  v_summary := jsonb_build_object('purged', v_purged, 'map', v_summary, 'joined_until', v_until, 'members_active', p_activate_members,
                                  'discard_preview_edits', p_discard_preview_edits);
  insert into v2_v1_runs(params, summary) values (jsonb_build_object('joined_until', v_until, 'activate_members', p_activate_members,
                                                   'force_after_cutover', p_force_after_cutover,
                                                   'discard_preview_edits', p_discard_preview_edits), v_summary);
  return v_summary;
end $function$;

CREATE OR REPLACE FUNCTION public.v2_v1_reconcile()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_until date := coalesce((select (params->>'joined_until')::date from v2_v1_runs order by id desc limit 1),
                           (now() at time zone 'Asia/Tokyo')::date);
  v1 jsonb; v2 jsonb; acct jsonb; checks jsonb := '[]'; xt jsonb; fails jsonb; pa jsonb;
begin
  v1 := jsonb_build_object(
    'agencies', (select count(*) from agencies),
    'projects', (select count(*) from projects),
    'assignments', (select count(*) from assignments),
    'assignments_published', (select count(*) from assignments where published and agency_id not in (select id from agencies where code in ('KA999','RE999','PT000'))),
    -- 移す対象（移さない会社 KA999・RE999・PT000 の分を除く。会社コードで数え、移行の記録は通さない）
    'referrals', (select count(*) from referrals where agency_id not in (select id from agencies where code in ('KA999','RE999','PT000'))),
    'excluded_referrals', (select count(*) from referrals where agency_id in (select id from agencies where code in ('KA999','RE999','PT000'))),
    'referrals_by_status', (select jsonb_object_agg(coalesce(status, 'null'), n) from (select status, count(*) n from referrals where agency_id not in (select id from agencies where code in ('KA999','RE999','PT000')) group by 1) x),
    'intake_by_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from intake where agency_id not in (select id from agencies where code in ('KA999','RE999','PT000')) group by 1) x),
    'documents', (select count(*) from documents d where not exists (select 1 from referrals r where r.id = d.referral_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000')))),
    'documents_bytes', (select coalesce(sum(size), 0) from documents d where not exists (select 1 from referrals r where r.id = d.referral_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000')))),
    'excluded_documents', (select count(*) from documents d where exists (select 1 from referrals r where r.id = d.referral_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000')))),
    'messages', (select count(*) from messages),
    'messages_with_ref', (select count(*) from messages m where ref_id is not null and not exists (select 1 from referrals r where r.id = m.ref_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000')))),
    'excluded_messages_with_ref', (select count(*) from messages m where ref_id is not null and exists (select 1 from referrals r where r.id = m.ref_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000')))),
    'messages_company_level', (select count(*) from messages where ref_id is null),
    'messages_by_sender', (select jsonb_object_agg(coalesce(sender, 'null'), n) from (select sender, count(*) n from messages m where ref_id is not null and not exists (select 1 from referrals r where r.id = m.ref_id and r.agency_id in (select id from agencies where code in ('KA999','RE999','PT000'))) group by 1) x),
    -- 確認待ちの紹介フォームのうち、同じ会社に電話番号が同じ送客があるもの（V1 の表だけで数える）
    'intake_pending_same_phone_same_agency', (select count(*) from intake i where i.status = 'pending' and coalesce(i.phone, '') <> '' and i.agency_id not in (select id from agencies where code in ('KA999','RE999','PT000'))
        and exists (select 1 from referrals r where r.agency_id = i.agency_id
                    and regexp_replace(coalesce(r.phone, ''), '[^0-9]', '', 'g') = regexp_replace(i.phone, '[^0-9]', '', 'g'))),
    'agencies_migratable', (select count(*) from agencies where code not in ('KA999','RE999','PT000')),
    'agencies_migratable_with_auth', (select count(*) from agencies where code not in ('KA999','RE999','PT000') and auth_user_id is not null),
    'notices', (select count(*) from notices),
    'tasks', (select count(*) from tasks),
    'tracker_links', (select count(*) from tracker_links),
    'reflog', (select count(*) from reflog),
    'candidate_docs_objects', (select count(*) from storage.objects where bucket_id = 'candidate-docs'),
    'candidate_docs_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'candidate-docs'),
    'candidate_docs_unreferenced', (select count(*) from storage.objects o where bucket_id = 'candidate-docs'
                                     and not exists (select 1 from documents d where d.storage_path = o.name)),
    'sum_success_reward', (select coalesce(sum(success_reward), 0) from projects),
    'sum_referral_reward', (select coalesce(sum(referral_reward), 0) from projects),
    'sum_client_fee', (select coalesce(sum(client_fee), 0) from projects),
    'sum_suc_override', (select coalesce(sum(suc_override), 0) from assignments),
    'ref_override_set', (select count(*) from assignments where ref_override is not null),
    'joined_rule', jsonb_build_object('joined_until', v_until,
      'count', (select count(*) from referrals where status in ('joined','resigned') or (joined_on is not null and joined_on <= v_until)),
      'fee_total', (select coalesce(sum(coalesce(s.suc_override, p.success_reward, 0)), 0) from referrals r
                    join projects p on p.id = r.project_id left join assignments s on s.project_id = r.project_id and s.agency_id = r.agency_id
                    where r.status in ('joined','resigned') or (r.joined_on is not null and r.joined_on <= v_until)),
      'joined_on_set_total', (select count(*) from referrals where joined_on is not null)),
    'auth_users_partner', (select count(*) from auth.users where email like '%@partner.kanoa.local'));

  v2 := jsonb_build_object(
    'companies', (select count(*) from v2_companies where id in (select v2_id from v2_v1_map where kind = 'agency' and status = 'migrated')),
    'owner_members', (select jsonb_object_agg(status, n) from (select status, count(*) n from v2_members
                        where id in (select v2_id from v2_v1_map where kind = 'owner_member' and status = 'migrated') group by 1) x),
    'clients', (select count(*) from v2_clients where id in (select v2_id from v2_v1_map where kind = 'client')),
    'jobs', (select count(*) from v2_jobs where id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')),
    'sum_job_kanoa_fee', (select coalesce(sum(fee), 0) from v2_job_kanoa_fees where job_id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')),
    'sum_client_fee', (select coalesce(sum(fee), 0) from v2_job_client_fees where job_id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')),
    'jobs_with_refund_policy', (select count(*) from v2_job_refund_policies where job_id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')),
    'shares', (select count(*) from v2_job_shares where id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'shares_published', (select count(*) from v2_job_shares where published and id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'sum_fee_override', (select coalesce(sum(fee_override), 0) from v2_job_shares where id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'candidates_from_referrals', (select count(*) from v2_candidates where id in (select v2_v1_uuid('candidate', v1_id) from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'candidates_from_intake', (select count(*) from v2_candidates where id in (select v2_id from v2_v1_map where kind = 'intake' and status = 'migrated'
                                                                                and coalesce(reason, '') not like 'merged%')),
    'intake_merged', (select count(*) from v2_v1_map where kind = 'intake' and status = 'migrated' and reason like 'merged%'),
    -- 会社コード経由（移行の記録を通さない）: 移行した会社の代表CA
    'owner_members_by_code', (select count(*) from v2_members m join v2_companies co on co.id = m.company_id
                               join v2_v1_company_codes cc on cc.code = co.code where m.is_owner),
    'applications', (select count(*) from v2_applications where id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'applications_by_stage', (select jsonb_object_agg(k, n) from (select stage || coalesce('/' || result, '') k, count(*) n from v2_applications
                                where id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated') group by 1) x),
    'milestones', (select count(*) from v2_milestones where application_id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'events', (select count(*) from v2_application_events where application_id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'candidate_notes', (select jsonb_build_object('kanoa', count(*) filter (where company_id is null), 'company', count(*) filter (where company_id is not null))
                         from v2_candidate_notes where candidate_id in (select v2_v1_uuid('candidate', v1_id) from v2_v1_map where kind = 'referral' and status = 'migrated')
                            or candidate_id in (select v2_id from v2_v1_map where kind = 'intake' and status = 'migrated')),
    'files', (select count(*) from v2_candidate_files where id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated')),
    'files_bytes', (select coalesce(sum(size), 0) from v2_candidate_files where id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated')),
    'files_from_documents', (select count(*) from v2_v1_map where kind = 'document' and status = 'migrated'),
    'files_from_documents_bytes', (select coalesce(sum(f.size), 0) from v2_candidate_files f where f.id in (select v2_id from v2_v1_map where kind = 'document' and status = 'migrated')),
    'files_in_storage', (select count(*) from storage.objects o join v2_candidate_files f on f.storage_path = o.name
                          where o.bucket_id = 'v2-files' and f.id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated')),
    'files_in_storage_bytes', (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o join v2_candidate_files f on f.storage_path = o.name
                          where o.bucket_id = 'v2-files' and f.id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated')),
    'files_size_mismatch', (select count(*) from storage.objects o join v2_candidate_files f on f.storage_path = o.name
                          where o.bucket_id = 'v2-files' and f.id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated')
                            and (o.metadata->>'size')::bigint is distinct from f.size),
    'messages', (select count(*) from v2_messages where id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'messages_by_side', (select jsonb_object_agg(side, n) from (select side, count(*) n from v2_messages
                           where id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated') group by 1) x),
    'messages_with_reactions', (select count(*) from v2_messages where reactions <> '[]' and id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'messages_replies', (select count(*) from v2_messages where reply_to is not null and id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'messages_edited', (select count(*) from v2_messages where edited and id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'thread_reads', (select count(*) from v2_thread_reads where application_id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'unread_for_kanoa', (select count(*) from v2_messages m join v2_thread_reads r on r.application_id = m.application_id and r.thread_company_id = m.thread_company_id
                           join v2_members mb on mb.id = r.member_id and mb.role = 'ra'
                          where m.side = 'self' and not m.deleted and m.created_at > r.last_read_at
                            and m.id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'unread_for_partners', (select count(*) from v2_messages m join v2_thread_reads r on r.application_id = m.application_id and r.thread_company_id = m.thread_company_id
                           join v2_members mb on mb.id = r.member_id and mb.role = 'ca'
                          where m.side = 'up' and not m.deleted and m.created_at > r.last_read_at
                            and m.id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated')),
    'notices', (select count(*) from v2_notices where id in (select v2_id from v2_v1_map where kind = 'notice' and status = 'migrated')),
    'rewards', (select count(*) from v2_rewards where id in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated')),
    'rewards_fee_total', (select coalesce(sum(fee_amount), 0) from v2_rewards where id in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated')),
    'rewards_all_for_migrated_apps', (select count(*) from v2_rewards where application_id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'rewards_pending', (select count(*) from v2_rewards where pay_status = 'pending' and id in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated')),
    -- 紹介料・返金の語の検査（全パートナーに読める求人の項目。0 でなければならない）
    'job_text_fee_word_hits', (select count(*) from v2_jobs j where j.id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')
        and (coalesce(j.title, '') || ' ' || coalesce(j.description, '') || ' ' || coalesce(j.conditions, '') || ' ' || coalesce(j.detail::text, ''))
            ~* '紹介料|返金|手数料|受領|貴社報酬|弊社報酬|成約報酬|送客報酬|報酬率|reward|refund|client_fee'));

  -- V1 の行 → migrated / skipped / failed（全行を数え切る）
  select jsonb_object_agg(k, jsonb_build_object('v1', v1n, 'migrated', coalesce(mig, 0), 'skipped', coalesce(sk, 0), 'failed', coalesce(fl, 0),
                                               'unaccounted', v1n - coalesce(mig, 0) - coalesce(sk, 0) - coalesce(fl, 0)))
    into acct
  from (values ('agency', (select count(*) from agencies)), ('project', (select count(*) from projects)),
               ('assignment', (select count(*) from assignments)), ('referral', (select count(*) from referrals)),
               ('intake', (select count(*) from intake)), ('document', (select count(*) from documents)),
               ('message', (select count(*) from messages)), ('notice', (select count(*) from notices)),
               ('reflog', (select count(*) from reflog)), ('task', (select count(*) from tasks)),
               ('tracker_link', (select count(*) from tracker_links))) t(k, v1n)
  left join lateral (select count(*) filter (where status = 'migrated') mig, count(*) filter (where status = 'skipped') sk,
                            count(*) filter (where status = 'failed') fl from v2_v1_map m where m.kind = t.k) c on true;

  -- V1 の状態 → V2 の状態（件数の対応表）
  select jsonb_agg(jsonb_build_object('v1_status', st, 'v1_fail_at', fa, 'v1_joined', jn, 'v2', v2s, 'n', n) order by st, fa, v2s) into xt
  from (select r.status st, r.fail_at fa, (r.joined_on is not null) jn,
               coalesce(a.stage || coalesce('/' || a.result, ''), 'NOT MIGRATED') v2s, count(*) n
        from referrals r left join v2_v1_map m on m.kind = 'referral' and m.v1_id = r.id and m.status = 'migrated'
        left join v2_applications a on a.id = m.v2_id group by 1, 2, 3, 4) x;

  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'v1_id', v1_id, 'status', status, 'reason', reason) order by kind, v1_id), '[]') into fails
  from v2_v1_map where status = 'failed' or (status = 'skipped' and kind not in ('task','tracker_link','message','intake','reflog'))
     or (kind = 'intake' and status = 'skipped' and reason like '%no longer exists%') or (kind = 'referral' and reason is not null)
     or (kind = 'intake' and reason like 'merged%');

  -- 会社ごと（会社コード経由。移行の記録を通さない）: V1 の送客 ↔ V2 の選考、V1 の送客＋確認待ちの紹介フォーム（重複を除く）↔ V2 の求職者
  select jsonb_agg(jsonb_build_object('code', cc.code, 'v1_referrals', r.n, 'v2_applications', ap.n,
                                      'v1_expected_candidates', r.n + ik.n, 'v2_candidates', ca.n) order by cc.code) into pa
  from v2_v1_company_codes cc join agencies a on a.id = cc.agency_id and a.id not in (select id from agencies where code in ('KA999','RE999','PT000'))
  left join v2_companies co on co.code = cc.code
  cross join lateral (select count(*) n from referrals where agency_id = a.id) r
  cross join lateral (select count(*) n from intake i where i.agency_id = a.id and i.status = 'pending'
                        and not exists (select 1 from referrals x where x.agency_id = i.agency_id and coalesce(i.phone, '') <> ''
                                        and regexp_replace(coalesce(x.phone, ''), '[^0-9]', '', 'g') = regexp_replace(i.phone, '[^0-9]', '', 'g'))) ik
  cross join lateral (select count(*) n from v2_applications where applied_by_company = co.id) ap
  cross join lateral (select count(*) n from v2_candidates where owner_company_id = co.id) ca;

  return jsonb_build_object('generated_at', now(), 'v1', v1, 'v2', v2, 'accounting', acct, 'status_crosstab', xt, 'exceptions', fails,
                            'per_agency', pa);
end $function$;

CREATE OR REPLACE FUNCTION public.v2_v1_purge_blockers()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_prev timestamptz := (select max(started_at) from v2_v1_runs); h jsonb := '{}'; d jsonb := '{}'; n bigint;
begin
  if not exists (select 1 from v2_v1_map) then return jsonb_build_object('hard', h, 'discardable', d); end if;
  drop table if exists _m_app, _m_cand, _m_comp, _m_owner, _m_job, _m_notice, _m_ok_member;
  create temp table _m_app    on commit drop as select v2_id id from v2_v1_map where kind = 'referral' and status = 'migrated';
  create temp table _m_cand   on commit drop as
    select v2_v1_uuid('candidate', v1_id) id from v2_v1_map where kind = 'referral' and status = 'migrated'
    union select v2_id from v2_v1_map where kind = 'intake' and status = 'migrated' and v2_id is not null;
  create temp table _m_comp   on commit drop as select v2_id id from v2_v1_map where kind = 'agency' and status = 'migrated';
  create temp table _m_owner  on commit drop as select v2_id id from v2_v1_map where kind = 'owner_member' and status = 'migrated';
  create temp table _m_job    on commit drop as select v2_id id from v2_v1_map where kind = 'project' and status = 'migrated';
  create temp table _m_notice on commit drop as select v2_id id from v2_v1_map where kind = 'notice' and status = 'migrated';
  create temp table _m_ok_member on commit drop as select id from _m_owner union select id from v2_members where role = 'ra';

  -- ===== discardable: 移した行の下に、お試し中にできた行 =====
  select count(*) into n from v2_messages where application_id in (select id from _m_app)
    and id not in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated');
  if n > 0 then d := d || jsonb_build_object('messages_sent_in_v2', n); end if;
  select count(*) into n from v2_message_files where application_id in (select id from _m_app);
  if n > 0 then d := d || jsonb_build_object('message_files_on_migrated_applications', n); end if;
  select count(*) into n from v2_candidate_files where candidate_id in (select id from _m_cand)
    and id not in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated');
  if n > 0 then d := d || jsonb_build_object('candidate_files_uploaded_in_v2', n); end if;
  select count(*) into n from v2_candidate_notes where candidate_id in (select id from _m_cand) and (version > 1 or created_at >= v_prev);
  if n > 0 then d := d || jsonb_build_object('candidate_notes_added_or_edited', n); end if;
  select count(*) into n from v2_milestones where application_id in (select id from _m_app) and (version > 1 or created_at >= v_prev);
  if n > 0 then d := d || jsonb_build_object('milestones_added_or_edited', n); end if;
  select count(*) into n from v2_application_events where application_id in (select id from _m_app) and created_at >= v_prev;
  if n > 0 then d := d || jsonb_build_object('application_events_added', n); end if;
  select count(*) into n from v2_rewards where application_id in (select id from _m_app)
    and id not in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated');
  if n > 0 then d := d || jsonb_build_object('rewards_created_on_migrated_applications', n); end if;
  select count(*) into n from v2_rewards w
  where w.id in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated')
    and (w.version > 1 or w.pay_status = 'paid' or w.paid_on is not null or w.paid_amount is not null
         or w.refund_status is not null or w.refunded_on is not null
         or w.resigned_on is distinct from (select r2.resigned_on from v2_v1_map m join referrals r2 on r2.id = m.v1_id
                                            where m.kind = 'reward' and m.v2_id = w.id));
  if n > 0 then d := d || jsonb_build_object('rewards_with_pay_resign_or_refund_records', n); end if;
  select count(*) into n from v2_job_kanoa_fees where job_id in (select id from _m_job) and (version > 1 or created_at >= v_prev);
  if n > 0 then d := d || jsonb_build_object('job_kanoa_fees_created_or_edited', n); end if;
  select count(*) into n from v2_job_client_fees where job_id in (select id from _m_job) and (version > 1 or created_at >= v_prev);
  if n > 0 then d := d || jsonb_build_object('job_client_fees_created_or_edited', n); end if;
  select count(*) into n from v2_job_refund_policies where job_id in (select id from _m_job) and (version > 1 or created_at >= v_prev);
  if n > 0 then d := d || jsonb_build_object('job_refund_policies_created_or_edited', n); end if;

  -- ===== discardable: 移した行そのものの変更（version > 1） =====
  select count(*) into n from v2_applications where id in (select id from _m_app) and version > 1;
  if n > 0 then d := d || jsonb_build_object('applications_edited', n); end if;
  select count(*) into n from v2_candidates where id in (select id from _m_cand) and version > 1;
  if n > 0 then d := d || jsonb_build_object('candidates_edited', n); end if;
  select count(*) into n from v2_messages where id in (select v2_id from v2_v1_map where kind = 'message' and status = 'migrated') and version > 1;
  if n > 0 then d := d || jsonb_build_object('messages_edited', n); end if;
  select count(*) into n from v2_candidate_files where id in (select v2_id from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated') and version > 1;
  if n > 0 then d := d || jsonb_build_object('candidate_files_edited', n); end if;
  select count(*) into n from v2_jobs where id in (select id from _m_job) and version > 1;
  if n > 0 then d := d || jsonb_build_object('jobs_edited', n); end if;
  select count(*) into n from v2_job_shares where id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated') and version > 1;
  if n > 0 then d := d || jsonb_build_object('job_shares_edited', n); end if;
  select count(*) into n from v2_companies where id in (select id from _m_comp) and version > 1;
  if n > 0 then d := d || jsonb_build_object('companies_edited', n); end if;
  select count(*) into n from v2_members where id in (select id from _m_owner) and version > 1;
  if n > 0 then d := d || jsonb_build_object('members_edited', n); end if;
  select count(*) into n from v2_notices where id in (select id from _m_notice) and version > 1;
  if n > 0 then d := d || jsonb_build_object('notices_edited', n); end if;
  select count(*) into n from v2_clients where id in (select v2_id from v2_v1_map where kind = 'client' and status = 'migrated') and version > 1;
  if n > 0 then d := d || jsonb_build_object('clients_edited', n); end if;

  -- ===== discardable: 移した行が V2 で消された =====
  select count(*) into n from v2_v1_map m where m.status = 'migrated' and m.v2_id is not null and not exists (
    select 1 where (m.kind = 'agency' and exists (select 1 from v2_companies x where x.id = m.v2_id))
       or (m.kind = 'owner_member' and exists (select 1 from v2_members x where x.id = m.v2_id))
       or (m.kind = 'client' and exists (select 1 from v2_clients x where x.id = m.v2_id))
       or (m.kind = 'project' and exists (select 1 from v2_jobs x where x.id = m.v2_id))
       or (m.kind = 'assignment' and exists (select 1 from v2_job_shares x where x.id = m.v2_id))
       or (m.kind = 'referral' and exists (select 1 from v2_applications x where x.id = m.v2_id)
                               and exists (select 1 from v2_candidates c where c.id = v2_v1_uuid('candidate', m.v1_id)))
       or (m.kind = 'intake' and exists (select 1 from v2_candidates x where x.id = m.v2_id))
       or (m.kind in ('document','intake_doc') and exists (select 1 from v2_candidate_files x where x.id = m.v2_id))
       or (m.kind = 'message' and exists (select 1 from v2_messages x where x.id = m.v2_id))
       or (m.kind = 'notice' and exists (select 1 from v2_notices x where x.id = m.v2_id))
       or (m.kind = 'reward' and exists (select 1 from v2_rewards x where x.id = m.v2_id))
       or m.kind = 'reflog')   -- 経路の記録は選考ごと（選考の有無で上の referral が見る）
  ;
  if n > 0 then d := d || jsonb_build_object('migrated_rows_deleted_in_v2', n); end if;
  select count(*) into n from v2_job_kanoa_fees f right join _m_job j on j.id = f.job_id where f.job_id is null;
  if n > 0 then d := d || jsonb_build_object('job_kanoa_fees_deleted_in_v2', n); end if;
  -- （求人企業からの紹介料の「削除」は見ない: 137 で表を足した直後は前回の移行分が無く、誤って止まるため。編集・追加は上で見る）

  -- ===== hard: 移していない行に及ぶ（--discard-preview-edits でも止める） =====
  select count(*) into n from v2_message_files where thread_company_id in (select id from _m_comp) and application_id not in (select id from _m_app);
  if n > 0 then h := h || jsonb_build_object('message_files_on_other_applications', n); end if;
  select count(*) into n from v2_messages where thread_company_id in (select id from _m_comp) and application_id not in (select id from _m_app);
  if n > 0 then h := h || jsonb_build_object('messages_on_other_applications', n); end if;
  select count(*) into n from v2_candidate_notes where company_id in (select id from _m_comp) and candidate_id not in (select id from _m_cand);
  if n > 0 then h := h || jsonb_build_object('notes_by_migrated_companies_on_other_candidates', n); end if;
  select count(*) into n from v2_applications where id not in (select id from _m_app) and (candidate_id in (select id from _m_cand)
    or job_id in (select id from _m_job) or applied_by_company in (select id from _m_comp) or holder_company_id in (select id from _m_comp));
  if n > 0 then h := h || jsonb_build_object('applications_created_in_v2', n); end if;
  select count(*) into n from v2_application_parties where company_id in (select id from _m_comp) and application_id not in (select id from _m_app);
  if n > 0 then h := h || jsonb_build_object('application_parties_on_other_applications', n); end if;
  select count(*) into n from v2_candidates where owner_company_id in (select id from _m_comp) and id not in (select id from _m_cand);
  if n > 0 then h := h || jsonb_build_object('candidates_created_in_v2', n); end if;
  select count(*) into n from v2_job_offers where job_id in (select id from _m_job) or company_id in (select id from _m_comp);
  if n > 0 then h := h || jsonb_build_object('job_offers', n); end if;
  select count(*) into n from v2_job_shares where (job_id in (select id from _m_job) or company_id in (select id from _m_comp))
    and id not in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated');
  if n > 0 then h := h || jsonb_build_object('job_shares_to_other_companies', n); end if;
  select count(*) into n from v2_notice_reads where (notice_id in (select id from _m_notice) and member_id not in (select id from _m_ok_member))
    or (member_id in (select id from _m_owner) and notice_id not in (select id from _m_notice));
  if n > 0 then h := h || jsonb_build_object('notice_reads_of_other_members', n); end if;
  select count(*) into n from v2_thread_reads where (application_id in (select id from _m_app) and member_id not in (select id from _m_ok_member))
    or (member_id in (select id from _m_owner) and application_id not in (select id from _m_app))
    or (thread_company_id in (select id from _m_comp) and application_id not in (select id from _m_app));
  if n > 0 then h := h || jsonb_build_object('thread_reads_of_other_members', n); end if;
  select count(*) into n from v2_rewards where application_id not in (select id from _m_app)
    and (candidate_id in (select id from _m_cand) or job_id in (select id from _m_job)
         or payee_company_id in (select id from _m_comp) or payer_company_id in (select id from _m_comp));
  if n > 0 then h := h || jsonb_build_object('rewards_on_other_applications', n); end if;
  select count(*) into n from v2_members where company_id in (select id from _m_comp) and id not in (select id from _m_owner);
  if n > 0 then h := h || jsonb_build_object('members_added_in_v2', n); end if;
  select count(*) into n from v2_companies where parent_id in (select id from _m_comp);
  if n > 0 then h := h || jsonb_build_object('front_companies_in_v2', n); end if;
  select count(*) into n from v2_invites where issued_by in (select id from _m_comp) or accepted_company_id in (select id from _m_comp)
    or issued_member in (select id from _m_owner);
  if n > 0 then h := h || jsonb_build_object('invites', n); end if;
  select count(*) into n from v2_jobs where client_id in (select v2_id from v2_v1_map where kind = 'client' and status = 'migrated')
    and id not in (select id from _m_job);
  if n > 0 then h := h || jsonb_build_object('jobs_created_in_v2_for_migrated_clients', n); end if;
  return jsonb_build_object('hard', h, 'discardable', d);
end $function$;

revoke all on function v2_v1_migrate(date, boolean, boolean, boolean), v2_v1_reconcile(), v2_v1_purge_blockers()
  from public, anon, authenticated, service_role;
