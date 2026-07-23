-- ============================================================
-- KANOA Partner Portal V2  初期スキーマ
-- 方針: V1テーブル(agencies, referrals...)には触れない。V2は新テーブル群で並行稼働。
-- 認証: KANOA管理者 = supabase.auth / パートナー = Edge Function発行JWT
--        (claims: role='partner', company_id=<uuid>, tier=<int>)
-- ============================================================

-- ---------- 共通ヘルパー ----------
-- (関数本体の検証をテーブル作成後まで遅延させる。定義順の制約を無くすため)
set check_function_bodies = off;

create or replace function v2_claim(key text) returns text
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> key
$$;

-- ログイン中のパートナー企業id（管理者・未ログインは null）
-- 注意: JWTの 'role' クレームはPostgreSQLのDBロール名に予約されているため、
--        パートナー種別は 'app_role' クレームで表す（partner-login EFが付与）
create or replace function v2_company_id() returns uuid
language sql stable as $$
  select case when v2_claim('app_role') = 'partner' then (v2_claim('company_id'))::uuid end
$$;

-- KANOA管理者か（supabase.auth のユーザーで kanoa_admins_v2 に登録済み）
create or replace function v2_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from kanoa_admins_v2 where user_id = auth.uid())
$$;

-- ---------- 管理者 ----------
create table if not exists kanoa_admins_v2 (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  name      text,
  created_at timestamptz not null default now()
);

-- ---------- パートナー企業（木構造） ----------
create table if not exists companies (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,             -- 例 A00001 / B00013（階層頭文字＋5桁）
  tier       int  not null check (tier >= 1),  -- 1=Aライン
  parent_id  uuid references companies(id),    -- アップライン。1次は null（=KANOA直下）
  name       text not null,
  contact    text,
  email      text,
  phone      text,
  status     text not null default 'pending' check (status in ('pending','active','suspended')),
  pw_hash    text,                             -- bcrypt
  legacy_pw_hash text,                         -- V1移行用(SHA-256)。初回ログインで再ハッシュ後 null
  bank       jsonb,
  license    boolean not null default false,
  special    text,
  source     text,
  must_change_pw boolean not null default true, -- 初回ログインでパスワード変更を強制
  created_at timestamptz not null default now(),
  joined_at  timestamptz,
  -- 階層とコード頭文字の整合（1..26=A..Z, 27..=AA..）はEdge Functionが担保
  constraint companies_tier_parent check (
    (tier = 1 and parent_id is null) or (tier > 1 and parent_id is not null)
  )
);
create index if not exists idx_companies_parent on companies(parent_id);

-- 企業コード採番用: 階層ごとの連番
create table if not exists company_code_seq (
  tier    int primary key,
  last_no int not null default 0
);

-- ---------- 招待コード ----------
create table if not exists invites (
  id            uuid primary key default gen_random_uuid(),
  issued_by     uuid references companies(id),  -- null = KANOA発行（Aライン招待）
  code          text unique not null,           -- 受諾時にそのまま companies.code へ
  tier          int  not null,
  company_name  text not null,
  temp_pw_hash  text not null,                  -- 平文は保存しない（発行画面で一度だけ表示）
  status        text not null default 'issued' check (status in ('issued','accepted','revoked','expired')),
  issued_at     timestamptz not null default now(),
  accepted_at   timestamptz,
  expires_at    timestamptz not null default now() + interval '14 days',
  accepted_company_id uuid references companies(id)
);
create index if not exists idx_invites_issued_by on invites(issued_by);

-- ---------- 案件 ----------
create table if not exists projects_v2 (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  client      text,
  logo        text,
  color       text,
  status      text not null default 'open' check (status in ('open','paused','closed')),
  position    text,
  employment  text,
  salary      text,
  location    text,
  summary     text,
  conditions  text,
  requirements jsonb not null default '[]',
  flow        jsonb not null default '[]',
  reward_type text,
  referral_reward numeric not null default 0,
  success_reward  numeric not null default 0,
  client_fee      numeric not null default 0,
  headcount   text,
  seminar     text,
  pass_note   text,
  case_study  text,
  detail      jsonb,                            -- V1のdetail JSONを継承
  created_at  timestamptz not null default now()
);

-- 案件の公開範囲（KANOA→Aライン、および各社→自分のフロント）
create table if not exists project_shares (
  project_id uuid not null references projects_v2(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  shared_by  uuid references companies(id),     -- null = KANOAが共有
  published  boolean not null default true,
  ref_override numeric,                          -- KANOA→Aライン共有のみ使用
  suc_override numeric,
  created_at timestamptz not null default now(),
  primary key (project_id, company_id)
);

-- ---------- 候補者（求職者）＋リレー ----------
create table if not exists candidates (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kana          text,
  phone         text,
  email         text,
  address       text,
  area          text,
  project_id    uuid references projects_v2(id),
  registered_by uuid not null references companies(id),
  holder_id     uuid references companies(id),  -- 今、判断権を持つ企業。null = KANOA到着
  stage         text not null default 'relay' check (stage in ('relay','screening','rejected','closed')),
  status        text,                            -- KANOA到着後の選考ステータス（V1体系）
  session       text,
  joined_on     date,
  resigned      boolean not null default false,
  resigned_on   date,
  resign_fraud  boolean not null default false,
  resign_confirmed boolean not null default false,
  spi_status    text not null default 'none',
  compliance_status text not null default 'none',
  fail_at       text,
  seen_kanoa    boolean not null default false,
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists idx_candidates_holder on candidates(holder_id) where stage = 'relay';
create index if not exists idx_candidates_registered_by on candidates(registered_by);
-- 電話番号の重複登録防止（V1の思想を継承。空は許容）
create unique index if not exists uq_candidates_phone on candidates(phone) where phone is not null and phone <> '';

-- リレー判断履歴
create table if not exists candidate_steps (
  id           uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references candidates(id) on delete cascade,
  company_id   uuid references companies(id),   -- null = KANOA
  action       text not null check (action in ('registered','forwarded','rejected','accepted')),
  note         text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_steps_candidate on candidate_steps(candidate_id);

-- ---------- 連絡チャット（スレッド = 企業⇔そのアップライン） ----------
create table if not exists messages_v2 (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id) on delete cascade, -- スレッド主（下側の企業）
  sender       text not null check (sender in ('self','up')),            -- self=企業側 / up=アップ側(KANOA含む)
  body         text,
  candidate_id uuid references candidates(id) on delete set null,
  reply_to     uuid,
  reactions    jsonb not null default '[]',
  mentions     jsonb not null default '[]',
  stamp        text,
  pinned       boolean not null default false,
  edited       boolean not null default false,
  deleted      boolean not null default false,
  read         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists idx_messages_company on messages_v2(company_id, created_at);

-- ---------- 紹介料・請求（KANOA↔Aラインのみ） ----------
create table if not exists invoices_v2 (
  id           uuid primary key default gen_random_uuid(),
  no           text unique,
  company_id   uuid not null references companies(id),
  status       text not null default 'draft',
  items        jsonb not null default '[]',
  subtotal     numeric not null default 0,
  tax          numeric not null default 0,
  total        numeric not null default 0,
  issued_on    date,
  submitted_on date,
  decided_on   date,
  paid_on      date,
  reject_reason text,
  history      jsonb not null default '[]',
  created_at   timestamptz not null default now()
);

-- ---------- 書類 ----------
create table if not exists documents_v2 (
  id           uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references candidates(id) on delete cascade,
  name         text not null,
  kind         text,
  size         bigint,
  mime         text,
  storage_path text not null,
  uploaded_by  uuid references companies(id),   -- null = KANOA
  created_at   timestamptz not null default now()
);

-- ---------- タスク ----------
create table if not exists tasks_v2 (
  id           uuid primary key default gen_random_uuid(),
  owner        text not null,                    -- 'kanoa' or company uuid（文字列）
  from_owner   text,
  company_id   uuid references companies(id),
  candidate_id uuid references candidates(id) on delete set null,
  body         text not null,
  done         boolean not null default false,
  due          date,
  created_at   timestamptz not null default now()
);

-- ---------- ログインログ ----------
create table if not exists login_logs_v2 (
  id         bigint generated always as identity primary key,
  company_id uuid references companies(id),
  success    boolean not null,
  method     text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- RLS
-- 原則: パートナーが見えるのは「自分」「自分のフロント」「自分に関係する行」だけ。
--        書き込みの副作用が大きい操作（送客・招待・受諾）は Edge Function(service_role)のみ。
-- ============================================================
alter table kanoa_admins_v2 enable row level security;
alter table companies       enable row level security;
alter table company_code_seq enable row level security;
alter table invites         enable row level security;
alter table projects_v2     enable row level security;
alter table project_shares  enable row level security;
alter table candidates      enable row level security;
alter table candidate_steps enable row level security;
alter table messages_v2     enable row level security;
alter table invoices_v2     enable row level security;
alter table documents_v2    enable row level security;
alter table tasks_v2        enable row level security;
alter table login_logs_v2   enable row level security;

-- 管理者: 全テーブル全操作
create policy adm_kanoa_admins on kanoa_admins_v2 for select using (user_id = auth.uid());
create policy adm_companies  on companies       for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_invites    on invites         for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_projects   on projects_v2     for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_shares     on project_shares  for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_candidates on candidates      for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_steps      on candidate_steps for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_messages   on messages_v2     for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_invoices   on invoices_v2     for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_documents  on documents_v2    for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_tasks      on tasks_v2        for all using (v2_is_admin()) with check (v2_is_admin());
create policy adm_loginlogs  on login_logs_v2   for select using (v2_is_admin());

-- パートナー: companies = 自社(更新可) と 自分のフロント(閲覧)
create policy p_companies_self   on companies for select using (id = v2_company_id());
create policy p_companies_fronts on companies for select using (parent_id = v2_company_id());
create policy p_companies_update on companies for update using (id = v2_company_id()) with check (id = v2_company_id());

-- パートナー: 自分が発行した招待の閲覧・取消
create policy p_invites_sel on invites for select using (issued_by = v2_company_id());
create policy p_invites_upd on invites for update using (issued_by = v2_company_id()) with check (issued_by = v2_company_id());

-- パートナー: 共有された案件
create policy p_shares_sel   on project_shares for select using (company_id = v2_company_id());
create policy p_shares_front on project_shares for select using (shared_by = v2_company_id());
-- 自分が見られる案件を自分のフロントへ共有できる（報酬上書きは不可）
create policy p_shares_ins on project_shares for insert with check (
  shared_by = v2_company_id()
  and ref_override is null and suc_override is null
  and exists (select 1 from project_shares s where s.project_id = project_shares.project_id and s.company_id = v2_company_id() and s.published)
  and exists (select 1 from companies c where c.id = project_shares.company_id and c.parent_id = v2_company_id())
);
create policy p_projects_sel on projects_v2 for select using (
  exists (select 1 from project_shares s where s.project_id = projects_v2.id and s.company_id = v2_company_id() and s.published)
);

-- パートナー: 候補者 = 自分が登録した行 ＋ 判断待ちで自分が持つ行 ＋ 自分のフロントが登録した行
create policy p_cand_sel on candidates for select using (
  registered_by = v2_company_id()
  or holder_id = v2_company_id()
  or exists (select 1 from companies c where c.id = candidates.registered_by and c.parent_id = v2_company_id())
);
-- 登録は自社起点のみ（holder=自分のアップ or null は Edge Function 側で設定するため insert は EF 経由）
-- 個人情報の修正は「登録した企業」のみ（送客系の列は relay-forward EF のみが触る）
create policy p_cand_upd on candidates for update
  using (registered_by = v2_company_id())
  with check (registered_by = v2_company_id());

create policy p_steps_sel on candidate_steps for select using (
  exists (select 1 from candidates cd where cd.id = candidate_steps.candidate_id
          and (cd.registered_by = v2_company_id() or cd.holder_id = v2_company_id()
               or exists (select 1 from companies c where c.id = cd.registered_by and c.parent_id = v2_company_id())))
);

-- パートナー: チャット = 自分のスレッド ＋ フロント各社とのスレッド
create policy p_msg_sel on messages_v2 for select using (
  company_id = v2_company_id()
  or exists (select 1 from companies c where c.id = messages_v2.company_id and c.parent_id = v2_company_id())
);
create policy p_msg_ins on messages_v2 for insert with check (
  (company_id = v2_company_id() and sender = 'self')
  or (sender = 'up' and exists (select 1 from companies c where c.id = messages_v2.company_id and c.parent_id = v2_company_id()))
);
create policy p_msg_upd on messages_v2 for update using (
  company_id = v2_company_id()
  or exists (select 1 from companies c where c.id = messages_v2.company_id and c.parent_id = v2_company_id())
);

-- パートナー: 請求 = 自社宛のみ（実質Aラインのみ）
create policy p_inv_sel on invoices_v2 for select using (company_id = v2_company_id());
create policy p_inv_upd on invoices_v2 for update using (company_id = v2_company_id()) with check (company_id = v2_company_id());

-- パートナー: 書類 = 見える候補者に紐づく行
create policy p_doc_sel on documents_v2 for select using (
  exists (select 1 from candidates cd where cd.id = documents_v2.candidate_id
          and (cd.registered_by = v2_company_id() or cd.holder_id = v2_company_id()))
);
create policy p_doc_ins on documents_v2 for insert with check (
  uploaded_by = v2_company_id()
  and exists (select 1 from candidates cd where cd.id = documents_v2.candidate_id
              and (cd.registered_by = v2_company_id() or cd.holder_id = v2_company_id()))
);

-- パートナー: タスク = 自社に関係する行
create policy p_task_sel on tasks_v2 for select using (company_id = v2_company_id());
create policy p_task_all on tasks_v2 for insert with check (company_id = v2_company_id());
create policy p_task_upd on tasks_v2 for update using (company_id = v2_company_id()) with check (company_id = v2_company_id());
