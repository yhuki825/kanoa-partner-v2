-- 2026-10-19_candidate_docs_policy.sql を元に戻す（外した2つの許可を、元の定義のまま戻す）
begin;
drop policy if exists "docs agency own intake read"      on storage.objects;
drop policy if exists "authenticated upload intake docs" on storage.objects;
create policy "authenticated read candidate docs" on storage.objects
  as permissive for select to authenticated using (bucket_id = 'candidate-docs'::text);
create policy "authenticated upload candidate docs" on storage.objects
  as permissive for insert to authenticated with check (bucket_id = 'candidate-docs'::text);
commit;
