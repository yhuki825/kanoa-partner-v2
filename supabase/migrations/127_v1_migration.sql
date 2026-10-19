-- ============================================================
-- V1 → V2 データ移行（何度流してもよい・切替前のお試し用）
-- 使い方: migration/run_migration.sh（DB → 書類ファイルのコピー → 照合レポート）
--
-- 原則
--  ・V1 のテーブルと置き場 candidate-docs は読むだけ（SELECT のみ）。書くのは v2_* と置き場 v2-files だけ
--  ・移行した行は v2_v1_map（kind, v1_id → v2_id）に記録する。流し直すと、まず記録にある行だけを消してから入れ直す
--    テスト用の会社（A99999 / B00001）とその配下は記録に無いので触れない
--  ・V2 の ID は V1 の ID から決まる（md5）。流し直しても同じ ID になる＝書類のコピー先も同じ
--  ・企業コードは v2_v1_company_codes に一度決めたら固定（流し直しても A00001 は A00001 のまま）
--  ・移行中だけ、対象の表の updated_at/version（v2_touch）と操作記録（v2_audit）のトリガーを止める
--    （V1 の日時を残すため／流し直すたびに求職者の個人情報の写しが操作記録に溜まらないようにするため）
--    同じトランザクションの中だけの変更で、終われば必ず元に戻る（失敗すれば丸ごと取り消し）
--  ・V2 の制約（電話番号の重複など）に止められた行は捨てずに status='failed' と理由を記録する
-- ============================================================
set check_function_bodies = off;

-- ---------- 移行の記録 ----------
create table if not exists v2_v1_map (
  kind       text not null,    -- agency / owner_member / client / project / assignment / referral / intake / document / intake_doc / message / notice / reward / reflog / task / tracker_link
  v1_id      text not null,
  v2_id      uuid,
  status     text not null check (status in ('migrated','skipped','failed')),
  reason     text,             -- 個人情報は入れない（V1 の ID と理由だけ）
  extra      jsonb,            -- 書類: {src, dst, size, mime}
  created_at timestamptz not null default now(),
  primary key (kind, v1_id)
);
create index if not exists v2_v1_map_v2 on v2_v1_map(v2_id);

-- 企業コードの割り当て（流し直しても変えない）
create table if not exists v2_v1_company_codes (
  agency_id   text primary key,
  code        text unique not null,
  assigned_at timestamptz not null default now()
);

-- 書類ファイルのコピー済み台帳（流し直しても消さない。コピーの要否・消し残しの判定に使う）
create table if not exists v2_v1_file_copies (
  dst_path  text primary key,
  src_path  text not null,
  size      bigint,
  copied_at timestamptz not null default now()
);

-- 実行の履歴
create table if not exists v2_v1_runs (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null default now(),
  params      jsonb,
  summary     jsonb
);

-- 画面（anon / authenticated）からは一切見せない
alter table v2_v1_map           enable row level security;
alter table v2_v1_company_codes enable row level security;
alter table v2_v1_file_copies   enable row level security;
alter table v2_v1_runs          enable row level security;
revoke all on v2_v1_map, v2_v1_company_codes, v2_v1_file_copies, v2_v1_runs from anon, authenticated;

-- ---------- 道具 ----------
create or replace function v2_v1_uuid(p_kind text, p_id text) returns uuid
language sql immutable as $$ select md5('kanoa-v1-migration:' || p_kind || ':' || p_id)::uuid $$;

-- 住所の先頭から都道府県を取る（取れなければ null）
create or replace function v2_v1_prefecture(p_addr text) returns text
language plpgsql immutable as $$
declare a text := btrim(coalesce(p_addr, ''), ' 　'); p text;
  prefs text[] := array['北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県','新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県','鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県'];
begin
  a := regexp_replace(a, '^〒?\s*[0-9０-９]{3}[-－ー]?[0-9０-９]{4}\s*', '');
  if a = '' then return null; end if;
  foreach p in array prefs loop
    if a like p || '%' then return p; end if;
  end loop;
  foreach p in array prefs loop
    if p <> '北海道' and a like regexp_replace(p, '[都府県]$', '') || '%' then return p; end if;
  end loop;
  return null;
end $$;

-- 文書の種類（V1 の日本語ラベル・紹介フォームの短いコード）→ V2 の kind
create or replace function v2_v1_file_kind(p_kind text) returns text
language sql immutable as $$
  select case coalesce(p_kind, '')
    when '履歴書' then 'resume' when 'rireki' then 'resume'
    when '職務経歴書' then 'cv' when 'shoku' then 'cv'
    when '源泉徴収票' then 'offer_1' when 'gensen' then 'offer_1'
    when '給与明細' then 'offer_2' when 'kyuyo' then 'offer_2'
    when '賞与明細' then 'offer_3' when 'shoyo' then 'offer_3'
    else 'other' end
$$;

-- V1 の SPI・コンプラの値の表示
create or replace function v2_v1_check_label(p text) returns text
language sql immutable as $$
  select case coalesce(p, 'none') when 'none' then '未案内' when 'sent' then '案内済み' when 'done' then '受検済み' else p end
$$;

-- 「8/20 18:00」→ 日付（年は登録日から推定。読めなければ null）
create or replace function v2_v1_session_date(p_session text, p_created timestamptz) returns date
language plpgsql immutable as $$
declare m text[]; y int; d date;
begin
  m := regexp_match(coalesce(p_session, ''), '^\s*([0-9]{1,2})/([0-9]{1,2})');
  if m is null then return null; end if;
  y := extract(year from (p_created at time zone 'Asia/Tokyo'))::int;
  begin
    d := make_date(y, m[1]::int, m[2]::int);
  exception when others then return null;
  end;
  if d < (p_created at time zone 'Asia/Tokyo')::date - 60 then d := d + interval '1 year'; end if;
  return d;
end $$;

-- 対象の表の updated_at/version・操作記録のトリガーを止める／戻す（同じトランザクションの中だけで使う）
create or replace function v2_v1_triggers(p_enable boolean) returns void
language plpgsql as $$
declare t record;
begin
  for t in
    select c.relname, tg.tgname from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
    where not tg.tgisinternal
      and c.relname in ('v2_companies','v2_members','v2_clients','v2_jobs','v2_job_kanoa_fees','v2_job_shares',
                        'v2_job_refund_policies','v2_candidates','v2_candidate_notes','v2_candidate_files',
                        'v2_applications','v2_milestones','v2_messages','v2_notices','v2_rewards')
      and (tg.tgname like '%\_touch' or tg.tgname like '%\_audit')
  loop
    execute format('alter table public.%I %s trigger %I', t.relname, case when p_enable then 'enable' else 'disable' end, t.tgname);
  end loop;
end $$;

-- ---------- 前回の移行分を消す（記録にある行だけ） ----------
create or replace function v2_v1_purge() returns jsonb
language plpgsql as $$
declare r jsonb := '{}'; n int;
begin
  -- 報酬（選考の削除を止める制約があるため先に）
  delete from v2_rewards
  where application_id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated')
     or candidate_id in (select v2_id from v2_v1_map where kind in ('referral','intake') and status = 'migrated')
     or job_id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('rewards', n);
  -- 選考（参加会社・経路・段階・チャット・既読はまとめて消える）
  delete from v2_applications where id in (select v2_id from v2_v1_map where kind = 'referral' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('applications', n);
  -- 求職者（書類の行・メモはまとめて消える。置き場のファイルはコピー用スクリプトが台帳で整理する）
  delete from v2_candidates
  where id in (select v2_v1_uuid('candidate', v1_id) from v2_v1_map where kind = 'referral' and status in ('migrated','failed'))
     or id in (select v2_id from v2_v1_map where kind = 'intake' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('candidates', n);
  delete from v2_notices where id in (select v2_id from v2_v1_map where kind = 'notice' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('notices', n);
  -- 求人（KANOAの紹介料・公開・返金規定はまとめて消える）
  delete from v2_jobs where id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('jobs', n);
  delete from v2_clients c where c.id in (select v2_id from v2_v1_map where kind = 'client' and status = 'migrated')
    and not exists (select 1 from v2_jobs j where j.client_id = c.id);
  get diagnostics n = row_count; r := r || jsonb_build_object('clients', n);
  delete from v2_members where id in (select v2_id from v2_v1_map where kind = 'owner_member' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('members', n);
  delete from v2_companies where id in (select v2_id from v2_v1_map where kind = 'agency' and status = 'migrated');
  get diagnostics n = row_count; r := r || jsonb_build_object('companies', n);
  delete from v2_v1_map;
  return r;
end $$;

-- ============================================================
-- 本体
--  p_joined_until    : V1 で入社日（joined_on）が入っていて、この日以前なら「入社」として扱う（既定: 日本時間の今日）
--                      それより先の入社日は「内定・入社待ち（最後の段階の予定日＝入社日）」にする
--  p_activate_members: 代表CAを利用中にするか（既定 false＝お試し中は停止。V1 のID・パスワードで V2 に入れない）
-- ============================================================
create or replace function v2_v1_migrate(p_joined_until date default null, p_activate_members boolean default false)
returns jsonb
language plpgsql as $$
declare
  v_until date := coalesce(p_joined_until, (now() at time zone 'Asia/Tokyo')::date);
  v_ra uuid; v_purged jsonb; v_summary jsonb;
  a record; p record; rf record; it record; d record;
  v_code text; v_cid uuid; v_mid uuid; v_jid uuid; v_cand uuid; v_app uuid;
  v_flow jsonb; v_n int; v_is int; v_ii int; v_io int;
  v_joined boolean; v_stage text; v_result text; v_mode text; v_passed int; v_fail int;
  v_sched date; v_txt text; v_kmemo text; v_amemo text; v_state text; v_con text; v_reason text; v_other text;
  v_docs jsonb; v_ext text; v_fid uuid; v_dst text; v_rid uuid; v_fee numeric; v_policy jsonb;
begin
  -- RA（KANOA の送信者・お知らせの作成者）
  select id into v_ra from v2_members where role = 'ra' and status = 'active' order by created_at limit 1;
  if v_ra is null then raise exception 'no active RA member'; end if;

  perform v2_v1_triggers(false);
  v_purged := v2_v1_purge();

  -- ========== 1) 会社（agencies → v2_companies、代表CA） ==========
  for a in select * from agencies order by joined nulls last, created_at, id loop
    if a.code in ('KA999','RE999') then
      insert into v2_v1_map values ('agency', a.id, null, 'skipped', 'decision 5: test/internal account (' || a.code || ') not migrated');
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
        nullif(btrim(p.summary), ''),
        '【採用予定数】' || nullif(btrim(p.headcount), ''),
        '【選考会】' || nullif(btrim(p.seminar), ''),
        '【通過のポイント】' || nullif(btrim(p.pass_note), ''),
        '【実績】' || nullif(btrim(p.case_study), '')),
      nullif(btrim(p.employment), ''), nullif(btrim(p.salary), ''), nullif(btrim(p.location), ''),
      concat_ws(E'\n\n',
        nullif(btrim(p.conditions), ''),
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
      -- 付帯情報（CA にも読める列なので、KANOA の受取額 client_fee とロゴ画像は入れない）
      coalesce(jsonb_strip_nulls(case when jsonb_typeof(p.detail) = 'object' then p.detail else '{}' end), '{}')
        || jsonb_build_object('v1', jsonb_strip_nulls(jsonb_build_object(
             'project_id', p.id, 'position', p.position, 'headcount', nullif(p.headcount, ''), 'seminar', nullif(p.seminar, ''),
             'pass_note', nullif(p.pass_note, ''), 'case_study', nullif(p.case_study, ''), 'flow', p.flow, 'requirements', p.requirements,
             'reward_type', p.reward_type, 'referral_reward', p.referral_reward, 'color', p.color))),
      coalesce(p.created_at, now()), coalesce(p.created_at, now()));
    -- KANOA→1次の紹介料（成約報酬）
    insert into v2_job_kanoa_fees(job_id, fee, created_at, updated_at)
    values (v_jid, coalesce(p.success_reward, 0), coalesce(p.created_at, now()), coalesce(p.created_at, now()));
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
      insert into v2_v1_map values ('referral', rf.id, null, 'failed', 'agency not migrated (' || coalesce(rf.agency_id, 'null') || ')');
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
      insert into v2_candidate_notes(candidate_id, company_id, memo, created_at, updated_at) values (v_cand, null, v_kmemo, rf.created_at, rf.created_at);
    end if;
    if v_amemo is not null then
      insert into v2_candidate_notes(candidate_id, company_id, memo, created_at, updated_at) values (v_cand, rf.cid, v_amemo, rf.created_at, rf.created_at);
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
      insert into v2_v1_map values ('intake', it.id, null, 'failed', 'agency not migrated (' || coalesce(it.agency_id, 'null') || ')');
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
    v_cand := v2_v1_uuid('intake', it.id);
    begin
      insert into v2_candidates(id, owner_company_id, assigned_member_id, name, kana, phone, email, prefecture, desired_location,
                                created_by, created_at, updated_at)
      values (v_cand, it.cid, it.mid, coalesce(nullif(btrim(it.name), ''), '（氏名未入力）'), nullif(btrim(it.kana), ''),
              nullif(btrim(it.phone), ''), nullif(btrim(it.email), ''), v2_v1_prefecture(it.address), nullif(btrim(it.area), ''),
              it.mid, coalesce(it.created_at, now()), coalesce(it.created_at, now()));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_con = constraint_name;
      select string_agg(m.v1_id, ',') into v_other from v2_v1_map m
      join v2_candidates c on c.id = case when m.kind = 'referral' then v2_v1_uuid('candidate', m.v1_id) else m.v2_id end
      where m.kind in ('referral','intake') and m.status = 'migrated' and v_con = 'v2_candidates_phone_uq'
        and c.phone_norm = regexp_replace(coalesce(it.phone, ''), '[^0-9]', '', 'g');
      insert into v2_v1_map values ('intake', it.id, null, 'failed',
        'candidate blocked: ' || v_state || coalesce(' ' || nullif(v_con, ''), '')
        || case when v_other is not null then ' (same phone as V1 ' || v_other || ')'
                when v_con = 'v2_candidates_phone_uq' then ' (same phone as a V2 candidate not created by this migration)' else '' end);
      -- この人の書類も移せない（同じ人の送客側の書類は documents から移る）
      insert into v2_v1_map(kind, v1_id, v2_id, status, reason)
      select 'intake_doc', it.id || '/' || coalesce(e->>'id', e->>'path', o::text), null,
             case when exists (select 1 from documents dd where dd.storage_path = e->>'path') then 'skipped' else 'failed' end,
             case when exists (select 1 from documents dd where dd.storage_path = e->>'path')
                  then 'same file is referenced by V1 documents (migrated there)'
                  else 'intake candidate blocked (' || it.id || ')' end
      from jsonb_array_elements(it.dl) with ordinality x(e, o)
      on conflict do nothing;
      continue;
    end;
    -- 選考が無い求職者は持ち主の会社にしか見えない（V2 の権限）ので、メモも持ち主の会社の分だけ
    insert into v2_candidate_notes(candidate_id, company_id, memo, created_at, updated_at)
    values (v_cand, it.cid, '― V1から引継ぎ ―' || E'\n' || v_txt, it.created_at, it.created_at);
    insert into v2_v1_map values ('intake', it.id, v_cand, 'migrated', 'decision 4: pending intake -> candidate without application');
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
         case when f.id is not null then 'migrated' else 'failed' end,
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
              else coalesce((select jsonb_agg(jsonb_build_object('emoji', e.key, 'member_id', mid) order by e.key, w.ord)
                               from jsonb_each(ms.reactions) e
                               cross join lateral jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value else '[]' end) with ordinality w(who, ord)
                               cross join lateral (select case when w.who = 'kanoa' then v_ra
                                                               else (select v2_id from v2_v1_map where kind = 'owner_member' and v1_id = w.who and status = 'migrated') end as mid) x
                              where x.mid is not null), '[]'::jsonb) end,
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
         case when v.id is not null then 'migrated' when ms.ref_id is null then 'skipped' else 'failed' end,
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
  cross join lateral (values (v_ra, 'up'), (ap.applied_by_member, 'self')) w(member_id, side)
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
  -- V1 の時点で出ていたお知らせは、移行した会社の代表CAには既読にしておく（切替時に未読バッジが溢れないように）
  insert into v2_notice_reads(notice_id, member_id, read_at)
  select v2_v1_uuid('notice', n.id), m.v2_id, coalesce(n.created_at, now())
  from notices n cross join v2_v1_map m
  where n.status = 'published' and m.kind = 'owner_member' and m.status = 'migrated'
  on conflict do nothing;

  -- ========== 10) 移さないもの（設計どおり） ==========
  insert into v2_v1_map(kind, v1_id, status, reason) select 'task', id, 'skipped', 'not migrated by design (V1 tasks)' from tasks;
  insert into v2_v1_map(kind, v1_id, status, reason) select 'tracker_link', token, 'skipped', 'not migrated by design (07-23: tracker_links not rebuilt)' from tracker_links;

  perform v2_v1_triggers(true);

  select jsonb_object_agg(kind, s) into v_summary from (
    select kind, jsonb_object_agg(status, n) s from (select kind, status, count(*) n from v2_v1_map group by 1, 2) x group by kind) y;
  v_summary := jsonb_build_object('purged', v_purged, 'map', v_summary, 'joined_until', v_until, 'members_active', p_activate_members);
  insert into v2_v1_runs(params, summary) values (jsonb_build_object('joined_until', v_until, 'activate_members', p_activate_members), v_summary);
  return v_summary;
end $$;

-- 実行は管理者（postgres）だけ。画面からは呼べない
revoke all on function v2_v1_uuid(text, text), v2_v1_prefecture(text), v2_v1_file_kind(text), v2_v1_check_label(text),
  v2_v1_session_date(text, timestamptz), v2_v1_triggers(boolean), v2_v1_purge(), v2_v1_migrate(date, boolean)
  from public, anon, authenticated;

-- ============================================================
-- 照合（設計書 8-E: 件数に加えて金額の合計も）。個人情報は返さない（件数・金額・V1 の ID だけ）
-- ============================================================
create or replace function v2_v1_reconcile() returns jsonb
language plpgsql stable as $$
declare
  v_until date := coalesce((select (params->>'joined_until')::date from v2_v1_runs order by id desc limit 1),
                           (now() at time zone 'Asia/Tokyo')::date);
  v1 jsonb; v2 jsonb; acct jsonb; checks jsonb := '[]'; xt jsonb; fails jsonb;
begin
  v1 := jsonb_build_object(
    'agencies', (select count(*) from agencies),
    'projects', (select count(*) from projects),
    'assignments', (select count(*) from assignments),
    'assignments_published', (select count(*) from assignments where published),
    'referrals', (select count(*) from referrals),
    'referrals_by_status', (select jsonb_object_agg(coalesce(status, 'null'), n) from (select status, count(*) n from referrals group by 1) x),
    'intake_by_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from intake group by 1) x),
    'documents', (select count(*) from documents),
    'documents_bytes', (select coalesce(sum(size), 0) from documents),
    'messages', (select count(*) from messages),
    'messages_with_ref', (select count(*) from messages where ref_id is not null),
    'messages_company_level', (select count(*) from messages where ref_id is null),
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
    'jobs_with_refund_policy', (select count(*) from v2_job_refund_policies where job_id in (select v2_id from v2_v1_map where kind = 'project' and status = 'migrated')),
    'shares', (select count(*) from v2_job_shares where id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'shares_published', (select count(*) from v2_job_shares where published and id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'sum_fee_override', (select coalesce(sum(fee_override), 0) from v2_job_shares where id in (select v2_id from v2_v1_map where kind = 'assignment' and status = 'migrated')),
    'candidates_from_referrals', (select count(*) from v2_candidates where id in (select v2_v1_uuid('candidate', v1_id) from v2_v1_map where kind = 'referral' and status = 'migrated')),
    'candidates_from_intake', (select count(*) from v2_candidates where id in (select v2_id from v2_v1_map where kind = 'intake' and status = 'migrated')),
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
    'rewards_pending', (select count(*) from v2_rewards where pay_status = 'pending' and id in (select v2_id from v2_v1_map where kind = 'reward' and status = 'migrated')));

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
     or (kind = 'intake' and status = 'skipped' and reason like '%no longer exists%') or (kind = 'referral' and reason is not null);

  return jsonb_build_object('generated_at', now(), 'v1', v1, 'v2', v2, 'accounting', acct, 'status_crosstab', xt, 'exceptions', fails);
end $$;
revoke all on function v2_v1_reconcile() from public, anon, authenticated;
