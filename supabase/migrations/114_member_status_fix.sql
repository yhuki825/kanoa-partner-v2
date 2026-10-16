-- 修正: 代表CAによるCAの停止・再開が、メンバー保護のトリガー（本人による権限の書き換え防止）に止められていた
-- 対処: 停止・再開の関数の中でだけ「信頼できる処理」の印を立て、トリガーはその印があれば通す
--       印はトランザクション内だけ有効（set_config の第3引数 true）。画面から直接は立てられない
set check_function_bodies = off;

create or replace function v2_members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- サーバー側の処理（Edge Function／管理用SQL）・RA・正規の関数の中からの更新は対象外
  if auth.uid() is null or v2_is_ra() or current_setting('v2.trusted_member_update', true) = 'on' then return new; end if;
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
  perform set_config('v2.trusted_member_update', 'on', true);   -- この関数の中の更新だけを通す
  update v2_members set status = p_status, version = t.version where id = t.id;
  perform set_config('v2.trusted_member_update', 'off', true);
end $$;
