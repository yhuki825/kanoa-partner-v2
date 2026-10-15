-- ============================================================
-- 旧V2（2026-07試作）の撤去
-- ・対象は旧V2のテーブル・関数・ログイン用アカウントだけ。V1には一切触れない
-- ・2026-10-15 事前確認: V1のポリシー/関数からの参照ゼロ、
--   旧V2のログイン用アカウントはドメイン partners.kanoa-portal.invalid の2件のみ
--   （V1は partner.kanoa.local、KANOA管理者は kanoa-inc.com で別物）
-- ============================================================
begin;

drop table if exists
  candidate_steps, documents_v2, messages_v2, invoices_v2, tasks_v2, project_shares,
  candidates, projects_v2, invites, login_logs_v2, company_code_seq, companies, kanoa_admins_v2
  cascade;

drop function if exists
  v2_claim(text), v2_company_id(), v2_is_admin(), v2_tier_prefix(int), v2_next_code(int),
  v2_register_candidate(jsonb), v2_relay_decide(uuid, text, text), v2_hash_pw(text),
  v2_verify_login(text, text, text),
  v2_accept_invite(text, text, text, text, text, text), v2_change_password(text, text)
  cascade;

delete from auth.users where email like '%@partners.kanoa-portal.invalid';

commit;
