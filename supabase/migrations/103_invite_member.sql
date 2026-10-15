-- ============================================================
-- 招待の受付・CA追加（Edge Function から service_role で呼ぶ）
-- 順序: ①招待を照合 → ②ログイン用アカウント作成（EF） → ③会社＋代表CA＋招待消込を1トランザクション
--       ③が失敗したらEFが②のアカウントを削除する（中途半端な状態を残さない）
-- ============================================================
set check_function_bodies = off;

create or replace function v2_hash_pw(p_plain text) returns text
language sql set search_path = public, extensions as $$ select crypt(p_plain, gen_salt('bf', 10)) $$;

-- ① 照合だけ（消込はしない）
create or replace function v2_invite_check(p_code text, p_temp_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare inv v2_invites%rowtype;
begin
  select * into inv from v2_invites where code = upper(trim(p_code));
  if not found then return jsonb_build_object('error','not_found'); end if;
  if inv.status <> 'issued' then return jsonb_build_object('error','already_used'); end if;
  if inv.expires_at < now() then return jsonb_build_object('error','expired'); end if;
  if inv.temp_pw_hash <> crypt(p_temp_pw, inv.temp_pw_hash) then return jsonb_build_object('error','bad_password'); end if;
  return jsonb_build_object('invite_id', inv.id, 'code', inv.code, 'tier', inv.tier, 'company_name', inv.company_name);
end $$;

-- ③ 会社＋代表CA＋消込（原子的）
create or replace function v2_invite_consume(p_invite uuid, p_user uuid, p_name text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv v2_invites%rowtype; v_company uuid; v_login text;
begin
  select * into inv from v2_invites where id = p_invite for update;
  if not found or inv.status <> 'issued' or inv.expires_at < now() then
    raise exception 'invite_unavailable';
  end if;
  insert into v2_companies(code, tier, parent_id, name, member_seq)
  values (inv.code, inv.tier, inv.issued_by, inv.company_name, 1)
  returning id into v_company;
  v_login := inv.code || '-01';
  insert into v2_members(user_id, company_id, role, login_id, name, email, is_owner, must_change_pw)
  values (p_user, v_company, 'ca', v_login, p_name, nullif(p_email, ''), true, false);
  update v2_invites set status = 'accepted', accepted_company_id = v_company, accepted_at = now()
  where id = inv.id;
  return jsonb_build_object('company_id', v_company, 'login_id', v_login);
end $$;

-- CA追加: 会社の次のログインIDを払い出してから、EFがアカウントを作り、ここで登録
create or replace function v2_member_insert(p_company uuid, p_user uuid, p_login text, p_name text, p_email text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into v2_members(user_id, company_id, role, login_id, name, email, must_change_pw)
  values (p_user, p_company, 'ca', p_login, p_name, nullif(p_email, ''), true)
  returning id into v_id;
  return v_id;
end $$;

revoke all on function v2_hash_pw(text), v2_invite_check(text, text),
  v2_invite_consume(uuid, uuid, text, text), v2_member_insert(uuid, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function v2_hash_pw(text), v2_invite_check(text, text),
  v2_invite_consume(uuid, uuid, text, text), v2_member_insert(uuid, uuid, text, text, text)
  to service_role;
