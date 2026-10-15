-- 108_chat.sql（と 109〜111 の修正）を元に戻す（チャットのデータも消える）
begin;
alter publication supabase_realtime drop table v2_messages;
drop function if exists v2_thread_side(uuid, uuid), v2_my_threads(uuid), v2_chat_unread(),
  v2_thread_messages(uuid, uuid, timestamptz, int), v2_thread_messages(uuid, uuid, timestamptz, uuid, int), v2_msg_send(uuid, uuid, text, text, uuid),
  v2_msg_own(uuid), v2_msg_edit(uuid, int, text), v2_msg_delete(uuid), v2_msg_react(uuid, text),
  v2_msg_pin(uuid, boolean), v2_thread_mark_read(uuid, uuid), v2_thread_mark_unread(uuid, uuid) cascade;
drop table if exists v2_thread_reads, v2_messages cascade;
commit;
