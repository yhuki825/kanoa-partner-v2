-- ============================================================
-- チャットの添付: 削除したメッセージのファイルを置き場から実際に消せるようにする（124 の手直し）
--  ・置き場の配信（CDN）は、同じ人が直前に開いたファイルをしばらく覚えている。また発行済みの「開くためのURL」は
--    期限まで使える。権限の判定だけでは、削除の直後に送った本人が開けてしまう（2026-10-19 実測）
--  ・そこで、メッセージを削除したら、送った本人の画面がそのファイルを置き場から消す（実体が無くなれば、覚えていた分も
--    発行済みのURLも開けない）。消してよいのは「自分が置いたもの」で「紐づいていない or 削除したメッセージのもの」だけ
--  ・置き場の削除は、対象が「見える」ことも条件になるため、同じ条件で見えるようにする（本人だけ）
-- ============================================================
set check_function_bodies = off;

create or replace function v2_chat_file_orphan(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from storage.objects o where o.bucket_id = 'v2-files' and o.name = p_name and o.owner_id = auth.uid()::text)
     and not exists (select 1 from v2_message_files f join v2_messages m on m.id = f.message_id
                     where f.storage_path = p_name and not m.deleted)
$$;

drop policy if exists v2_files_chat_sel on storage.objects;
create policy v2_files_chat_sel on storage.objects for select to authenticated using (
  bucket_id = 'v2-files' and split_part(name, '/', 1) = 'chat' and (v2_chat_file_visible(name) or v2_chat_file_orphan(name)));
