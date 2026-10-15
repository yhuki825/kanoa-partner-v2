-- ============================================================
-- KANOA Partner Portal V2（2026-10 再設計版）土台
-- 範囲: 会社・個人アカウント・招待・お知らせ・操作記録
-- 命名: V1と同じSupabaseを共有するため、すべて v2_ 接頭辞
-- 方針（V1からの申し送りより）:
--   ・全テーブルに version（楽観ロック）と updated_at
--   ・権限のない更新は黙って無視せず、エラーを返す
--   ・操作記録（audit_log）をトリガーで自動記録
-- ============================================================
set check_function_bodies = off;
create extension if not exists pgcrypto;

-- ---------- 共通トリガー: updated_at と version ----------
create or replace function v2_touch() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    -- 楽観ロック: 画面が読んだときの version と違えば拒否（他の人の変更を古い値で上書きしない）
    if new.version is distinct from old.version then
      raise exception 'version_conflict' using errcode = 'P0409',
        hint = '他の人が先に更新しました。画面を読み込み直してください';
    end if;
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- ---------- 会社（パートナー。KANOA自身は行を持たない） ----------
create table v2_companies (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null check (code ~ '^[A-Z]{1,2}[0-9]{5}$'),
  tier       int  not null check (tier between 1 and 702),
  parent_id  uuid references v2_companies(id),
  name       text not null check (length(trim(name)) > 0),
  status     text not null default 'active' check (status in ('active','suspended')),
  member_seq int  not null default 0,          -- ログインIDの連番（-01, -02 ...）
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1,
  constraint v2_companies_tier_parent check ((tier = 1) = (parent_id is null))
);
create index v2_companies_parent on v2_companies(parent_id);
create trigger v2_companies_touch before insert or update on v2_companies
  for each row execute function v2_touch();

create table v2_code_seq (tier int primary key, last_no int not null default 0);

-- ---------- 個人アカウント（RA=KANOA社員 / CA=パートナーの担当者） ----------
create table v2_members (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid unique not null references auth.users(id) on delete cascade,
  company_id    uuid references v2_companies(id),   -- null = RA（KANOA）
  role          text not null check (role in ('ra','ca')),
  login_id      text unique,                          -- CAのみ。例 A00001-01
  name          text not null,
  email         text,                                 -- 連絡用（ログインには使わない）
  is_owner      boolean not null default false,       -- 会社の代表CA（CA追加・招待ができる）
  status        text not null default 'active' check (status in ('active','suspended')),
  must_change_pw boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  constraint v2_members_role_company check ((role = 'ra') = (company_id is null)),
  constraint v2_members_ca_login check (role = 'ra' or login_id is not null)
);
create index v2_members_company on v2_members(company_id);
create trigger v2_members_touch before insert or update on v2_members
  for each row execute function v2_touch();

-- ---------- 権限判定ヘルパー（ログイン中の本人を v2_members から引く） ----------
create or replace function v2_me() returns v2_members
language sql stable security definer set search_path = public as $$
  select * from v2_members where user_id = auth.uid() and status = 'active'
$$;
create or replace function v2_is_ra() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from v2_members where user_id = auth.uid() and role = 'ra' and status = 'active')
$$;
create or replace function v2_my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select m.company_id from v2_members m
  join v2_companies c on c.id = m.company_id and c.status = 'active'
  where m.user_id = auth.uid() and m.role = 'ca' and m.status = 'active'
$$;
create or replace function v2_is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_owner from v2_members where user_id = auth.uid() and status = 'active'), false)
$$;

-- ---------- 階層→頭文字・企業コード採番 ----------
create or replace function v2_tier_prefix(p_tier int) returns text
language plpgsql immutable as $$
declare n int := p_tier; s text := '';
begin
  if p_tier < 1 or p_tier > 702 then raise exception 'tier out of range: %', p_tier; end if;
  while n > 0 loop s := chr(64 + ((n - 1) % 26 + 1)) || s; n := (n - 1) / 26; end loop;
  return s;
end $$;

create or replace function v2_next_code(p_tier int) returns text
language plpgsql security definer set search_path = public as $$
declare v_no int;
begin
  insert into v2_code_seq(tier) values (p_tier) on conflict (tier) do nothing;
  update v2_code_seq set last_no = last_no + 1 where tier = p_tier returning last_no into v_no;
  if v_no > 99999 then raise exception 'code exhausted for tier %', p_tier; end if;
  return v2_tier_prefix(p_tier) || lpad(v_no::text, 5, '0');
end $$;

-- 会社のログインIDを1つ払い出す（A00001-01, -02 ...）
create or replace function v2_next_login_id(p_company uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text; v_no int;
begin
  update v2_companies set member_seq = member_seq + 1, version = version
   where id = p_company returning code, member_seq into v_code, v_no;
  if v_code is null then raise exception 'company not found'; end if;
  return v_code || '-' || lpad(v_no::text, 2, '0');
end $$;

-- ---------- 招待（フロント会社の招待。KANOA発行＝1次） ----------
create table v2_invites (
  id            uuid primary key default gen_random_uuid(),
  issued_by     uuid references v2_companies(id),   -- null = KANOA（RA）が発行
  issued_member uuid references v2_members(id),
  code          text unique not null,
  tier          int  not null,
  company_name  text not null,
  temp_pw_hash  text not null,                        -- 平文は保存しない
  status        text not null default 'issued' check (status in ('issued','accepted','revoked','expired')),
  expires_at    timestamptz not null default now() + interval '14 days',
  accepted_company_id uuid references v2_companies(id),
  accepted_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);
create index v2_invites_issued_by on v2_invites(issued_by);
create trigger v2_invites_touch before insert or update on v2_invites
  for each row execute function v2_touch();

-- ---------- お知らせ ----------
create table v2_notices (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(trim(title)) > 0),
  body        text not null default '',
  audience    text not null default 'all' check (audience in ('all','selected')),
  target_company_ids uuid[] not null default '{}',
  pinned      boolean not null default false,
  status      text not null default 'draft' check (status in ('draft','published')),
  published_at timestamptz,
  author_id   uuid references v2_members(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  version     int not null default 1
);
create trigger v2_notices_touch before insert or update on v2_notices
  for each row execute function v2_touch();

create table v2_notice_reads (
  notice_id uuid not null references v2_notices(id) on delete cascade,
  member_id uuid not null references v2_members(id) on delete cascade,
  read_at   timestamptz not null default now(),
  primary key (notice_id, member_id)
);

-- ---------- 操作記録（誰が・いつ・何を変えたか。人為か事故かの切り分けに使う） ----------
create table v2_audit_log (
  id         bigint generated always as identity primary key,
  table_name text not null,
  row_id     uuid,
  action     text not null,
  actor_user uuid,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now()
);
create index v2_audit_log_row on v2_audit_log(table_name, row_id);

create or replace function v2_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into v2_audit_log(table_name, row_id, action, actor_user, before, after)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then old.id else new.id end), null),
          lower(tg_op), auth.uid(),
          case when tg_op <> 'INSERT' then to_jsonb(old) - 'version' - 'updated_at' end,
          case when tg_op <> 'DELETE' then to_jsonb(new) - 'version' - 'updated_at' end);
  return coalesce(new, old);
end $$;
create trigger v2_companies_audit after insert or update or delete on v2_companies for each row execute function v2_audit();
create trigger v2_members_audit   after insert or update or delete on v2_members   for each row execute function v2_audit();
create trigger v2_invites_audit   after insert or update or delete on v2_invites   for each row execute function v2_audit();
create trigger v2_notices_audit   after insert or update or delete on v2_notices   for each row execute function v2_audit();

-- ============================================================
-- 権限（RLS）
-- ============================================================
alter table v2_companies    enable row level security;
alter table v2_code_seq     enable row level security;
alter table v2_members      enable row level security;
alter table v2_invites      enable row level security;
alter table v2_notices      enable row level security;
alter table v2_notice_reads enable row level security;
alter table v2_audit_log    enable row level security;

-- 会社: RAは全社。CAは自社＋自社のフロント。直接の作成・削除は不可（Edge Function経由）
create policy v2_companies_sel on v2_companies for select using (
  v2_is_ra() or id = v2_my_company() or parent_id = v2_my_company());
create policy v2_companies_upd_ra on v2_companies for update using (v2_is_ra()) with check (v2_is_ra());

-- 個人: RAは全員。CAは自社のメンバーと、自社のフロントの代表者（連絡先として）
create policy v2_members_sel on v2_members for select using (
  v2_is_ra()
  or company_id = v2_my_company()
  or (is_owner and company_id in (select id from v2_companies where parent_id = v2_my_company())));
-- 自分の表示名・連絡用メールだけは本人が直せる（列の制限はトリガーで強制）
create policy v2_members_upd_self on v2_members for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy v2_members_upd_ra   on v2_members for update using (v2_is_ra()) with check (v2_is_ra());

create or replace function v2_members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- サーバー側の処理（Edge Function／管理用SQL）はログイン中の本人がいないので対象外
  if auth.uid() is null or v2_is_ra() then return new; end if;
  if (new.company_id, new.role, new.login_id, new.is_owner, new.status, new.user_id)
     is distinct from (old.company_id, old.role, old.login_id, old.is_owner, old.status, old.user_id) then
    raise exception 'permission_denied' using errcode = 'P0403',
      hint = 'この項目は変更できません（変更できるのは表示名と連絡用メールだけです）';
  end if;
  if new.must_change_pw = true and old.must_change_pw = false then
    raise exception 'permission_denied' using errcode = 'P0403';
  end if;
  return new;
end $$;
create trigger v2_members_guard before update on v2_members for each row execute function v2_members_guard();

-- 招待: RAは全件。CAは自社が発行したもの（作成はEdge Function、取消は代表CAのみ）
create policy v2_invites_sel on v2_invites for select using (
  v2_is_ra() or (issued_by is not null and issued_by = v2_my_company()));
create policy v2_invites_revoke on v2_invites for update using (
  v2_is_ra() or (v2_is_owner() and issued_by = v2_my_company()))
  with check (status = 'revoked');

-- お知らせ: RAは全操作。CAは公開済みで、全社向け or 自社が対象のものを読むだけ
create policy v2_notices_ra on v2_notices for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_notices_ca on v2_notices for select using (
  status = 'published'
  and (audience = 'all' or v2_my_company() = any(target_company_ids)));

create policy v2_notice_reads_own on v2_notice_reads for all
  using (member_id = (v2_me()).id) with check (member_id = (v2_me()).id);
create policy v2_notice_reads_ra on v2_notice_reads for select using (v2_is_ra());

create policy v2_audit_ra on v2_audit_log for select using (v2_is_ra());

-- ---------- 実行権限 ----------
revoke all on function v2_next_code(int), v2_next_login_id(uuid) from public, anon, authenticated;
grant execute on function v2_next_code(int), v2_next_login_id(uuid) to service_role;
grant execute on function v2_me(), v2_is_ra(), v2_my_company(), v2_is_owner() to authenticated;

-- 本人のパスワード変更後に「初回変更が必要」を外す（本人だけ・外す方向だけ）
create or replace function v2_clear_must_change_pw() returns void
language sql security definer set search_path = public as $$
  update v2_members set must_change_pw = false where user_id = auth.uid() and must_change_pw
$$;
grant execute on function v2_clear_must_change_pw() to authenticated;
