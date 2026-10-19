-- V1（本番）の求職者書類の置き場 candidate-docs の権限修正（2026-10-19 ユーザー承認「おねがいします」）
-- 問題: 「ログインしていれば全件読める／どこにでも置ける」許可があり、どのパートナーも他社の求職者の書類（全638件）を読めた
-- 直し方: その2つを外し、紹介フォーム経由の書類（intake/…）を自社の分だけ読める許可と、ログイン中の紹介フォームの置き場への登録を足す
--   KANOA は「docs kanoa all」、各パートナーの自社の求職者フォルダは「docs agency own」で、これまでどおり読み書きできる
-- 予行（本番の中で取り消し前提）: KANOA 638→638／AG-05 638→120／V2だけのアカウント 638→0、26社とも自社の書類で開けなくなるもの0件
-- 戻し方: 2026-10-19_candidate_docs_policy.rollback.sql
begin;
drop policy "authenticated read candidate docs"   on storage.objects;
drop policy "authenticated upload candidate docs" on storage.objects;

create policy "docs agency own intake read" on storage.objects
  for select to authenticated
  using (bucket_id = 'candidate-docs'
         and split_part(name, '/', 1) = 'intake'
         and split_part(name, '/', 2) in (select i.id from public.intake i
                                          where i.agency_id = public.my_agency_id()));

create policy "authenticated upload intake docs" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'candidate-docs' and (storage.foldername(name))[1] = 'intake');
commit;
