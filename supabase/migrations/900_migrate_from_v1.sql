-- ============================================================
-- V1 → V2 データ移行（切替日に1回だけ実行する。通常のマイグレーションではない）
-- ・全体を1トランザクションで実行。最後の検証で件数が合わなければ ROLLBACK すれば無傷
-- ・V1テーブルは読み取りのみ（変更しない）
-- ・実行前提: V1を読み取り専用運用にしてから流す（並行書き込みを防ぐ）
-- ============================================================
begin;

-- ---------- 0) 旧ID→新UUID の対応表（トランザクション内のみ） ----------
create temp table map_agency  (v1_id text primary key, v2_id uuid not null default gen_random_uuid(), code text);
create temp table map_project (v1_id text primary key, v2_id uuid not null default gen_random_uuid());
create temp table map_referral(v1_id text primary key, v2_id uuid not null default gen_random_uuid());

insert into map_agency(v1_id) select id from agencies where id <> 'AG-DIAG-TEST';
insert into map_project(v1_id) select id from projects;
insert into map_referral(v1_id)
  select id from referrals
  union select 'intake:' || id from intake where status = 'pending';

-- 企業コードを参加日順に採番（A00001, A00002, ...）
update map_agency m set code = v2_next_code(1)
from (select v1_id, row_number() over (order by coalesce(a.joined, '9999-12-31'), a.id) rn
      from map_agency mm join agencies a on a.id = mm.v1_id) o
where o.v1_id = m.v1_id;

-- ---------- 1) agencies → companies（全社 tier=1 / Aライン） ----------
insert into companies (id, code, tier, parent_id, name, contact, email, phone, status,
                       legacy_pw_hash, must_change_pw, bank, license, special, source, joined_at)
select m.v2_id, m.code, 1, null, a.name, a.contact, a.email, null,
       case when a.status in ('active','suspended') then a.status else 'active' end,
       a.pw_hash,           -- 旧SHA-256ハッシュ。初回ログイン成功時に自動でbcrypt化される
       false,
       case when a.bank is not null then jsonb_build_object('text', a.bank) end,
       coalesce(a.license, false), a.special, a.source,
       nullif(a.joined, '')::timestamptz
from agencies a join map_agency m on m.v1_id = a.id;

-- ---------- 2) projects → projects_v2 ----------
insert into projects_v2 (id, name, client, logo, color, status, position, employment, salary,
                         location, summary, conditions, requirements, flow, reward_type,
                         referral_reward, success_reward, client_fee, headcount, seminar,
                         pass_note, case_study, detail)
select m.v2_id, p.name, p.client, p.logo, p.color,
       case when p.status in ('open','paused','closed') then p.status else 'open' end,
       p.position, p.employment, p.salary, p.location, p.summary, p.conditions,
       coalesce(p.requirements, '[]'::jsonb), coalesce(p.flow, '[]'::jsonb), p.reward_type,
       coalesce(p.referral_reward, 0), coalesce(p.success_reward, 0), coalesce(p.client_fee, 0),
       p.headcount, p.seminar, p.pass_note, p.case_study, p.detail
from projects p join map_project m on m.v1_id = p.id;

-- ---------- 3) assignments → project_shares（KANOA→Aライン公開） ----------
insert into project_shares (project_id, company_id, shared_by, published, ref_override, suc_override)
select mp.v2_id, ma.v2_id, null, coalesce(s.published, true), s.ref_override, s.suc_override
from assignments s
join map_project mp on mp.v1_id = s.project_id
join map_agency ma on ma.v1_id = s.agency_id;

-- ---------- 4) referrals → candidates（KANOA選考中）＋ steps 合成 ----------
insert into candidates (id, name, kana, phone, email, address, area, project_id,
                        registered_by, holder_id, stage, status, session, joined_on,
                        resigned, resigned_on, resign_fraud, resign_confirmed,
                        spi_status, compliance_status, fail_at, seen_kanoa, note)
select m.v2_id, r.name, r.kana, nullif(r.phone, ''), nullif(r.email, ''), r.address, r.area,
       mp.v2_id, ma.v2_id, null, 'screening',
       coalesce(r.status, 'entry'), r.session, nullif(r.joined_on::text, '')::date,
       coalesce(r.resigned, false), nullif(r.resigned_on::text, '')::date,
       coalesce(r.resign_fraud, false), coalesce(r.resign_confirmed, false),
       coalesce(r.spi_status, 'none'), coalesce(r.compliance_status, 'none'),
       r.fail_at, coalesce(r.seen_kanoa, true), r.note
from referrals r
join map_referral m on m.v1_id = r.id
join map_agency ma on ma.v1_id = r.agency_id
left join map_project mp on mp.v1_id = r.project_id;

-- 経路履歴を合成（登録→KANOA受入の2行。日時はV1に無いため移行時刻）
insert into candidate_steps (candidate_id, company_id, action, note)
select m.v2_id, ma.v2_id, 'registered', 'V1からの移行'
from referrals r join map_referral m on m.v1_id = r.id join map_agency ma on ma.v1_id = r.agency_id;
insert into candidate_steps (candidate_id, company_id, action, note)
select m.v2_id, null, 'accepted', 'V1からの移行'
from referrals r join map_referral m on m.v1_id = r.id;

-- ---------- 5) intake(pending) → candidates（KANOA判断待ちのリレー中） ----------
insert into candidates (id, name, kana, phone, email, address, area, project_id,
                        registered_by, holder_id, stage, status, note)
select m.v2_id, i.name, i.kana, nullif(i.phone, ''), nullif(i.email, ''), i.address, i.area,
       mp.v2_id, ma.v2_id, null, 'relay', null, i.note
from intake i
join map_referral m on m.v1_id = 'intake:' || i.id
join map_agency ma on ma.v1_id = i.agency_id
left join map_project mp on mp.v1_id = i.project_id
where i.status = 'pending';

insert into candidate_steps (candidate_id, company_id, action, note)
select m.v2_id, ma.v2_id, 'registered', 'V1からの移行（確認待ち）'
from intake i join map_referral m on m.v1_id = 'intake:' || i.id
join map_agency ma on ma.v1_id = i.agency_id
where i.status = 'pending';

-- ---------- 6) messages → messages_v2 ----------
insert into messages_v2 (company_id, sender, body, candidate_id, reactions, mentions,
                         stamp, pinned, edited, deleted, read, created_at)
select ma.v2_id,
       case when msg.sender = 'kanoa' then 'up' else 'self' end,
       msg.body, mr.v2_id,
       coalesce(msg.reactions, '[]'::jsonb), coalesce(msg.mentions, '[]'::jsonb),
       msg.stamp, coalesce(msg.pinned, false), coalesce(msg.edited, false),
       coalesce(msg.deleted, false), coalesce(msg.read, false),
       coalesce(msg.created_at, now())
from messages msg
join map_agency ma on ma.v1_id = msg.agency_id
left join map_referral mr on mr.v1_id = msg.ref_id
order by msg.created_at;

-- ---------- 7) invoices → invoices_v2 ----------
insert into invoices_v2 (no, company_id, status, items, subtotal, tax, total,
                         issued_on, submitted_on, decided_on, paid_on, reject_reason, history)
select v.no, ma.v2_id, coalesce(v.status, 'draft'), coalesce(v.items, '[]'::jsonb),
       coalesce(v.subtotal, 0), coalesce(v.tax, 0), coalesce(v.total, 0),
       nullif(v.issued_on::text, '')::date, nullif(v.submitted_on::text, '')::date,
       nullif(v.decided_on::text, '')::date, nullif(v.paid_on::text, '')::date,
       v.reject_reason, coalesce(v.history, '[]'::jsonb)
from invoices v join map_agency ma on ma.v1_id = v.agency_id;

-- ---------- 8) documents → documents_v2（storageパスは同一バケットのため変更不要） ----------
insert into documents_v2 (candidate_id, name, kind, size, mime, storage_path, uploaded_by, created_at)
select mr.v2_id, d.name, d.kind, d.size, d.mime, d.storage_path,
       ma.v2_id, coalesce(d.created_at, now())
from documents d
join map_referral mr on mr.v1_id = d.referral_id
left join map_agency ma on ma.v1_id = d.uploaded_by;

-- ---------- 9) tasks → tasks_v2 ----------
insert into tasks_v2 (owner, from_owner, company_id, candidate_id, body, done, due)
select coalesce(t.owner, 'kanoa'), coalesce(t.from_owner, t.owner, 'kanoa'),
       ma.v2_id, mr.v2_id, t.body, coalesce(t.done, false), nullif(t.due::text, '')::date
from tasks t
left join map_agency ma on ma.v1_id = t.agency_id
left join map_referral mr on mr.v1_id = t.ref_id;

-- ---------- 10) 検証（件数照合。合わなければ ROLLBACK; で全て無かったことにできる） ----------
select 'agencies→companies' as t, (select count(*) from agencies where id <> 'AG-DIAG-TEST') as v1,
       (select count(*) from companies c join map_agency m on m.v2_id = c.id) as v2
union all
select 'referrals+intake→candidates',
       (select count(*) from referrals) + (select count(*) from intake where status = 'pending'),
       (select count(*) from candidates c join map_referral m on m.v2_id = c.id)
union all
select 'projects', (select count(*) from projects), (select count(*) from projects_v2 p join map_project m on m.v2_id = p.id)
union all
select 'messages', (select count(*) from messages), (select count(*) from messages_v2 where created_at < now())
union all
select 'invoices', (select count(*) from invoices), (select count(*) from invoices_v2 v join map_agency m on m.v2_id = v.company_id);

-- 問題なければ手動で: commit;  合わなければ: rollback;
-- ※このファイルをそのまま流すと最後の select 後に commit されないため、
--    実行ツール側で BEGIN〜末尾までを1バッチとして流し、検証結果を見てから COMMIT すること。
