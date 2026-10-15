-- テストデータの削除（tests/cleanup_test_data.sh から呼ぶ。書類ファイルは .sh が先に消す）
-- 対象: 企業コード A99999 / B00001 とその配下、テスト用の求人・求人企業・お知らせ、テスト用ログイン
begin;
delete from v2_notices where title like '%（テスト）';
delete from v2_candidates where owner_company_id in (select id from v2_companies where code in ('A99999','B00001'));
delete from v2_jobs where title like '%（自動削除予定）';
delete from v2_clients where name like '%（自動削除予定）' and not exists (select 1 from v2_jobs j where j.client_id = v2_clients.id);
delete from v2_job_offers where company_id in (select id from v2_companies where code in ('A99999','B00001'));
delete from v2_invites where code in ('A99999','B00001');
delete from v2_members where company_id in (select id from v2_companies where code in ('A99999','B00001'));
delete from v2_companies where code = 'B00001';
delete from v2_companies where code = 'A99999';
delete from auth.users where email in ('a99999-01@id.kanoa-portal.invalid','a99999-02@id.kanoa-portal.invalid','b00001-01@id.kanoa-portal.invalid');
-- B00001 をテストで使ったため、2次の採番を戻す（本番の2次が B00001 から始まるように）
update v2_code_seq set last_no = 0 where tier = 2 and not exists (select 1 from v2_companies where tier = 2);
commit;
