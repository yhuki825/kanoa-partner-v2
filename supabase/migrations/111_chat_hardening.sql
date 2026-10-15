-- ============================================================
-- 選考チャットの強化（独立レビューの指摘を実測で再現したうえで修正）
--  1) 削除したメッセージの本文が表から直接読めた → 削除時に本文・スタンプ・リアクションを消す
--  2) 上の会社に届く前でも下の会社が「アップラインとの会話」に書けた → 届いてから
--  6) 関数が未ログインでも呼べた（中で弾くので漏れは無いが二重の守り）→ 公開を閉じる
--  7) 権限を失った送信者が過去のメッセージを編集・削除できた → 参加中の人だけ
--  8) スタンプがサーバーで検証されていなかった → 決まったものだけ・本文との併用不可
--  9) ピン・リアクションで版数が上がり、送信者の編集が「先に更新された」で失敗した → 本文の編集は版数の照合をしない（送信者本人しか編集できないため）
-- 10) 「さらに前を読み込む」で同時刻のメッセージを取りこぼした → (時刻, id) で区切る
-- 元に戻す手順は 108_chat.down.sql（チャット一式を撤去）
-- ============================================================
set check_function_bodies = off;

create or replace function v2_thread_side(p_app uuid, p_thread uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare my uuid := v2_my_company(); l record; upper_reached boolean;
begin
  if exists (select 1 from v2_applications where id = p_app and kind = 'external') then return null; end if;
  select id, tier, parent_id into l from v2_companies where id = p_thread;
  if not found then return null; end if;
  if not exists (select 1 from v2_application_parties where application_id = p_app and company_id = p_thread) then
    return null;
  end if;
  -- 上側（直上の会社 or KANOA）にこの選考が届いているか
  if l.parent_id is not null then
    upper_reached := exists (select 1 from v2_application_parties where application_id = p_app and company_id = l.parent_id);
  else
    upper_reached := exists (select 1 from v2_applications where id = p_app and kanoa_visible);
  end if;
  if not upper_reached then return null; end if;
  if my is not null and my = p_thread then return 'self'; end if;
  if l.parent_id is not null then
    if my is not null and my = l.parent_id then return 'up'; end if;
  elsif v2_is_ra() then
    return 'up';
  end if;
  return null;
end $$;

create or replace function v2_msg_own(p_id uuid) returns v2_messages
language plpgsql security definer set search_path = public as $$
declare m v2_messages%rowtype;
begin
  select * into m from v2_messages where id = p_id for update;
  if not found or m.sender_member_id is distinct from (v2_me()).id
     or v2_thread_side(m.application_id, m.thread_company_id) is null then
    raise exception 'not_sender' using errcode = 'P0403', hint = '自分のメッセージだけ編集・削除できます';
  end if;
  return m;
end $$;

create or replace function v2_msg_edit(p_id uuid, p_version int, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages := v2_msg_own(p_id);
begin
  if m.deleted or m.stamp is not null then raise exception 'not_editable' using errcode = 'P0400', hint = 'このメッセージは編集できません'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty' using errcode = 'P0400', hint = 'メッセージを入力してください'; end if;
  update v2_messages set body = trim(p_body), edited = true, version = m.version where id = p_id;
end $$;

create or replace function v2_msg_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages := v2_msg_own(p_id);
begin
  update v2_messages set deleted = true, body = null, stamp = null, reactions = '[]', pinned = false, version = m.version
  where id = p_id;
end $$;

create or replace function v2_msg_send(p_app uuid, p_thread uuid, p_body text, p_stamp text default null, p_reply_to uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s text := v2_thread_side(p_app, p_thread); v_id uuid; v_body text := nullif(trim(coalesce(p_body, '')), '');
begin
  if s is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りには書き込めません'; end if;
  if p_stamp is not null and p_stamp not in ('👍','🙏','🎉','💪','😄','🙇','✨','⭕','❌','⏰') then
    raise exception 'bad_stamp' using errcode = 'P0400', hint = 'このスタンプは使えません';
  end if;
  if (v_body is null) = (p_stamp is null) then
    raise exception 'empty' using errcode = 'P0400', hint = 'メッセージかスタンプのどちらか一方を送ってください';
  end if;
  if p_reply_to is not null and not exists (select 1 from v2_messages where id = p_reply_to and application_id = p_app and thread_company_id = p_thread) then
    raise exception 'bad_reply' using errcode = 'P0400';
  end if;
  insert into v2_messages(application_id, thread_company_id, sender_member_id, side, body, stamp, reply_to)
  values (p_app, p_thread, (v2_me()).id, s, v_body, p_stamp, p_reply_to) returning id into v_id;
  perform v2_thread_mark_read(p_app, p_thread);
  return v_id;
end $$;

-- ページ送りを (時刻, id) で区切る版に置き換え
drop function if exists v2_thread_messages(uuid, uuid, timestamptz, int);
create or replace function v2_thread_messages(p_app uuid, p_thread uuid, p_before timestamptz default null,
                                              p_before_id uuid default null, p_limit int default 200)
returns table (id uuid, side text, sender_name text, mine boolean, body text, stamp text, reply_to uuid,
               reactions jsonb, pinned boolean, edited boolean, deleted boolean, created_at timestamptz,
               read_by_other boolean, version int)
language plpgsql stable security definer set search_path = public as $$
declare my_side text := v2_thread_side(p_app, p_thread); me uuid := (v2_me()).id; other_read timestamptz;
begin
  if my_side is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りは見られません'; end if;
  select max(r.last_read_at) into other_read from v2_thread_reads r join v2_members mb on mb.id = r.member_id
  where r.application_id = p_app and r.thread_company_id = p_thread
    and ((my_side = 'self' and (mb.company_id is distinct from p_thread)) or (my_side = 'up' and mb.company_id = p_thread));
  return query
  select * from (
    select m.id, m.side, mb.name, m.sender_member_id = me,
      case when m.deleted then null else m.body end, case when m.deleted then null else m.stamp end,
      m.reply_to, case when m.deleted then '[]'::jsonb else m.reactions end, m.pinned, m.edited, m.deleted, m.created_at,
      (m.side = my_side and other_read is not null and other_read >= m.created_at), m.version
    from v2_messages m join v2_members mb on mb.id = m.sender_member_id
    where m.application_id = p_app and m.thread_company_id = p_thread
      and (p_before is null or (m.created_at, m.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by m.created_at desc, m.id desc limit least(greatest(p_limit, 1), 200)
  ) x order by x.created_at, x.id;
end $$;

-- 既に削除済みのメッセージから本文を消す
update v2_messages set body = null, stamp = null, reactions = '[]', pinned = false, version = version where deleted;

-- 公開範囲: 未ログイン（anon）と既定の公開（PUBLIC）からは閉じ、ログイン済み（authenticated）だけに開く
revoke all on function v2_thread_side(uuid, uuid), v2_my_threads(uuid), v2_chat_unread(),
  v2_thread_messages(uuid, uuid, timestamptz, uuid, int), v2_msg_send(uuid, uuid, text, text, uuid),
  v2_msg_own(uuid), v2_msg_edit(uuid, int, text), v2_msg_delete(uuid), v2_msg_react(uuid, text), v2_msg_pin(uuid, boolean),
  v2_thread_mark_read(uuid, uuid), v2_thread_mark_unread(uuid, uuid) from public, anon;
grant execute on function v2_thread_side(uuid, uuid), v2_my_threads(uuid), v2_chat_unread(),
  v2_thread_messages(uuid, uuid, timestamptz, uuid, int), v2_msg_send(uuid, uuid, text, text, uuid),
  v2_msg_edit(uuid, int, text), v2_msg_delete(uuid), v2_msg_react(uuid, text), v2_msg_pin(uuid, boolean),
  v2_thread_mark_read(uuid, uuid), v2_thread_mark_unread(uuid, uuid) to authenticated;
-- 表への直接の書き込み権限も外す（読み取りの権限＝RLSはそのまま）
revoke insert, update, delete, truncate on v2_messages, v2_thread_reads from anon, authenticated;
