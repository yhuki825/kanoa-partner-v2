-- ============================================================
-- パートナー認証を Supabase Auth セッション方式へ変更
-- ・Edge Function が code+pw を照合後、企業に紐づく auth ユーザーの
--   セッションを発行する（JWTは Supabase が現行の署名鍵で発行）
-- ・企業の識別は JWT の app_metadata（app_role / company_id / tier）で行う
-- ============================================================
set check_function_bodies = off;

create or replace function v2_company_id() returns uuid
language sql stable as $$
  select case
    when nullif(current_setting('request.jwt.claims', true), '')::jsonb
           -> 'app_metadata' ->> 'app_role' = 'partner'
    then (nullif(current_setting('request.jwt.claims', true), '')::jsonb
           -> 'app_metadata' ->> 'company_id')::uuid
  end
$$;

-- companies に auth ユーザーの対応を持つ（EFが作成・管理）
alter table companies add column if not exists auth_user_id uuid references auth.users(id);
create unique index if not exists uq_companies_auth_user on companies(auth_user_id);
