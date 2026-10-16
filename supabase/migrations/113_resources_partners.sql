-- ============================================================
-- 第5段階（前半）: 各種資料・パートナー管理（CAの停止/再開）・招待の取消
-- ============================================================
set check_function_bodies = off;

-- ---------- 各種資料（RAが登録、CAは公開中のものを閲覧） ----------
create table v2_resources (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) > 0),
  category text not null default 'その他',
  description text not null default '',
  kind text not null check (kind in ('file','link')),
  storage_path text unique,            -- kind=file: resources/{資料ID}/{ランダム}.{拡張子}
  file_name text, size bigint, mime text,
  url text,                            -- kind=link
  sort int not null default 100,
  published boolean not null default true,
  created_by uuid references v2_members(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  constraint v2_resources_kind check (
    (kind = 'file' and storage_path is not null) or
    (kind = 'link' and url ~* '^https?://'))
);
create trigger v2_resources_touch before insert or update on v2_resources for each row execute function v2_touch();
create trigger v2_resources_audit after insert or update or delete on v2_resources for each row execute function v2_audit();
alter table v2_resources enable row level security;
create policy v2_resources_ra on v2_resources for all using (v2_is_ra()) with check (v2_is_ra());
create policy v2_resources_ca on v2_resources for select using (published and v2_my_company() is not null);

-- 置き場（v2-files）の resources/ 以下: RAは読み書き、CAは公開中の資料のファイルだけ読める
create or replace function v2_storage_resource_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select split_part(p_name, '/', 1) = 'resources'
     and exists (select 1 from v2_resources r where r.storage_path = p_name and r.published)
$$;
grant execute on function v2_storage_resource_ok(text) to authenticated;
create policy v2_files_res_sel on storage.objects for select to authenticated using (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'resources'
  and (v2_is_ra() or v2_storage_resource_ok(name)));
create policy v2_files_res_ins on storage.objects for insert to authenticated with check (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'resources' and v2_is_ra());
create policy v2_files_res_del on storage.objects for delete to authenticated using (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'resources' and v2_is_ra());

-- 置き場に入れられる種類にテキストとCSVを足す（雛形・記入見本など）
update storage.buckets set allowed_mime_types = array(select distinct unnest(allowed_mime_types || array['text/plain','text/csv']))
where id = 'v2-files';

-- ---------- CAの停止・再開（代表CAは自社のCA、RAは全員。自分自身と代表者は止められない） ----------
create or replace function v2_set_member_status(p_member uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare me v2_members%rowtype; t v2_members%rowtype;
begin
  select * into me from v2_members where user_id = auth.uid() and status = 'active';
  if not found then raise exception 'not_authorized' using errcode = 'P0403', hint = 'ログインし直してください'; end if;
  select * into t from v2_members where id = p_member for update;
  if not found then raise exception 'not_found' using errcode = 'P0404'; end if;
  if p_status not in ('active','suspended') then raise exception 'bad_status' using errcode = 'P0400'; end if;
  if t.id = me.id then raise exception 'self' using errcode = 'P0403', hint = '自分自身は停止できません'; end if;
  if not (me.role = 'ra' or (me.is_owner and t.company_id is not distinct from me.company_id and t.role = 'ca')) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = 'CAの停止・再開は、会社の代表者だけが行えます';
  end if;
  if t.is_owner and me.role <> 'ra' then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '代表者は停止できません（KANOAにご相談ください）';
  end if;
  update v2_members set status = p_status, version = t.version where id = t.id;
end $$;
revoke all on function v2_set_member_status(uuid, text) from public, anon;
grant execute on function v2_set_member_status(uuid, text) to authenticated;
