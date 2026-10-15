-- ============================================================
-- Phase 3: 案件共有の解除・パスワード変更
-- ============================================================
set check_function_bodies = off;

-- パートナー: 自分がフロントへ共有した案件の公開切替・解除
create policy p_shares_upd on project_shares for update
  using (shared_by = v2_company_id()) with check (shared_by = v2_company_id());
create policy p_shares_del on project_shares for delete
  using (shared_by = v2_company_id());

-- パートナーのパスワード変更（現在のパスワードを確認してから更新）
create or replace function v2_change_password(p_current text, p_new text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v companies%rowtype;
begin
  select * into v from companies where id = v2_company_id();
  if not found then raise exception 'not authorized'; end if;
  if v.pw_hash is null or v.pw_hash <> crypt(p_current, v.pw_hash) then
    raise exception 'current password mismatch';
  end if;
  if length(coalesce(p_new, '')) < 8 then raise exception 'weak password'; end if;
  update companies set pw_hash = v2_hash_pw(p_new), must_change_pw = false, legacy_pw_hash = null
  where id = v.id;
end $$;
grant execute on function v2_change_password(text, text) to authenticated;
