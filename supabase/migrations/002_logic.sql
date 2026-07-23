-- ============================================================
-- KANOA Partner Portal V2  サーバー側ロジック
-- ・企業コード採番（同時実行安全）
-- ・候補者登録／送客リレー（トランザクション保証のRPC）
-- ・パスワード照合ヘルパー（pgcrypto bcrypt。Edge Functionから使用）
-- ============================================================
create extension if not exists pgcrypto;

-- ---------- 階層→頭文字（1=A .. 26=Z, 27=AA .. 702=ZZ。Excel列名と同じ規則） ----------
create or replace function v2_tier_prefix(p_tier int) returns text
language plpgsql immutable as $$
declare n int := p_tier; s text := '';
begin
  if p_tier < 1 or p_tier > 702 then raise exception 'tier out of range: %', p_tier; end if;
  while n > 0 loop
    s := chr(64 + ((n - 1) % 26 + 1)) || s;
    n := (n - 1) / 26;
  end loop;
  return s;
end $$;

-- ---------- 企業コード採番（行ロックで同時発行でも重複しない） ----------
create or replace function v2_next_code(p_tier int) returns text
language plpgsql security definer set search_path = public as $$
declare v_no int;
begin
  insert into company_code_seq(tier, last_no) values (p_tier, 0) on conflict (tier) do nothing;
  update company_code_seq set last_no = last_no + 1 where tier = p_tier returning last_no into v_no;
  if v_no > 99999 then raise exception 'code exhausted for tier %', p_tier; end if;
  return v2_tier_prefix(p_tier) || lpad(v_no::text, 5, '0');
end $$;
revoke all on function v2_next_code(int) from public, anon, authenticated;

-- ---------- 候補者登録 ----------
-- 呼び出し: パートナーJWT（自社起点で登録）または管理者（KANOA直接登録）
-- holder は「登録企業のアップライン」（1次なら null = KANOA判断待ち）に自動設定
create or replace function v2_register_candidate(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := v2_company_id();
  v_holder  uuid;
  v_id      uuid;
begin
  if v_company is null and not v2_is_admin() then raise exception 'not authorized'; end if;

  if v_company is not null then
    select parent_id into v_holder from companies where id = v_company and status = 'active';
    if not found then raise exception 'company not active'; end if;
  end if;

  insert into candidates(name, kana, phone, email, address, area, project_id, note,
                         registered_by, holder_id, stage, status)
  values (p->>'name', p->>'kana', nullif(p->>'phone',''), nullif(p->>'email',''),
          p->>'address', p->>'area', nullif(p->>'project_id','')::uuid, p->>'note',
          coalesce(v_company, nullif(p->>'registered_by','')::uuid),
          case when v_company is null then null else v_holder end,
          case when v_company is null then 'screening' else 'relay' end,
          case when v_company is null then '確認中' else null end)
  returning id into v_id;

  insert into candidate_steps(candidate_id, company_id, action, note)
  values (v_id, v_company, 'registered', p->>'note');
  return v_id;
end $$;
grant execute on function v2_register_candidate(jsonb) to anon, authenticated;

-- ---------- 送客／見送り／KANOA受入 ----------
-- p_action: 'forward'（アップへ送客）/ 'reject'（見送り）/ 'accept'（KANOA受入→選考へ）
create or replace function v2_relay_decide(p_candidate uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := v2_company_id();
  v_cand candidates%rowtype;
  v_next uuid;
begin
  select * into v_cand from candidates where id = p_candidate for update;
  if not found then raise exception 'candidate not found'; end if;
  if v_cand.stage <> 'relay' then raise exception 'not in relay stage'; end if;

  if v_company is not null then
    -- パートナー: 自分が判断権を持つ候補者のみ。acceptは不可
    if v_cand.holder_id is distinct from v_company then raise exception 'not the holder'; end if;
    if p_action = 'accept' then raise exception 'accept is KANOA only'; end if;
  elsif v2_is_admin() then
    -- KANOA: holder=null（到着済み）の候補者のみ
    if v_cand.holder_id is not null then raise exception 'not arrived at KANOA'; end if;
  else
    raise exception 'not authorized';
  end if;

  if p_action = 'forward' then
    select parent_id into v_next from companies where id = v_cand.holder_id;
    update candidates set holder_id = v_next where id = p_candidate;   -- v_next=null なら KANOA到着
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, v_company, 'forwarded', p_note);
  elsif p_action = 'reject' then
    update candidates set stage = 'rejected' where id = p_candidate;
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, v_company, 'rejected', p_note);
  elsif p_action = 'accept' then
    update candidates set stage = 'screening', status = coalesce(status, '確認中'), seen_kanoa = false
    where id = p_candidate;
    insert into candidate_steps(candidate_id, company_id, action, note)
    values (p_candidate, null, 'accepted', p_note);
  else
    raise exception 'unknown action: %', p_action;
  end if;
end $$;
grant execute on function v2_relay_decide(uuid, text, text) to anon, authenticated;

-- ---------- パスワード関連（Edge Function から service_role で呼ぶ。クライアント実行不可） ----------
create or replace function v2_hash_pw(p_plain text) returns text
language sql as $$ select crypt(p_plain, gen_salt('bf', 10)) $$;
revoke all on function v2_hash_pw(text) from public, anon, authenticated;

-- 照合: 成功なら company行(json)を返す。V1移行分は legacy(SHA-256) 照合→bcryptへ自動再ハッシュ
create or replace function v2_verify_login(p_code text, p_pw text, p_legacy_hash text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v companies%rowtype;
begin
  select * into v from companies where code = upper(p_code);
  if not found then return null; end if;
  if v.status = 'suspended' then return jsonb_build_object('suspended', true); end if;

  if v.pw_hash is not null and v.pw_hash = crypt(p_pw, v.pw_hash) then
    null; -- OK
  elsif v.legacy_pw_hash is not null and p_legacy_hash is not null and v.legacy_pw_hash = p_legacy_hash then
    -- V1形式で一致 → この場でbcryptへ移行
    update companies set pw_hash = v2_hash_pw(p_pw), legacy_pw_hash = null where id = v.id;
  else
    return null;
  end if;

  return jsonb_build_object('id', v.id, 'tier', v.tier, 'code', v.code, 'name', v.name,
                            'must_change_pw', v.must_change_pw);
end $$;
revoke all on function v2_verify_login(text, text, text) from public, anon, authenticated;

-- ---------- 招待の受諾（invite-accept EF から service_role で呼ぶ） ----------
-- 一時パスワード照合→companies行作成→invite消込 を1トランザクションで行う
create or replace function v2_accept_invite(p_code text, p_temp_pw text, p_new_pw text,
                                            p_contact text, p_email text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype; v_parent uuid; v_id uuid;
begin
  select * into inv from invites where code = upper(p_code) for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if inv.status <> 'issued' then return jsonb_build_object('error', 'already_used'); end if;
  if inv.expires_at < now() then
    update invites set status = 'expired' where id = inv.id;
    return jsonb_build_object('error', 'expired');
  end if;
  if inv.temp_pw_hash <> crypt(p_temp_pw, inv.temp_pw_hash) then
    return jsonb_build_object('error', 'bad_password');
  end if;
  if length(coalesce(p_new_pw, '')) < 8 then return jsonb_build_object('error', 'weak_password'); end if;

  insert into companies(code, tier, parent_id, name, contact, email, phone,
                        status, pw_hash, must_change_pw, joined_at)
  values (inv.code, inv.tier, inv.issued_by, inv.company_name, p_contact, p_email, p_phone,
          'active', v2_hash_pw(p_new_pw), false, now())
  returning id into v_id;

  update invites set status = 'accepted', accepted_at = now(), accepted_company_id = v_id
  where id = inv.id;

  return jsonb_build_object('id', v_id, 'tier', inv.tier, 'code', inv.code, 'name', inv.company_name);
end $$;
revoke all on function v2_accept_invite(text, text, text, text, text, text) from public, anon, authenticated;
