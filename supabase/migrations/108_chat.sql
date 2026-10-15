-- ============================================================
-- 第4段階: 選考ごとのチャット（相手は直上と直下だけ）
-- スレッド = (選考, 下側の会社 L)。L と、その直上（L が1次なら KANOA）の2者だけが読み書きできる
-- 例: C社(2次)→A社(1次)→KANOA の選考 … (選考, C)=C⇔A ／ (選考, A)=A⇔KANOA
-- 書き込みはすべて関数経由。元に戻す手順: 108_chat.down.sql
-- ============================================================
set check_function_bodies = off;

create table v2_messages (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references v2_applications(id) on delete cascade,
  thread_company_id uuid not null references v2_companies(id) on delete cascade,
  sender_member_id uuid not null references v2_members(id),
  side text not null check (side in ('self','up')),       -- self = 下側の会社 / up = 上側（KANOA含む）
  body text check (char_length(body) <= 5000),
  stamp text check (char_length(stamp) <= 8),
  reply_to uuid references v2_messages(id) on delete set null,
  reactions jsonb not null default '[]',                    -- [{emoji, member_id}]
  pinned boolean not null default false,
  edited boolean not null default false,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  constraint v2_messages_content check (deleted or coalesce(nullif(trim(body), ''), stamp) is not null)
);
create index v2_messages_thread on v2_messages(application_id, thread_company_id, created_at);
create trigger v2_messages_touch before insert or update on v2_messages for each row execute function v2_touch();

-- 既読（人ごと・スレッドごと。「未読に戻す」は last_read_at を戻すだけ）
create table v2_thread_reads (
  application_id uuid not null references v2_applications(id) on delete cascade,
  thread_company_id uuid not null references v2_companies(id) on delete cascade,
  member_id uuid not null references v2_members(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (application_id, thread_company_id, member_id)
);

-- ---------- このスレッドでの自分の立場（null = 参加できない） ----------
-- 下側 L の会社のメンバー → 'self'（L がこの選考の当事者であること）
-- L の直上の会社のメンバー → 'up'（直上にもこの選考が届いていること）
-- L が1次なら RA → 'up'（KANOAに届いていること）
create or replace function v2_thread_side(p_app uuid, p_thread uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare my uuid := v2_my_company(); l record;
begin
  if exists (select 1 from v2_applications where id = p_app and kind = 'external') then return null; end if;
  select id, tier, parent_id into l from v2_companies where id = p_thread;
  if not found then return null; end if;
  if not exists (select 1 from v2_application_parties where application_id = p_app and company_id = p_thread) then
    return null;
  end if;
  if my is not null and my = p_thread then return 'self'; end if;
  if l.parent_id is not null then
    if my is not null and my = l.parent_id
       and exists (select 1 from v2_application_parties where application_id = p_app and company_id = my) then
      return 'up';
    end if;
  elsif v2_is_ra() and exists (select 1 from v2_applications where id = p_app and kanoa_visible) then
    return 'up';
  end if;
  return null;
end $$;

-- ---------- 自分が参加しているスレッド一覧（選考詳細の右側タブ用） ----------
create or replace function v2_my_threads(p_app uuid)
returns table (thread_company_id uuid, my_side text, partner_label text, unread bigint, last_read_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := (v2_me()).id;
begin
  return query
  select p.company_id, s.side,
    case when s.side = 'self'
         then coalesce((select up.name || '（' || up.code || '）' from v2_companies up where up.id = c.parent_id), 'KANOA')
         else c.name || '（' || c.code || '）' end,
    (select count(*) from v2_messages m where m.application_id = p_app and m.thread_company_id = p.company_id
       and m.side <> s.side and not m.deleted
       and m.created_at > coalesce((select r.last_read_at from v2_thread_reads r where r.application_id = p_app
                                    and r.thread_company_id = p.company_id and r.member_id = me), '-infinity')),
    (select r.last_read_at from v2_thread_reads r where r.application_id = p_app and r.thread_company_id = p.company_id and r.member_id = me)
  from v2_application_parties p
  join v2_companies c on c.id = p.company_id
  cross join lateral (select v2_thread_side(p_app, p.company_id) as side) s
  where p.application_id = p_app and s.side is not null
  order by (s.side = 'self') desc;   -- 「アップラインとの連絡」を先、「紹介元との連絡」を後に
end $$;

-- ---------- 未読の合計（一覧・ホーム・メニューのバッジ用） ----------
create or replace function v2_chat_unread()
returns table (application_id uuid, unread bigint)
language sql stable security definer set search_path = public as $$
  with me as (select (v2_me()).id mid),
  th as (
    select p.application_id, p.company_id as tid, v2_thread_side(p.application_id, p.company_id) as side
    from v2_application_parties p
    where p.company_id = v2_my_company()
       or p.company_id in (select id from v2_companies where parent_id = v2_my_company())
       or (v2_is_ra() and p.company_id in (select id from v2_companies where tier = 1))
  )
  select th.application_id, count(m.id)
  from th cross join me
  join v2_messages m on m.application_id = th.application_id and m.thread_company_id = th.tid
   and m.side <> th.side and not m.deleted
   and m.created_at > coalesce((select r.last_read_at from v2_thread_reads r where r.application_id = th.application_id
                                and r.thread_company_id = th.tid and r.member_id = me.mid), '-infinity')
  where th.side is not null
  group by th.application_id
$$;

-- ---------- メッセージの読み出し（相手の既読つき。古い順、最大200件ずつ） ----------
create or replace function v2_thread_messages(p_app uuid, p_thread uuid, p_before timestamptz default null, p_limit int default 200)
returns table (id uuid, side text, sender_name text, mine boolean, body text, stamp text, reply_to uuid,
               reactions jsonb, pinned boolean, edited boolean, deleted boolean, created_at timestamptz,
               read_by_other boolean, version int)
language plpgsql stable security definer set search_path = public as $$
declare my_side text := v2_thread_side(p_app, p_thread); me uuid := (v2_me()).id; other_read timestamptz;
begin
  if my_side is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りは見られません'; end if;
  -- 相手側の誰かが最後に読んだ時刻
  select max(r.last_read_at) into other_read from v2_thread_reads r join v2_members mb on mb.id = r.member_id
  where r.application_id = p_app and r.thread_company_id = p_thread
    and ((my_side = 'self' and (mb.company_id is distinct from p_thread)) or (my_side = 'up' and mb.company_id = p_thread));
  return query
  select * from (
    select m.id, m.side, mb.name, m.sender_member_id = me,
      case when m.deleted then null else m.body end, case when m.deleted then null else m.stamp end,
      m.reply_to, m.reactions, m.pinned, m.edited, m.deleted, m.created_at,
      (m.side = my_side and other_read is not null and other_read >= m.created_at), m.version
    from v2_messages m join v2_members mb on mb.id = m.sender_member_id
    where m.application_id = p_app and m.thread_company_id = p_thread
      and (p_before is null or m.created_at < p_before)
    order by m.created_at desc limit least(greatest(p_limit, 1), 200)
  ) x order by x.created_at;
end $$;

-- ---------- 書き込み ----------
create or replace function v2_msg_send(p_app uuid, p_thread uuid, p_body text, p_stamp text default null, p_reply_to uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s text := v2_thread_side(p_app, p_thread); v_id uuid;
begin
  if s is null then raise exception 'not_in_thread' using errcode = 'P0403', hint = 'このやり取りには書き込めません'; end if;
  if coalesce(nullif(trim(p_body), ''), p_stamp) is null then raise exception 'empty' using errcode = 'P0400', hint = 'メッセージを入力してください'; end if;
  if p_reply_to is not null and not exists (select 1 from v2_messages where id = p_reply_to and application_id = p_app and thread_company_id = p_thread) then
    raise exception 'bad_reply' using errcode = 'P0400';
  end if;
  insert into v2_messages(application_id, thread_company_id, sender_member_id, side, body, stamp, reply_to)
  values (p_app, p_thread, (v2_me()).id, s, nullif(trim(p_body), ''), p_stamp, p_reply_to) returning id into v_id;
  perform v2_thread_mark_read(p_app, p_thread);
  return v_id;
end $$;

create or replace function v2_msg_own(p_id uuid) returns v2_messages
language plpgsql stable security definer set search_path = public as $$
declare m v2_messages%rowtype;
begin
  select * into m from v2_messages where id = p_id;
  if not found or m.sender_member_id is distinct from (v2_me()).id then
    raise exception 'not_sender' using errcode = 'P0403', hint = '自分のメッセージだけ編集・削除できます';
  end if;
  return m;
end $$;

create or replace function v2_msg_edit(p_id uuid, p_version int, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages := v2_msg_own(p_id);
begin
  if m.deleted or m.stamp is not null then raise exception 'not_editable' using errcode = 'P0400'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty' using errcode = 'P0400', hint = 'メッセージを入力してください'; end if;
  update v2_messages set body = trim(p_body), edited = true, version = p_version where id = p_id;
end $$;

create or replace function v2_msg_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages := v2_msg_own(p_id);
begin
  update v2_messages set deleted = true, pinned = false, version = m.version where id = p_id;
end $$;

-- リアクション・ピン留めはスレッドの参加者なら誰でも（行ロックで同時押しでも消えない）
create or replace function v2_msg_react(p_id uuid, p_emoji text) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages%rowtype; me uuid := (v2_me()).id;
begin
  select * into m from v2_messages where id = p_id for update;
  if not found or v2_thread_side(m.application_id, m.thread_company_id) is null or m.deleted then
    raise exception 'not_in_thread' using errcode = 'P0403';
  end if;
  if p_emoji not in ('👍','✅','🙏','😄','🎉') then raise exception 'bad_emoji' using errcode = 'P0400'; end if;
  if m.reactions @> jsonb_build_array(jsonb_build_object('emoji', p_emoji, 'member_id', me)) then
    update v2_messages set reactions = (select coalesce(jsonb_agg(r), '[]') from jsonb_array_elements(m.reactions) r
                                        where not (r->>'emoji' = p_emoji and r->>'member_id' = me::text)), version = m.version
    where id = p_id;
  else
    update v2_messages set reactions = m.reactions || jsonb_build_array(jsonb_build_object('emoji', p_emoji, 'member_id', me)), version = m.version
    where id = p_id;
  end if;
end $$;

create or replace function v2_msg_pin(p_id uuid, p_pinned boolean) returns void
language plpgsql security definer set search_path = public as $$
declare m v2_messages%rowtype;
begin
  select * into m from v2_messages where id = p_id for update;
  if not found or v2_thread_side(m.application_id, m.thread_company_id) is null or m.deleted then
    raise exception 'not_in_thread' using errcode = 'P0403';
  end if;
  update v2_messages set pinned = p_pinned, version = m.version where id = p_id;
end $$;

-- 既読にする／未読に戻す（相手の最新メッセージの直前まで戻す）
create or replace function v2_thread_mark_read(p_app uuid, p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if v2_thread_side(p_app, p_thread) is null then raise exception 'not_in_thread' using errcode = 'P0403'; end if;
  insert into v2_thread_reads(application_id, thread_company_id, member_id, last_read_at)
  values (p_app, p_thread, (v2_me()).id, now())
  on conflict (application_id, thread_company_id, member_id) do update set last_read_at = now();
end $$;

create or replace function v2_thread_mark_unread(p_app uuid, p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s text := v2_thread_side(p_app, p_thread); latest timestamptz;
begin
  if s is null then raise exception 'not_in_thread' using errcode = 'P0403'; end if;
  select max(created_at) into latest from v2_messages
  where application_id = p_app and thread_company_id = p_thread and side <> s and not deleted;
  if latest is null then return; end if;
  insert into v2_thread_reads(application_id, thread_company_id, member_id, last_read_at)
  values (p_app, p_thread, (v2_me()).id, latest - interval '1 millisecond')
  on conflict (application_id, thread_company_id, member_id) do update set last_read_at = excluded.last_read_at;
end $$;

-- ============================================================
-- RLS（読み取りは参加者だけ。書き込みは上の関数だけ）
-- ============================================================
alter table v2_messages enable row level security;
alter table v2_thread_reads enable row level security;
create policy v2_messages_sel on v2_messages for select using (v2_thread_side(application_id, thread_company_id) is not null);
create policy v2_thread_reads_own on v2_thread_reads for select using (member_id = (v2_me()).id);

revoke all on function v2_msg_own(uuid) from public, anon, authenticated;
grant execute on function v2_thread_side(uuid, uuid), v2_my_threads(uuid), v2_chat_unread(),
  v2_thread_messages(uuid, uuid, timestamptz, int), v2_msg_send(uuid, uuid, text, text, uuid),
  v2_msg_edit(uuid, int, text), v2_msg_delete(uuid), v2_msg_react(uuid, text), v2_msg_pin(uuid, boolean),
  v2_thread_mark_read(uuid, uuid), v2_thread_mark_unread(uuid, uuid) to authenticated;

-- リアルタイム配信（読み取り権限＝上のRLSに従って届く）。V1の配信対象には触れない
alter publication supabase_realtime add table v2_messages;
