-- ============================================================
-- V2データの全消去（切替日の本移行の直前に実行）
-- 用途: お試し移行のデータとテストデータを消して、まっさらな状態から
--        900_migrate_from_v1.sql で最新のV1データを取り込み直す
-- ⚠ V2のテーブルだけを消す。V1には一切触れない
-- ============================================================
begin;
delete from candidate_steps;
delete from documents_v2;
delete from messages_v2;
delete from invoices_v2;
delete from tasks_v2;
delete from project_shares;
delete from candidates;
delete from projects_v2;
delete from invites;
delete from login_logs_v2;
delete from companies;
delete from company_code_seq;   -- 企業コード採番をリセット（A00001から振り直し）
select 'wiped' as result,
       (select count(*) from companies) companies,
       (select count(*) from candidates) candidates;
commit;
