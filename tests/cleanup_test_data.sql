-- テストデータの削除（切替前・または作り直したいときに実行）
-- 対象: 企業コード A99999 / B00001 とその配下、テスト用お知らせ、テスト用ログイン
begin;
delete from v2_notices where title like '%（テスト）';
delete from v2_invites where code in ('A99999','B00001');
delete from v2_members where company_id in (select id from v2_companies where code in ('A99999','B00001'));
delete from v2_companies where code = 'B00001';
delete from v2_companies where code = 'A99999';
delete from auth.users where email in ('a99999-01@id.kanoa-portal.invalid','a99999-02@id.kanoa-portal.invalid','b00001-01@id.kanoa-portal.invalid');
-- B00001 をテストで使ったため、2次の採番を戻す（本番の2次が B00001 から始まるように）
update v2_code_seq set last_no = 0 where tier = 2 and not exists (select 1 from v2_companies where tier = 2);
commit;
