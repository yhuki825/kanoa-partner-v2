#!/usr/bin/env python3
"""V1→V2 移行の各手順（run_migration.sh から呼ぶ）
  snapshot              V1 の件数とハッシュ（読むだけ）を JSON で出す
  run [YYYY-MM-DD|-] [activate|-] [force|-] [discard]   DB の移行（v2_v1_migrate）を1トランザクションで流す
                        （force＝切替後でも流す／discard＝切替前だけ、お試し中の操作を捨てて作り直す）
  export                会社単位の V1 連絡（ref_id なし）を CSV に書き出す（決定3。migration/exports/ は Git に上げない）
  report <before> <after> <run> <copy> [tests]   照合レポート migration/reconciliation_<日付>.md を作る（件数・金額だけ）
画面に出すのは件数・金額・V1 の ID だけ（個人情報は出さない）"""
import csv, datetime, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _mgmt import sql, lit  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SNAPSHOT_SQL = """
select json_build_object(
 'agencies', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from agencies t),
 'projects', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from projects t),
 'assignments', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by project_id,agency_id),''))) from assignments t),
 'referrals', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from referrals t),
 'documents', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from documents t),
 'intake', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from intake t),
 'messages', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from messages t),
 'notices', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from notices t),
 'tasks', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from tasks t),
 'reflog', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(t::text,'|' order by id),''))) from reflog t),
 'tracker_links', (select json_build_object('n',count(*)) from tracker_links),
 'kanoa_admins', (select json_build_object('n',count(*)) from kanoa_admins),
 'candidate_docs_objects', (select json_build_object('n',count(*),'bytes',coalesce(sum((metadata->>'size')::bigint),0),
     'md5',md5(coalesce(string_agg(name||':'||coalesce(metadata->>'eTag',''),'|' order by name),''))) from storage.objects where bucket_id='candidate-docs'),
 'v1_auth_users', (select json_build_object('n',count(*),'md5',md5(coalesce(string_agg(id::text||coalesce(encrypted_password,'')||coalesce(email,''),'|' order by id),'')))
     from auth.users where email like '%@partner.kanoa.local')
) s"""


def snapshot():
    print(json.dumps(sql(SNAPSHOT_SQL)[0]['s'], ensure_ascii=False))


def run(joined_until, activate, force=False, discard=False):
    ju = 'null' if joined_until in (None, '', '-') else lit(joined_until) + '::date'
    b = lambda x: 'true' if x else 'false'
    res = sql(f'select v2_v1_migrate({ju}, {b(activate)}, {b(force)}, {b(discard)}) r')[0]['r']
    trig = sql("select count(*) n from pg_trigger tg join pg_class c on c.oid = tg.tgrelid "
               "where not tg.tgisinternal and c.relname like 'v2\\_%' and tg.tgenabled <> 'O'")[0]['n']
    res['disabled_triggers_after_run'] = trig
    print(json.dumps(res, ensure_ascii=False))
    return 1 if trig else 0


def export():
    rows = sql("select coalesce(a.code, m.agency_id) agency_code, coalesce(a.name, '') agency_name, m.sender, m.body, "
               "to_char(m.created_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') created_at_jst "
               "from messages m left join agencies a on a.id = m.agency_id where m.ref_id is null order by m.created_at, m.id")
    out = os.path.join(ROOT, 'migration/exports/v1_company_messages.csv')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', newline='', encoding='utf-8-sig') as f:   # Excel で文字化けしないよう BOM 付き
        w = csv.writer(f)
        w.writerow(['agency_code', 'agency_name', 'sender', 'body', 'created_at'])
        for r in rows:
            w.writerow([r['agency_code'], r['agency_name'], r['sender'], r['body'], r['created_at_jst']])
    print(json.dumps({'company_level_messages_exported': len(rows), 'file': 'migration/exports/v1_company_messages.csv'}))


def _n(x):
    return f'{x:,}' if isinstance(x, (int, float)) else str(x)


def report(before_f, after_f, run_f, copy_f, tests_f=None):
    before, after = json.load(open(before_f)), json.load(open(after_f))
    runs = json.load(open(run_f)); copy = json.load(open(copy_f))
    rc = sql('select v2_v1_reconcile() r')[0]['r']
    v1, v2, acct = rc['v1'], rc['v2'], rc['accounting']
    today = datetime.date.today().isoformat()
    L = []
    a = L.append
    a(f'# V1 → V2 移行 照合レポート（お試し移行）{today}')
    a('')
    a('件数と金額だけを載せています（氏名・連絡先などの個人情報は載せていません）。V1 の ID は照合のためにそのまま載せています。')
    a(f'生成: {rc["generated_at"]} ／ 入社の扱い: V1 の入社日が {v1["joined_rule"]["joined_until"]} 以前なら「入社」'
      f' ／ 代表CA: {"利用中" if runs.get("members_active") else "停止（お試し中は V2 にログインできない）"}')
    a('')
    a('## 1. 照合（V1 と V2）')
    a('')
    a('| 項目 | V1 | V2 | 一致 | 補足 |')
    a('|---|---:|---:|:-:|---|')

    def row(name, x, y, note='', ok=None):
        okv = (x == y) if ok is None else ok
        a(f'| {name} | {_n(x)} | {_n(y)} | {"○" if okv else "×"} | {note} |')
    row('会社（agencies → v2_companies）', v1['agencies'] - acct['agency']['skipped'], v2['companies'], f'V1 全 {v1["agencies"]} 社のうち {acct["agency"]["skipped"]} 社は決定5で対象外')
    row('代表CA（V1 のログイン用アカウントがある会社 → v2_members）', v1['agencies_migratable_with_auth'], v2['owner_members_by_code'],
        '会社コード経由で数えた。状態: ' + ', '.join(f'{k} {v}' for k, v in (v2['owner_members'] or {}).items()))
    row('求人（projects → v2_jobs）', v1['projects'], v2['jobs'], f'求人企業 {v2["clients"]} 社に集約')
    row('紹介料の合計（success_reward → v2_job_kanoa_fees）', v1['sum_success_reward'], v2['sum_job_kanoa_fee'], '円・税抜')
    row('公開（assignments → v2_job_shares）', v1['assignments'] - acct['assignment']['skipped'], v2['shares'], f'対象外の会社の {acct["assignment"]["skipped"]} 行を除く')
    row('　うち公開中', v1['assignments_published'], v2['shares_published'], '')
    row('会社ごとの紹介料の上書き合計（suc_override → fee_override）', v1['sum_suc_override'], v2['sum_fee_override'], '円')
    row('求職者（referrals → v2_candidates）', v1['referrals'], v2['candidates_from_referrals'], '')
    row('選考（referrals → v2_applications）', v1['referrals'], v2['applications'], '状態の対応は 3 章')
    pend = v1['intake_by_status'].get('pending', 0); dupi = v1['intake_pending_same_phone_same_agency']
    row('紹介フォームの確認待ち → 新しい求職者（選考なし）', pend - dupi, v2['candidates_from_intake'],
        f'V1 の確認待ち {pend} 件のうち、同じ会社に電話番号が同じ送客がある {dupi} 件を除いた数（V1 の表だけで計算）')
    row('　同じ人の送客がある確認待ち → その求職者にメモと添付を統合', dupi, v2['intake_merged'], '電話番号の重複を防ぐ制約のため、2人目は作らない')
    row('書類の行（documents → v2_candidate_files）', v1['documents'], v2['files_from_documents'], '')
    row('書類の大きさ合計（documents.size → v2_candidate_files.size）', v1['documents_bytes'], v2['files_from_documents_bytes'], 'バイト')
    row('書類の行（紹介フォームの添付を含む全体）', v2['files'], v2['files_in_storage'], 'V2 の行数 ／ v2-files に実物がある数')
    row('書類の実物の大きさ合計（v2-files）', v2['files_bytes'], v2['files_in_storage_bytes'], 'バイト。大きさの不一致 ' + _n(v2['files_size_mismatch']) + ' 件')
    row('連絡（ref_id あり → 選考のチャット）', v1['messages_with_ref'], v2['messages'], '')
    row('　KANOA の送信（sender=kanoa → side=up）', v1['messages_by_sender'].get('kanoa', 0), v2['messages_by_side'].get('up', 0), '')
    row('　パートナーの送信（sender=agency → side=self）', v1['messages_by_sender'].get('agency', 0), v2['messages_by_side'].get('self', 0), '')
    row('会社単位の連絡（ref_id なし → CSV）', v1['messages_company_level'], copy.get('_export', {}).get('company_level_messages_exported', v1['messages_company_level']), '決定3。migration/exports/v1_company_messages.csv（Git 対象外）')
    row('お知らせ', v1['notices'], v2['notices'], '')
    jr = v1['joined_rule']
    row('報酬の件数（入社 → v2_rewards）', jr['count'], v2['rewards'], f'V1 で入社日が入っているのは {jr["joined_on_set_total"]} 件（5 章）')
    row('報酬の金額合計（税抜）', jr['fee_total'], v2['rewards_fee_total'], '円。すべて支払待ち（V1 に支払の記録なし）')
    row('求人の文章に紹介料・返金の語（全パートナーに読める項目。0 であること）', 0, v2['job_text_fee_word_hits'],
        '求人名・業務内容・その他の条件・付帯情報を検査')
    a('')
    a('### 会社ごと（会社コード経由。移行の記録を通さずに数えた）')
    a('')
    a('| V2 企業コード | V1 送客 | V2 選考 | 一致 | V1 送客＋確認待ち（重複除く） | V2 求職者 | 一致 |')
    a('|---|---:|---:|:-:|---:|---:|:-:|')
    for x in rc.get('per_agency') or []:
        a(f'| {x["code"]} | {x["v1_referrals"]} | {x["v2_applications"]} | {"○" if x["v1_referrals"] == x["v2_applications"] else "×"} '
          f'| {x["v1_expected_candidates"]} | {x["v2_candidates"]} | {"○" if x["v1_expected_candidates"] == x["v2_candidates"] else "×"} |')
    a('')
    a('## 2. V1 の全行の行き先（移した／意図して移さない／止まった）')
    a('')
    a('| V1 の表 | V1 行数 | 移した | 移さない | 止まった | 未確認 |')
    a('|---|---:|---:|---:|---:|---:|')
    for k in ['agency', 'project', 'assignment', 'referral', 'intake', 'document', 'message', 'notice', 'reflog', 'task', 'tracker_link']:
        x = acct[k]
        a(f'| {k} | {_n(x["v1"])} | {_n(x["migrated"])} | {_n(x["skipped"])} | {_n(x["failed"])} | {_n(x["unaccounted"])} |')
    a('')
    a('移さない理由: agency＝決定5（KA999・RE999）／assignment＝その2社の公開行／intake＝承認済み（すでに送客）・見送り（決定4）'
      '／message＝会社単位の連絡（決定3・CSV へ）／task・tracker_link＝設計で作らない機能。reflog（V1 の操作履歴）は選考の経路の記録へ移した。')
    a('')
    a('移行の対象にしていない V1 の表（件数のみ）: login_logs・kanoa_admins（RA は 102 で登録済み）・invoices・subaccounts・members・「KANOA partner」')
    a('')
    a('## 3. 選考の状態の対応（件数）')
    a('')
    a('| V1 status | V1 fail_at | 入社日あり | V2 stage/result | 件数 |')
    a('|---|---|:-:|---|---:|')
    for x in rc['status_crosstab']:
        a(f'| {x["v1_status"]} | {x["v1_fail_at"] or "—"} | {"○" if x["v1_joined"] else ""} | {x["v2"]} | {_n(x["n"])} |')
    a('')
    a(f'V2 の状態別: ' + ' ／ '.join(f'{k} {_n(v)}' for k, v in sorted(v2['applications_by_stage'].items())))
    a(f'／ 段階（v2_milestones）{_n(v2["milestones"])} 行 ／ 経路の記録 {_n(v2["events"])} 行')
    a('')
    a('## 4. 止まった行・注意が要る行（理由）')
    a('')
    ex = [e for e in rc['exceptions'] if not (e['kind'] == 'assignment')]
    a('| 種類 | V1 ID | 状態 | 理由 |')
    a('|---|---|---|---|')
    for e in ex:
        a(f'| {e["kind"]} | {e["v1_id"]} | {e["status"]} | {e["reason"]} |')
    a(f'| assignment | （{acct["assignment"]["skipped"]} 行） | skipped | 対象外の会社（KA999・RE999）の公開行 |')
    a('')
    a('## 5. 報酬')
    a('')
    a(f'- 入社として移した: {_n(v2["rewards"])} 件 ／ 合計 {_n(v2["rewards_fee_total"])} 円（税抜）／ 支払待ち {_n(v2["rewards_pending"])} 件')
    a(f'- V1 で入社日が入っている送客は {jr["joined_on_set_total"]} 件。V1 の status はすべて offer のまま。入社日が {jr["joined_until"]} より後のものは'
      '「入社待ち」（最後の段階「入社」の予定日＝V1 の入社日）として移し、報酬はまだ作らない。その日を過ぎてから流し直すと報酬が作られる')
    a(f'- 返金規定を持つ求人: {v2["jobs_with_refund_policy"]} 件（V1 の文章から「◯か月以内 ◯%」を読み取り。経歴詐称の全額返金は V2 に項目が無いため対象外）')
    a(f'- V1 の client_fee（求人企業が KANOA に払う額）は V2 に置き場が無いため移していない。合計 {_n(v1["sum_client_fee"])} 円（求人4件分）')
    a(f'- V1 の送客報酬（referral_reward）合計 {_n(v1["sum_referral_reward"])} 円・会社ごとの上書き（ref_override）{v1["ref_override_set"]} 件 → V2 に送客報酬は無い（設計書14）')
    a('')
    a('## 6. 書類ファイルのコピー（candidate-docs → v2-files）')
    a('')
    cp = copy.get('_copy', copy)
    a(f'- コピー先の数 {_n(cp.get("expected"))} ／ 今回コピー {json.dumps(cp.get("copied"), ensure_ascii=False)} ／ コピー済みで飛ばした {_n(cp.get("already_copied_skipped"))}'
      f' ／ 失敗 {_n(cp.get("failed"))}')
    a(f'- V1 から消えた書類のコピーを消した {_n(cp.get("removed_stale_copies"))}（消すのはコピー済み台帳にあるものだけ）'
      f' ／ 台帳に無いファイル（触らない）{_n(cp.get("unknown_files_left_untouched"))}')
    a(f'- v2-files に実物がある {_n(cp.get("present_in_v2_files"))} 件・{_n(cp.get("present_bytes"))} バイト ／ 大きさの不一致 {_n(cp.get("size_mismatch"))} 件')
    a(f'- V1 の置き場 candidate-docs: {_n(v1["candidate_docs_objects"])} 件・{_n(v1["candidate_docs_bytes"])} バイト。うち documents から参照されていないもの {_n(v1["candidate_docs_unreferenced"])} 件'
      '（紹介フォームの添付の控え・削除済みの送客の書類など。移していない）')
    a('')
    a('## 7. 連絡（チャット）')
    a('')
    a(f'- 返信つき {_n(v2["messages_replies"])} ／ 編集済み {_n(v2["messages_edited"])} ／ リアクションつき {_n(v2["messages_with_reactions"])}（V1 の文字のリアクション「承知しました」等もそのまま）')
    a(f'- 既読: V1 の read をそのまま再現。未読として残るのは パートナー側 {_n(v2["unread_for_partners"])} 件・KANOA 側 {_n(v2["unread_for_kanoa"])} 件（スレッドの既読 {_n(v2["thread_reads"])} 行）')
    a('')
    a('## 8. V1 は読むだけだったことの確認（実行の前後）')
    a('')
    a('| V1 | 前 | 後 | 変化 |')
    a('|---|---:|---:|:-:|')
    for k in before:
        b, c = before[k], after.get(k, {})
        same = b == c
        a(f'| {k} | {_n(b.get("n"))} | {_n(c.get("n"))} | {"なし" if same else "あり（V1 は本番稼働中。件数・中身のハッシュが変わった）"} |')
    a('')
    a('## 9. 実行の記録')
    a('')
    a('```')
    a(json.dumps({k: runs[k] for k in runs if k != 'map'}, ensure_ascii=False))
    a('```')
    if tests_f and os.path.exists(tests_f):
        a('')
        a('## 10. V2 のテスト（移行後・順番に実行）')
        a('')
        # 件数だけを載せる（テストの出力の行そのものは載せない）
        import re
        a('| テスト | PASS | FAIL |')
        a('|---|---:|---:|')
        name = None
        for line in open(tests_f, encoding='utf-8'):
            line = line.strip()
            m0 = re.match(r'^=== (\S+)', line)
            if m0: name = m0.group(1); continue
            m1 = re.match(r'^PASS (\d+) / FAIL (\d+)$', line)
            m2 = re.search(r'問い合わせ (\d+)種 × (\d+)アカウント\s+FAIL (\d+)', line)
            if m1 and name: a(f'| {name} | {m1.group(1)} | {m1.group(2)} |')
            elif m2 and name: a(f'| {name} | {int(m2.group(1)) * int(m2.group(2)) - int(m2.group(3))} | {m2.group(3)} |')
    out = os.path.join(ROOT, f'migration/reconciliation_{today}.md')
    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(L) + '\n')
    print(json.dumps({'report': os.path.relpath(out, ROOT)}))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'snapshot':
        snapshot()
    elif cmd == 'run':
        sys.exit(run(sys.argv[2] if len(sys.argv) > 2 else None, len(sys.argv) > 3 and sys.argv[3] == 'activate',
                     len(sys.argv) > 4 and sys.argv[4] == 'force', len(sys.argv) > 5 and sys.argv[5] == 'discard'))
    elif cmd == 'export':
        export()
    elif cmd == 'report':
        report(*sys.argv[2:7])
    else:
        print(__doc__); sys.exit(2)
