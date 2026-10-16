-- テストデータの削除（tests/cleanup_test_data.sh から呼ぶ。書類ファイルは .sh が先に消す）
-- 対象: 企業コード A99999 / B00001 とその配下（招待で作った会社も含む）、テスト用の求人・求人企業・お知らせ・資料、テスト用ログイン
-- ※ 本番データは消さない（名前に「（テスト）」「（自動削除予定）」が付いたもの、テスト会社の配下だけ）
begin;
create temp table test_companies as
  with recursive t as (
    select id from v2_companies where code in ('A99999','B00001')
    union select c.id from v2_companies c join t on c.parent_id = t.id)
  select id from t;
-- 報酬（選考を消しても報酬は消えない設定＝116 のため、テスト選考の報酬を先に消す）
delete from v2_rewards where application_id in (select id from v2_applications where candidate_id in (select id from v2_candidates where owner_company_id in (select id from test_companies)));
-- 選考（パーティ・経路・段階・チャットは選考と一緒に消える）
delete from v2_applications where candidate_id in (select id from v2_candidates where owner_company_id in (select id from test_companies));
delete from v2_candidates where owner_company_id in (select id from test_companies);
delete from v2_notices where title like '%（テスト）';
delete from v2_resources where title like '%（テスト）';
delete from v2_job_offers where company_id in (select id from test_companies);
delete from v2_job_shares where company_id in (select id from test_companies);
delete from v2_jobs where title like '%（自動削除予定）';
delete from v2_clients where name like '%（自動削除予定）' and not exists (select 1 from v2_jobs j where j.client_id = v2_clients.id);
delete from v2_invites where issued_by in (select id from test_companies) or code in ('A99999','B00001')
  or accepted_company_id in (select id from test_companies);
create temp table test_users as select user_id from v2_members where company_id in (select id from test_companies);
delete from v2_members where company_id in (select id from test_companies);
-- 下の階層から順に会社を消す
delete from v2_companies where id in (select id from test_companies) and tier >= 3;
delete from v2_companies where id in (select id from test_companies) and tier = 2;
delete from v2_companies where id in (select id from test_companies);
delete from auth.users where id in (select user_id from test_users);
-- テストで使った2次以降の企業コードの採番を戻す（本番の2次が B00001 から始まるように）
update v2_code_seq s set last_no = coalesce((select max(substring(code from '[0-9]+$')::int) from v2_companies c where c.tier = s.tier), 0)
  where s.tier >= 2;
commit;
