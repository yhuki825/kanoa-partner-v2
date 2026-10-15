-- ============================================================
-- 第2段階: 求職者・書類・求人企業・求人・紹介料
-- 紹介料の見え方（設計書 4.4）:
--   1次 = KANOA→自社の額（求人ごとの基本額、会社ごとの上書きがあればそちら）
--   2次以降 = 直上の会社がフロント向けに設定した額
--   自分より上の会社に提示された額は、DBの権限で見えない
-- ============================================================
set check_function_bodies = off;

-- ---------- 求人企業 ----------
create table v2_clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  industry text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create trigger v2_clients_touch before insert or update on v2_clients for each row execute function v2_touch();
create trigger v2_clients_audit after insert or update or delete on v2_clients for each row execute function v2_audit();

-- ---------- 求人（紹介料の列は持たない） ----------
create table v2_jobs (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references v2_clients(id),
  title text not null check (length(trim(title)) > 0),   -- 求人名・職種
  description text not null default '',                  -- 業務内容
  employment text, salary text, location text,
  conditions text not null default '',                   -- その他の条件
  entry_requirements jsonb not null default '[]',        -- エントリー時必須項目（求職者の項目キーの配列）
  flow jsonb not null default '["書類選考","一次面接","最終面接","内定","入社"]',  -- 選考フロー
  checks jsonb not null default '{"spi":false,"compliance":false}',
  status text not null default 'open' check (status in ('open','paused','closed')),
  detail jsonb,                                           -- V1から移行する付帯情報
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create index v2_jobs_client on v2_jobs(client_id);
create trigger v2_jobs_touch before insert or update on v2_jobs for each row execute function v2_touch();
create trigger v2_jobs_audit after insert or update or delete on v2_jobs for each row execute function v2_audit();

-- KANOA→1次の基本額（RAだけが読める）
create table v2_job_kanoa_fees (
  id uuid primary key default gen_random_uuid(),
  job_id uuid unique not null references v2_jobs(id) on delete cascade,
  fee numeric not null default 0 check (fee >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create trigger v2_job_kanoa_fees_touch before insert or update on v2_job_kanoa_fees for each row execute function v2_touch();
create trigger v2_job_kanoa_fees_audit after insert or update or delete on v2_job_kanoa_fees for each row execute function v2_audit();

-- KANOA→1次の公開（会社ごと。上書き額があれば基本額より優先）
create table v2_job_shares (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references v2_jobs(id) on delete cascade,
  company_id uuid not null references v2_companies(id) on delete cascade,
  published boolean not null default true,
  fee_override numeric check (fee_override >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (job_id, company_id)
);
create trigger v2_job_shares_touch before insert or update on v2_job_shares for each row execute function v2_touch();
create trigger v2_job_shares_audit after insert or update or delete on v2_job_shares for each row execute function v2_audit();
create or replace function v2_job_shares_tier1() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from v2_companies where id = new.company_id and tier = 1) then
    raise exception 'tier1_only' using errcode = 'P0403', hint = 'KANOAが直接公開できるのは1次パートナーだけです';
  end if;
  return new;
end $$;
create trigger v2_job_shares_tier1 before insert or update on v2_job_shares for each row execute function v2_job_shares_tier1();

-- 各社→自分のフロント全社への提示（1求人につき1社1行。設計書Q2: フロント全社に同じ額）
create table v2_job_offers (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references v2_jobs(id) on delete cascade,
  company_id uuid not null references v2_companies(id) on delete cascade,   -- 提示する会社
  fee_display numeric not null check (fee_display >= 0),
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (job_id, company_id)
);
create trigger v2_job_offers_touch before insert or update on v2_job_offers for each row execute function v2_touch();
create trigger v2_job_offers_audit after insert or update or delete on v2_job_offers for each row execute function v2_audit();

-- その会社にこの求人が見えるか（階層をたどって判定）
create or replace function v2_job_visible(p_job uuid, p_company uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare c record; cur uuid := p_company;
begin
  if p_company is null then return false; end if;
  loop
    select id, tier, parent_id, status into c from v2_companies where id = cur;
    if not found or c.status <> 'active' then return false; end if;
    if c.tier = 1 then
      return exists (select 1 from v2_job_shares where job_id = p_job and company_id = cur and published);
    end if;
    if not exists (select 1 from v2_job_offers where job_id = p_job and company_id = c.parent_id and published) then
      return false;
    end if;
    cur := c.parent_id;
  end loop;
end $$;

-- 自分に提示された紹介料（求人の行に付けて読む: select=*,v2_my_fee）
create or replace function v2_my_fee(j v2_jobs) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare me uuid := v2_my_company(); t int; p uuid;
begin
  if v2_is_ra() then
    return (select fee from v2_job_kanoa_fees where job_id = j.id);
  end if;
  if me is null or not v2_job_visible(j.id, me) then return null; end if;
  select tier, parent_id into t, p from v2_companies where id = me;
  if t = 1 then
    return coalesce((select fee_override from v2_job_shares where job_id = j.id and company_id = me),
                    (select fee from v2_job_kanoa_fees where job_id = j.id));
  end if;
  return (select fee_display from v2_job_offers where job_id = j.id and company_id = p and published);
end $$;

-- ---------- 求職者 ----------
create table v2_candidates (
  id uuid primary key default gen_random_uuid(),
  owner_company_id uuid references v2_companies(id),     -- null = KANOAが持つ求職者
  assigned_member_id uuid references v2_members(id),     -- 担当
  name text not null check (length(trim(name)) > 0),
  kana text,
  birth_date date,
  gender text check (gender in ('男性','女性','その他','回答しない')),
  education text,
  job_changes int check (job_changes between 0 and 99),  -- 就業経験社数
  employment_type text,
  current_income int check (current_income >= 0),       -- 直近の年収（万円）
  prefecture text,
  email text,
  phone text,
  phone_norm text generated always as (regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g')) stored,
  desired_location text,
  travel_ok boolean,          -- 出張: true=可 false=不可 null=未確認
  relocation_ok boolean,      -- 転勤
  desired_income int check (desired_income >= 0),        -- 希望年収（万円）
  recommendation text,        -- 推薦文（アップラインにも届く）
  created_by uuid references v2_members(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
-- 同じ電話番号の求職者は登録できない（全社横断。V1と同じ）
create unique index v2_candidates_phone_uq on v2_candidates(phone_norm) where phone_norm <> '';
create index v2_candidates_owner on v2_candidates(owner_company_id);
create trigger v2_candidates_touch before insert or update on v2_candidates for each row execute function v2_touch();
create trigger v2_candidates_audit after insert or update or delete on v2_candidates for each row execute function v2_audit();

-- 持ち主と担当の整合（担当は持ち主の会社のメンバー）＋持ち主は変更不可
create or replace function v2_candidates_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.owner_company_id is distinct from old.owner_company_id then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '求職者の持ち主の会社は変更できません';
  end if;
  if new.assigned_member_id is not null and not exists (
       select 1 from v2_members m where m.id = new.assigned_member_id
         and m.company_id is not distinct from new.owner_company_id) then
    raise exception 'bad_assignee' using errcode = 'P0403', hint = '担当は同じ会社のメンバーから選んでください';
  end if;
  return new;
end $$;
create trigger v2_candidates_guard before insert or update on v2_candidates for each row execute function v2_candidates_guard();

-- 会社ごとのメモ（他社には見えない。null = KANOA のメモ）
create table v2_candidate_notes (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references v2_candidates(id) on delete cascade,
  company_id uuid references v2_companies(id) on delete cascade,
  memo text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create unique index v2_candidate_notes_uq on v2_candidate_notes(candidate_id, coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid));
create trigger v2_candidate_notes_touch before insert or update on v2_candidate_notes for each row execute function v2_touch();

-- 書類
create table v2_candidate_files (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references v2_candidates(id) on delete cascade,
  kind text not null check (kind in ('resume','cv','offer_1','offer_2','offer_3','other')),
  name text not null,
  size bigint, mime text,
  storage_path text unique not null,
  uploaded_by uuid references v2_members(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create index v2_candidate_files_cand on v2_candidate_files(candidate_id);
create trigger v2_candidate_files_touch before insert or update on v2_candidate_files for each row execute function v2_touch();
create trigger v2_candidate_files_audit after insert or update or delete on v2_candidate_files for each row execute function v2_audit();

-- ---------- 権限判定（第3段階で「届いた選考の求職者」を追加する） ----------
create or replace function v2_can_edit_candidate(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from v2_candidates c where c.id = p_cand and (
    (c.owner_company_id is not null and c.owner_company_id = v2_my_company())
    or (c.owner_company_id is null and v2_is_ra())))
$$;
create or replace function v2_can_view_candidate(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select v2_can_edit_candidate(p_cand)
$$;

-- ============================================================
-- RLS
-- ============================================================
alter table v2_clients enable row level security;
alter table v2_jobs enable row level security;
alter table v2_job_kanoa_fees enable row level security;
alter table v2_job_shares enable row level security;
alter table v2_job_offers enable row level security;
alter table v2_candidates enable row level security;
alter table v2_candidate_notes enable row level security;
alter table v2_candidate_files enable row level security;

-- 求人企業・求人: RAは全操作。CAは自社に見える求人と、その求人企業だけ読める
create policy v2_clients_ra on v2_clients for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_clients_ca on v2_clients for select using (
  exists (select 1 from v2_jobs j where j.client_id = v2_clients.id and v2_job_visible(j.id, v2_my_company())));
create policy v2_jobs_ra on v2_jobs for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_jobs_ca on v2_jobs for select using (v2_job_visible(id, v2_my_company()));

-- 紹介料: KANOAの基本額はRAだけ。会社ごとの公開行は、その1次本人とRAだけ
create policy v2_job_kanoa_fees_ra on v2_job_kanoa_fees for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_job_shares_ra on v2_job_shares for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_job_shares_own on v2_job_shares for select using (company_id = v2_my_company());

-- フロントへの提示: 出した本人と、そのフロント（＝直下の会社）が読める。作成・変更は代表CAだけ
create policy v2_job_offers_sel on v2_job_offers for select using (
  v2_is_ra() or company_id = v2_my_company()
  or company_id = (select parent_id from v2_companies where id = v2_my_company()));
create policy v2_job_offers_ins on v2_job_offers for insert with check (
  company_id = v2_my_company() and v2_is_owner() and v2_job_visible(job_id, company_id));
create policy v2_job_offers_upd on v2_job_offers for update
  using (company_id = v2_my_company() and v2_is_owner())
  with check (company_id = v2_my_company() and v2_is_owner() and v2_job_visible(job_id, company_id));

-- 求職者
create policy v2_candidates_sel on v2_candidates for select using (v2_can_view_candidate(id));
create policy v2_candidates_ins on v2_candidates for insert with check (
  (owner_company_id is not null and owner_company_id = v2_my_company())
  or (owner_company_id is null and v2_is_ra()));
create policy v2_candidates_upd on v2_candidates for update using (v2_can_edit_candidate(id)) with check (v2_can_edit_candidate(id));

-- メモ: 自社（RAはKANOA）の行だけ
create policy v2_candidate_notes_own on v2_candidate_notes for all
  using (v2_can_view_candidate(candidate_id) and (
    (company_id is not null and company_id = v2_my_company()) or (company_id is null and v2_is_ra())))
  with check (v2_can_view_candidate(candidate_id) and (
    (company_id is not null and company_id = v2_my_company()) or (company_id is null and v2_is_ra())));

-- 書類: 見える求職者の書類は読める。追加・削除は編集できる人
create policy v2_candidate_files_sel on v2_candidate_files for select using (v2_can_view_candidate(candidate_id));
create policy v2_candidate_files_ins on v2_candidate_files for insert with check (
  v2_can_edit_candidate(candidate_id) and uploaded_by = (v2_me()).id);
create policy v2_candidate_files_del on v2_candidate_files for delete using (v2_can_edit_candidate(candidate_id));

-- ---------- 書類の置き場（V1のバケットとは分ける。非公開） ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('v2-files', 'v2-files', false, 20971520, array[
  'application/pdf','image/jpeg','image/png','image/heic',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do nothing;

-- パス: candidates/{求職者ID}/{ランダム}.{拡張子}
create or replace function v2_storage_cand(p_name text) returns uuid
language plpgsql immutable as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) < 3 or parts[1] <> 'candidates' then return null; end if;
  return parts[2]::uuid;
exception when others then return null;
end $$;

create policy v2_files_sel on storage.objects for select to authenticated using (
  bucket_id = 'v2-files' and v2_can_view_candidate(v2_storage_cand(name)));
create policy v2_files_ins on storage.objects for insert to authenticated with check (
  bucket_id = 'v2-files' and v2_can_edit_candidate(v2_storage_cand(name)));
create policy v2_files_del on storage.objects for delete to authenticated using (
  bucket_id = 'v2-files' and v2_can_edit_candidate(v2_storage_cand(name)));

-- ---------- 一覧（検索・ページング・件数をDB側で。申し送りA-5） ----------
-- 権限は呼び出した本人のまま（security invoker）なので、見えない行は返らない
create or replace function v2_candidate_list(p_q text default '', p_limit int default 50, p_offset int default 0)
returns table (id uuid, name text, kana text, birth_date date, gender text, prefecture text,
               assigned_name text, memo text, created_at timestamptz, total bigint)
language sql stable security invoker set search_path = public as $$
  with mine as (
    select c.*, m.name as assigned_name,
           (select n.memo from v2_candidate_notes n where n.candidate_id = c.id
              and n.company_id is not distinct from (case when v2_is_ra() then null else v2_my_company() end)) as memo
    from v2_candidates c left join v2_members m on m.id = c.assigned_member_id
  ), hit as (
    select * from mine where coalesce(p_q, '') = ''
      or name ilike '%' || p_q || '%' or kana ilike '%' || p_q || '%'
      or coalesce(memo, '') ilike '%' || p_q || '%' or coalesce(recommendation, '') ilike '%' || p_q || '%'
      or phone_norm like '%' || regexp_replace(p_q, '[^0-9]', '', 'g') || '%' and regexp_replace(p_q, '[^0-9]', '', 'g') <> ''
  )
  select id, name, kana, birth_date, gender, prefecture, assigned_name, memo, created_at, count(*) over ()
  from hit order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$$;

grant execute on function v2_job_visible(uuid, uuid), v2_my_fee(v2_jobs), v2_can_edit_candidate(uuid),
  v2_can_view_candidate(uuid), v2_candidate_list(text, int, int) to authenticated;
