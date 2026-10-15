-- ============================================================
-- 第3段階: 選考（応募・送客/見送り・受入・辞退・外部求人・マイルストーン）
-- 状態を変える操作はすべて関数（RPC）経由。表を直接書き換えさせない
-- 権限判定は「行自身の列」または「別の表」で行う（2026-10-15 の失敗記録）
-- ============================================================
set check_function_bodies = off;

create table v2_applications (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references v2_candidates(id),
  kind text not null check (kind in ('internal','external')),
  job_id uuid references v2_jobs(id),
  external_url text, external_company text, external_title text, applied_on date,
  applied_by_company uuid references v2_companies(id),     -- 紹介した会社（null = KANOA）
  applied_by_member uuid references v2_members(id),
  holder_company_id uuid references v2_companies(id),      -- 送客の判断をする会社（null = KANOA）
  kanoa_visible boolean not null default false,            -- KANOAに届いた（またはKANOA自身の）選考
  stage text not null check (stage in ('relay','active','rejected','withdrawn','closed')),
  result text check (result in ('passed','failed')),
  memo text,                                               -- 外部求人の登録時メモ（登録した会社だけが見る）
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  constraint v2_app_kind check (
    (kind = 'internal' and job_id is not null) or
    (kind = 'external' and external_url is not null and job_id is null))
);
-- 同じ求職者を同じ社内求人に二重に応募させない（辞退・見送り後の再応募は可）
create unique index v2_app_dup on v2_applications(candidate_id, job_id)
  where kind = 'internal' and stage not in ('withdrawn','rejected');
create index v2_app_cand on v2_applications(candidate_id);
create index v2_app_holder on v2_applications(holder_company_id) where stage = 'relay';
create trigger v2_applications_touch before insert or update on v2_applications for each row execute function v2_touch();
create trigger v2_applications_audit after insert or update or delete on v2_applications for each row execute function v2_audit();

-- この選考を見てよい会社（応募した会社＋届いた会社。送客のたびに追加）
create table v2_application_parties (
  application_id uuid not null references v2_applications(id) on delete cascade,
  company_id uuid not null references v2_companies(id) on delete cascade,
  primary key (application_id, company_id)
);
create index v2_app_parties_company on v2_application_parties(company_id);

-- 経路と操作の記録
create table v2_application_events (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references v2_applications(id) on delete cascade,
  company_id uuid references v2_companies(id),   -- 操作した会社（null = KANOA）
  member_id uuid references v2_members(id),
  action text not null check (action in ('applied','forwarded','rejected','accepted','withdrawn','registered_external','milestone')),
  note text,
  created_at timestamptz not null default now()
);
create index v2_app_events_app on v2_application_events(application_id, created_at);

-- 選考フローの各段階
create table v2_milestones (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references v2_applications(id) on delete cascade,
  seq int not null,
  name text not null,
  scheduled_on date,
  done_on date,
  result text not null default 'pending' check (result in ('pending','passed','failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (application_id, seq)
);
create trigger v2_milestones_touch before insert or update on v2_milestones for each row execute function v2_touch();
create trigger v2_milestones_audit after insert or update or delete on v2_milestones for each row execute function v2_audit();

-- ---------- 見える範囲 ----------
create or replace function v2_app_visible(p_app uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from v2_application_parties p where p.application_id = p_app and p.company_id = v2_my_company())
      or (v2_is_ra() and exists (select 1 from v2_applications a where a.id = p_app and a.kanoa_visible))
$$;

-- 求職者は「自社の持ち物」に加えて「自社に届いた選考の求職者」も見える
create or replace function v2_cand_via_app(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from v2_applications a join v2_application_parties p on p.application_id = a.id
                 where a.candidate_id = p_cand and p.company_id = v2_my_company())
      or (v2_is_ra() and exists (select 1 from v2_applications a where a.candidate_id = p_cand and a.kanoa_visible))
$$;
create or replace function v2_can_view_candidate(p_cand uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select v2_can_edit_candidate(p_cand) or v2_cand_via_app(p_cand)
$$;
drop policy if exists v2_candidates_sel on v2_candidates;
create policy v2_candidates_sel on v2_candidates for select using (v2_owns(owner_company_id) or v2_cand_via_app(id));

-- ---------- 内部ヘルパー ----------
create or replace function v2_actor() returns record
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select id as member_id, company_id, role into r from v2_members where user_id = auth.uid() and status = 'active';
  if not found then raise exception 'not_authorized' using errcode = 'P0403', hint = 'ログインし直してください'; end if;
  return r;
end $$;

create or replace function v2_make_milestones(p_app uuid, p_flow jsonb) returns void
language sql security definer set search_path = public as $$
  insert into v2_milestones(application_id, seq, name)
  select p_app, ord::int, value from jsonb_array_elements_text(coalesce(p_flow, '[]')) with ordinality as t(value, ord)
$$;

-- ---------- 応募（社内求人） ----------
create or replace function v2_apply(p_candidate uuid, p_job uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me record; cand v2_candidates%rowtype; job v2_jobs%rowtype; v_holder uuid; v_id uuid; v_visible boolean;
begin
  me := v2_actor();
  select * into cand from v2_candidates where id = p_candidate;
  if not found or not v2_owns(cand.owner_company_id) then
    raise exception 'not_owner' using errcode = 'P0403', hint = '自社の求職者だけを応募できます';
  end if;
  select * into job from v2_jobs where id = p_job;
  if not found or job.status <> 'open' then
    raise exception 'job_unavailable' using errcode = 'P0403', hint = 'この求人は募集中ではありません';
  end if;
  if cand.owner_company_id is not null and not v2_job_visible(p_job, cand.owner_company_id) then
    raise exception 'job_unavailable' using errcode = 'P0403', hint = 'この求人はあなたの会社に提示されていません';
  end if;
  if exists (select 1 from v2_applications where candidate_id = p_candidate and job_id = p_job
             and kind = 'internal' and stage not in ('withdrawn','rejected')) then
    raise exception 'duplicate' using errcode = 'P0409', hint = 'この求職者はすでにこの求人に応募しています';
  end if;

  if cand.owner_company_id is null then
    -- KANOA自身の求職者: リレー無しでそのまま選考開始
    insert into v2_applications(candidate_id, kind, job_id, applied_by_company, applied_by_member,
                                holder_company_id, kanoa_visible, stage)
    values (p_candidate, 'internal', p_job, null, me.member_id, null, true, 'active') returning id into v_id;
    perform v2_make_milestones(v_id, job.flow);
  else
    select parent_id into v_holder from v2_companies where id = cand.owner_company_id;
    v_visible := v_holder is null;   -- 1次の応募は直接KANOAに届く
    insert into v2_applications(candidate_id, kind, job_id, applied_by_company, applied_by_member,
                                holder_company_id, kanoa_visible, stage)
    values (p_candidate, 'internal', p_job, cand.owner_company_id, me.member_id, v_holder, v_visible, 'relay')
    returning id into v_id;
    insert into v2_application_parties values (v_id, cand.owner_company_id);
    if v_holder is not null then insert into v2_application_parties values (v_id, v_holder); end if;
  end if;
  insert into v2_application_events(application_id, company_id, member_id, action, note)
  values (v_id, cand.owner_company_id, me.member_id, 'applied', p_note);
  return v_id;
end $$;

-- ---------- 送客 / 見送り（判断待ちの会社、またはKANOAに届いた選考はRA） ----------
create or replace function v2_relay_decide(p_app uuid, p_action text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me record; a v2_applications%rowtype; v_next uuid; job v2_jobs%rowtype;
begin
  me := v2_actor();
  select * into a from v2_applications where id = p_app for update;
  if not found or a.stage <> 'relay' then
    raise exception 'not_pending' using errcode = 'P0409', hint = 'この選考はすでに判断済みです。画面を読み込み直してください';
  end if;
  if a.holder_company_id is not null then
    if a.holder_company_id is distinct from me.company_id then
      raise exception 'not_holder' using errcode = 'P0403', hint = 'この選考を判断できるのは届いている会社だけです';
    end if;
  elsif not (me.role = 'ra' and a.kanoa_visible) then
    raise exception 'not_holder' using errcode = 'P0403', hint = 'この選考はKANOAが判断します';
  end if;

  if p_action = 'forward' then
    if a.holder_company_id is null then raise exception 'use_accept' using errcode = 'P0403', hint = 'KANOAは「受入」を使ってください'; end if;
    select parent_id into v_next from v2_companies where id = a.holder_company_id;
    update v2_applications set holder_company_id = v_next, kanoa_visible = (v_next is null), version = version where id = p_app;
    if v_next is not null then insert into v2_application_parties values (p_app, v_next) on conflict do nothing; end if;
    insert into v2_application_events(application_id, company_id, member_id, action, note)
    values (p_app, me.company_id, me.member_id, 'forwarded', p_note);
  elsif p_action = 'reject' then
    update v2_applications set stage = 'rejected', version = version where id = p_app;
    insert into v2_application_events(application_id, company_id, member_id, action, note)
    values (p_app, me.company_id, me.member_id, 'rejected', p_note);
  elsif p_action = 'accept' then
    if not (me.role = 'ra' and a.holder_company_id is null) then
      raise exception 'not_holder' using errcode = 'P0403', hint = '受入はKANOAだけが行えます';
    end if;
    select * into job from v2_jobs where id = a.job_id;
    update v2_applications set stage = 'active', version = version where id = p_app;
    perform v2_make_milestones(p_app, job.flow);
    insert into v2_application_events(application_id, company_id, member_id, action, note)
    values (p_app, null, me.member_id, 'accepted', p_note);
  else
    raise exception 'unknown_action: %', p_action;
  end if;
end $$;

-- ---------- 辞退（紹介した側） ----------
create or replace function v2_withdraw(p_app uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me record; a v2_applications%rowtype;
begin
  me := v2_actor();
  select * into a from v2_applications where id = p_app for update;
  if not found or not v2_owns(a.applied_by_company) then
    raise exception 'not_owner' using errcode = 'P0403', hint = '辞退できるのは紹介した会社だけです';
  end if;
  if a.stage not in ('relay','active') then
    raise exception 'not_open' using errcode = 'P0409', hint = 'この選考はすでに終わっています';
  end if;
  update v2_applications set stage = 'withdrawn', version = version where id = p_app;
  insert into v2_application_events(application_id, company_id, member_id, action, note)
  values (p_app, a.applied_by_company, me.member_id, 'withdrawn', p_note);
end $$;

-- ---------- 外部求人の登録（URL。リレーは通らず即「選考」。登録した会社の中だけに見える＝設計書Q1） ----------
create or replace function v2_register_external(p_candidate uuid, p_url text, p_company text, p_title text,
                                                p_applied_on date, p_flow jsonb, p_memo text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me record; cand v2_candidates%rowtype; v_id uuid;
begin
  me := v2_actor();
  select * into cand from v2_candidates where id = p_candidate;
  if not found or not v2_owns(cand.owner_company_id) then
    raise exception 'not_owner' using errcode = 'P0403', hint = '自社の求職者だけを登録できます';
  end if;
  if coalesce(trim(p_url), '') !~* '^https?://' then
    raise exception 'bad_url' using errcode = 'P0400', hint = 'URLは http:// または https:// から始まる形で入力してください';
  end if;
  if jsonb_array_length(coalesce(p_flow, '[]')) = 0 then
    raise exception 'no_flow' using errcode = 'P0400', hint = '選考フローを1段階以上入力してください';
  end if;
  insert into v2_applications(candidate_id, kind, external_url, external_company, external_title, applied_on,
                              applied_by_company, applied_by_member, holder_company_id, kanoa_visible, stage, memo)
  values (p_candidate, 'external', trim(p_url), nullif(trim(p_company), ''), nullif(trim(p_title), ''),
          coalesce(p_applied_on, current_date), cand.owner_company_id, me.member_id, null,
          cand.owner_company_id is null, 'active', p_memo)
  returning id into v_id;
  if cand.owner_company_id is not null then insert into v2_application_parties values (v_id, cand.owner_company_id); end if;
  perform v2_make_milestones(v_id, p_flow);
  insert into v2_application_events(application_id, company_id, member_id, action)
  values (v_id, cand.owner_company_id, me.member_id, 'registered_external');
  return v_id;
end $$;

-- ---------- マイルストーンの更新（社内求人=RAのみ／外部求人=登録した会社。設計書Q5） ----------
create or replace function v2_milestone_save(p_id uuid, p_version int, p_scheduled date, p_done date, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare me record; ms v2_milestones%rowtype; a v2_applications%rowtype; v_failed boolean; v_all boolean;
begin
  me := v2_actor();
  select * into ms from v2_milestones where id = p_id;
  if not found then raise exception 'not_found'; end if;
  select * into a from v2_applications where id = ms.application_id for update;
  if a.kind = 'internal' and not (me.role = 'ra' and a.kanoa_visible) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '社内求人の選考の進み具合はKANOAが更新します';
  end if;
  if a.kind = 'external' and not v2_owns(a.applied_by_company) then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '外部求人の選考は、登録した会社が更新します';
  end if;
  if a.stage not in ('active','closed') then
    raise exception 'not_open' using errcode = 'P0409', hint = 'この選考は進行中ではありません';
  end if;
  if p_result not in ('pending','passed','failed') then raise exception 'bad_result'; end if;
  update v2_milestones set scheduled_on = p_scheduled, done_on = p_done, result = p_result, version = p_version
  where id = p_id;   -- version が違えば v2_touch が衝突エラーにする
  -- 選考全体の状態を段階の結果から決める（不通過が1つ→終了・不通過／全段階通過→終了・通過）
  select bool_or(result = 'failed'), bool_and(result = 'passed') into v_failed, v_all
  from v2_milestones where application_id = a.id;
  update v2_applications set
    stage = case when v_failed or v_all then 'closed' else 'active' end,
    result = case when v_failed then 'failed' when v_all then 'passed' else null end,
    version = version
  where id = a.id;
  insert into v2_application_events(application_id, company_id, member_id, action, note)
  values (a.id, me.company_id, me.member_id, 'milestone',
          ms.name || '：' || case p_result when 'passed' then '通過' when 'failed' then '不通過' else '未定' end);
end $$;

-- ---------- 経路の記録（コメントは隣り合う会社のものだけ見せる。RAは全部） ----------
create or replace function v2_application_events_for(p_app uuid)
returns table (action text, company_id uuid, company_label text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare my uuid := v2_my_company(); ra boolean := v2_is_ra(); my_parent uuid;
begin
  if not v2_app_visible(p_app) then return; end if;
  select parent_id into my_parent from v2_companies where id = my;
  return query
  select e.action, e.company_id,
    case when e.company_id is null then 'KANOA'
         when e.company_id = my then '自社'
         when ra or co.parent_id = my then co.name || '（' || co.code || '）'
         when e.company_id = my_parent then 'アップライン'
         else 'パートナー' end,
    case when ra or e.company_id is not distinct from my
           or e.company_id = my_parent or co.parent_id = my
           or (e.company_id is null and my_parent is null)   -- KANOAのコメントは1次にだけ
         then e.note else null end,
    e.created_at
  from v2_application_events e left join v2_companies co on co.id = e.company_id
  where e.application_id = p_app order by e.created_at;
end $$;

-- ---------- 選考一覧（タブ・検索・ページング。権限は呼び出した本人のまま） ----------
create or replace function v2_selection_list(p_tab text, p_q text default '', p_limit int default 50, p_offset int default 0)
returns table (id uuid, kind text, stage text, result text, candidate_id uuid, candidate_name text,
               job_title text, client_name text, external_url text, source_label text, waiting_me boolean,
               holder_is_kanoa boolean, milestones jsonb, updated_at timestamptz, total bigint)
language sql stable security invoker set search_path = public as $$
  with me as (select v2_my_company() cid, v2_is_ra() ra),
  base as (
    select a.*, c.name as cand_name,
           coalesce(j.title, a.external_title, '（求人名なし）') as jt,
           coalesce(cl.name, a.external_company, '') as cn,
           (a.stage = 'relay' and ((me.ra and a.holder_company_id is null) or a.holder_company_id = me.cid)) as wait_me,
           me.ra as is_ra, me.cid as my_cid
    from v2_applications a
    join v2_candidates c on c.id = a.candidate_id
    left join v2_jobs j on j.id = a.job_id
    left join v2_clients cl on cl.id = j.client_id
    cross join me
    where case when p_tab = 'mine'
               then (case when me.ra then a.applied_by_company is null else a.applied_by_company = me.cid end)
               else (case when me.ra then a.applied_by_company is not null and a.kanoa_visible
                          else a.applied_by_company is distinct from me.cid end) end
  ), hit as (
    select * from base where coalesce(p_q, '') = '' or cand_name ilike '%' || p_q || '%' or jt ilike '%' || p_q || '%' or cn ilike '%' || p_q || '%'
  )
  select h.id, h.kind, h.stage, h.result, h.candidate_id, h.cand_name, h.jt, h.cn, h.external_url,
    (select co.name || '（' || co.code || '）' from v2_application_parties p join v2_companies co on co.id = p.company_id
      where p.application_id = h.id and (case when h.is_ra then co.tier = 1 else co.parent_id = h.my_cid end) limit 1),
    h.wait_me, h.holder_company_id is null,
    (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'result', m.result, 'scheduled_on', m.scheduled_on, 'done_on', m.done_on) order by m.seq), '[]')
       from v2_milestones m where m.application_id = h.id),
    h.updated_at, count(*) over ()
  from hit h order by h.wait_me desc, h.updated_at desc
  limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
$$;

-- ============================================================
-- RLS（読み取りのみ。書き込みは上の関数だけ）
-- ============================================================
alter table v2_applications enable row level security;
alter table v2_application_parties enable row level security;
alter table v2_application_events enable row level security;
alter table v2_milestones enable row level security;

create policy v2_applications_sel on v2_applications for select using (
  exists (select 1 from v2_application_parties p where p.application_id = v2_applications.id and p.company_id = v2_my_company())
  or (v2_is_ra() and kanoa_visible));
create policy v2_app_parties_sel on v2_application_parties for select using (v2_app_visible(application_id));
create policy v2_milestones_sel on v2_milestones for select using (v2_app_visible(application_id));
-- 経路の記録はコメントの出し分けがあるため、表は直接読ませず v2_application_events_for で読む

revoke all on function v2_actor(), v2_make_milestones(uuid, jsonb) from public, anon, authenticated;
grant execute on function v2_app_visible(uuid), v2_cand_via_app(uuid), v2_apply(uuid, uuid, text),
  v2_relay_decide(uuid, text, text), v2_withdraw(uuid, text),
  v2_register_external(uuid, text, text, text, date, jsonb, text),
  v2_milestone_save(uuid, int, date, date, text), v2_application_events_for(uuid),
  v2_selection_list(text, text, int, int) to authenticated;
