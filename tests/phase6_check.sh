#!/usr/bin/env bash
# 第5段階（後半: 報酬・返金規定）のテスト。何度流してもよい
# 116（入社日の固定・日付の前後・1円単位・返金規定の楽観ロック・報酬の記録を残す）と 117（日本時間・入社日を動かさない・NaN/Infinityの拒否・外部求人）の確認も含む
# 前提（テストデータ）: 求人「テスト営業職（自動削除予定）」（A99999に公開・基本額300000円）、
#                       B社の「テスト次郎」の選考（B00001→A99999→KANOA、KANOA受入済み）
# 流れ: 最初に次郎の選考と報酬を決まった状態に戻す（このテストの行だけ）→ RAとして返金規定を設定し、段階を順に通過させて入社
#       → 見える範囲・権限・返金の計算・取り消しの制限を確かめる → 最後に次郎の選考を最初の状態に戻す
#       （既定では最後に次郎を「入社済み・支払待ち・退職なし」にして残す＝画面での確認用。消したいときは CLEAN_REWARD=1 bash tests/phase6_check.sh）
# 118（支払前の退職は支払額から差し引く。全額なら支払なし）と 119（支払った額の記録・表示と違う支払額の拒否・守りの制約）の確認も含む
set -u
cd "$(dirname "$0")/.."
source tests/.test-accounts.env
BASE=https://oicpfsfvywdhdriqehyr.supabase.co
AK=sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms
TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# 判定: 受け取る値は「名前・実際・期待」の3つちょうど。ずれていたら必ず不合格にする（引数ずれによる見逃し防止）
ok(){ if [ "$#" -ne 3 ]; then echo "FAIL  $1  （テストの書き方の誤り: 値が$#個）"; fail=$((fail+1)); return; fi
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  期待=[$3] 実際=[$2]"; fail=$((fail+1)); fi; }
# 問い合わせ用のJSON（bash 3.2 は $( ) の中の \" を正しく読めないため、引用符を入れ子にしない）
# 使い方: j キー 値 キー 値 …（値を = で始めると、数値・null・配列などをそのまま入れる）
j(){ python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps({a[i]:(json.loads(a[i+1][1:]) if a[i+1].startswith("=") else a[i+1]) for i in range(0,len(a),2)},ensure_ascii=False))' "$@"; }
login(){ curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "$(j email "$(echo "$1" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid" password "$2")" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))"; }
get(){ curl -s "$BASE/rest/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
rpc(){ curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
len(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 'ERR:'+str(d)[:80])"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') if isinstance(d,dict) else 'none')"; }
sql(){ python3 -c "import json,sys;print(json.dumps({'query':sys.argv[1]}))" "$1" > "$TMP/q.json"
  # 通信の一時的な失敗（接続エラー・429・5xx・空応答）だけ最大3回やり直す。SQLのエラー（400台）はそのまま返す
  local n=0 st
  while :; do
    st=$(curl -s -o "$TMP/r.json" -w '%{http_code}' -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json")
    n=$((n+1))
    case "$st" in 429|5??|000) ;; *) [ -s "$TMP/r.json" ] && break ;; esac
    [ $n -ge 3 ] && break; sleep $((n*2))
  done
  cat "$TMP/r.json"; }
# SQLの結果の1行目・1列目（エラーなら ERR:…）
first(){ python3 -c 'import json,sys;d=json.load(sys.stdin);print(list(d[0].values())[0] if isinstance(d,list) and d else "ERR:"+str(d)[:200])'; }
one(){ sql "$1" | first; }
# SQLのエラーコード（ERROR:  P0403: … の P0403）。エラーでなければ none
errc(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"ERROR:\s+([0-9A-Z]{5}):",d.get("message","")) if isinstance(d,dict) else None;print(m.group(1) if m else ("none" if isinstance(d,list) else "ERR:"+str(d)[:120]))'; }
# DOブロックの中で RESULT:値 として投げた値（中の変更はすべて取り消される）
result(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"RESULT:(\S+)",d.get("message","")) if isinstance(d,dict) else None;print(m.group(1) if m else "ERR:"+str(d)[:200])'; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); AC=$(login "$A_CA_ID" "$A_CA_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
ok "3アカウントでログインできる" "$([ -n "$A" ] && [ -n "$AC" ] && [ -n "$B" ] && echo y)" "y"
JIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
JOB=$(one "select id from v2_jobs where title='テスト営業職（自動削除予定）'")
BCO=$(one "select id from v2_companies where code='B00001'")
LAST=$(one "select max(seq) from v2_milestones where application_id='$JIRO'")
RAUID=$(one "select user_id from v2_members where role='ra' and status='active' limit 1")
CLAIMS=$(j sub "$RAUID" role authenticated)
AUID=$(one "select user_id from v2_members where login_id='A99999-01'")
CLAIMS_A=$(j sub "$AUID" role authenticated)
ACO=$(one "select id from v2_companies where code='A99999'")
# RAとして実行（ログイン中のRAと同じ権限の判定になる）
ra(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS',true); set local role authenticated; $1; commit;"; }
# A社の代表として実行
as_a(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; $1; commit;"; }
POL='[{"months":1,"rate":100},{"months":3,"rate":50}]'
POL_REV='[{"months":3,"rate":50},{"months":1,"rate":100}]'
POL6='[{"months":6,"rate":80}]'
POL1='[{"months":1,"rate":100}]'
# KANOA自身の求職者で入社まで進めて、報酬の行ができないことを確かめる。最後にわざとエラーで抜けるので、中の変更はすべて取り消される
KANOA_DO=$(cat <<'EOS'
do $$ declare c uuid; ap uuid; m record; n int; begin
  insert into v2_candidates(name) values ('一時テスト（取り消し）') returning id into c;
  ap := v2_apply(c, '__JOB__');
  for m in select id, version from v2_milestones where application_id = ap order by seq loop
    perform v2_milestone_save(m.id, m.version, current_date, current_date, 'passed');
  end loop;
  select count(*) into n from v2_rewards where application_id = ap;
  raise exception 'RESULT:%|%', (select stage || '/' || result from v2_applications where id = ap), n;
end $$
EOS
)
# 外部求人の選考（A社が花子で登録）で、最後の段階を実施日なしで「通過」にしても実施日は空のまま（106 のまま）。最後にわざとエラーで抜けて取り消す
EXT_DO=$(cat <<'EOS'
do $$ declare c uuid; ap uuid; m record; begin
  select id into c from v2_candidates where name = 'テスト花子';
  ap := v2_register_external(c, 'https://example.com/phase6-test', '一時テスト', '一時テスト', null, '["面接"]'::jsonb, null);
  select id, version into m from v2_milestones where application_id = ap and seq = 1;
  perform v2_milestone_save(m.id, m.version, null, null, 'passed');
  raise exception 'RESULT:%', coalesce((select done_on::text from v2_milestones where application_id = ap and seq = 1), 'null')
    || '/' || (select stage || '-' || result from v2_applications where id = ap);
end $$
EOS
)
# 次郎の段階を保存（RA）: ms 段階番号 日付（'YYYY-MM-DD' または null） 結果
# 返金規定の今の version（行が無ければ null）
PV="(select version from v2_job_refund_policies where job_id='$JOB')"
ms(){ local d="null"; [ "$2" != "null" ] && d="'$2'::date"
  ra "select v2_milestone_save(m.id, m.version, $d, $d, '$3') from v2_milestones m where m.application_id='$JIRO' and m.seq=$1"; }
# 予定日と実施日を別々に保存: msx 段階番号 予定日 実施日 結果（日付は 'YYYY-MM-DD' または null）
msx(){ local s="null" d="null"; [ "$2" != "null" ] && s="'$2'::date"; [ "$3" != "null" ] && d="'$3'::date"
  ra "select v2_milestone_save(m.id, m.version, $s, $d, '$4') from v2_milestones m where m.application_id='$JIRO' and m.seq=$1"; }
rew(){ one "select format('%s|%s|%s|%s', r.pay_status, r.fee_amount, r.joined_on, r.paid_on) from v2_rewards r where r.application_id='$JIRO'"; }
# 退職の記録: 返金率|返金・差し引き額|返金の状態|扱い（deduct=差し引き／refund=返金）|支払の状態
resign(){ ra "select format('%s|%s|%s|%s|%s', r.refund_rate, r.refund_amount, r.refund_status, r.refund_mode, r.pay_status) r from v2_reward_record_resignation('$JIRO', $1) r"; }
# 支払額（税抜。差し引きがあれば紹介料から引く）|支払の状態|扱い
# 支払済みにする（RA）: paid 支払日。画面と同じく「今の支払額」を確認用に送る
PAYX="(select fee_amount - coalesce(case when refund_mode='deduct' then refund_amount end, 0) from v2_rewards where application_id='$JIRO')"
paid(){ ra "select v2_reward_mark_paid('$JIRO', '$1', $PAYX)"; }
# 支払の記録: 支払の状態|支払日|実際に支払った額
paidamt(){ one "select format('%s|%s|%s', pay_status, paid_on, paid_amount) from v2_rewards where application_id='$JIRO'"; }
payable(){ one "select format('%s|%s|%s', fee_amount - coalesce(case when refund_mode='deduct' then refund_amount end, 0), pay_status, refund_mode) from v2_rewards where application_id='$JIRO'"; }
reset_jiro(){ sql "delete from v2_rewards where application_id='$JIRO';
  update v2_milestones set result='pending', done_on=null, scheduled_on=null, version=version where application_id='$JIRO' and seq>1;
  update v2_milestones set result='passed', done_on='2026-10-20', scheduled_on='2026-10-20', version=version where application_id='$JIRO' and seq=1;
  update v2_applications set stage='active', result=null, version=version where id='$JIRO';"; }

echo "== 準備（次郎の選考を決まった状態に戻す） =="
ok "次郎の選考と報酬を最初の状態に戻せた" "$(reset_jiro)" "[]"
ok "次郎の選考は進行中（段階は5つ）"       "$(one "select a.stage||'|'||$LAST from v2_applications a where a.id='$JIRO'")" "active|5"

echo "== 返金規定 =="
ok "RA: 返金規定を保存できる"               "$(ra "select (v2_job_refund_policy_save('$JOB', '$POL'::jsonb, $PV) = '$POL'::jsonb)::text r" | first)" "true"
ok "RA: 並び順が違っても月数の昇順で保存される" "$(ra "select (v2_job_refund_policy_save('$JOB', '$POL_REV'::jsonb, $PV) = '$POL'::jsonb)::text r" | first)" "true"
for bad in '{}' '[1]' '[{"months":0,"rate":50}]' '[{"months":1,"rate":101}]' '[{"months":1,"rate":-1}]' '[{"months":1.5,"rate":50}]' \
           '[{"months":1,"rate":50},{"months":1,"rate":20}]' '[{"months":1}]' '[{"months":"1","rate":50}]' '[{"months":1,"rate":50,"x":1}]'; do
  ok "RA: 形の違う返金規定は拒否される $bad" "$(ra "select v2_job_refund_policy_save('$JOB', '$bad'::jsonb, $PV)" | errc)" "P0400"
done
ok "古い version では返金規定を保存できない（P0409）" "$(ra "select v2_job_refund_policy_save('$JOB', '$POL6'::jsonb, $PV - 1)" | errc)" "P0409"
ok "規定があるのに version なしでは保存できない（P0409）" "$(ra "select v2_job_refund_policy_save('$JOB', '$POL6'::jsonb, null)" | errc)" "P0409"
ok "拒否された後も返金規定は元のまま"       "$(one "select (policy = '$POL'::jsonb)::text from v2_job_refund_policies where job_id='$JOB'")" "true"
ok "1次（A社）は返金規定を変更できない"     "$(rpc "$A" v2_job_refund_policy_save "$(j p_job "$JOB" p_policy "=$POL" p_version '=null')" | code)" "P0403"
ok "未ログインでは返金規定の関数を呼べない" "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_job_refund_policy_save" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_job "$JOB" p_policy "=$POL" p_version '=null')" | code)" "42501"
ok "返金規定の表を直接書き換えられない"     "$(curl -s -X POST "$BASE/rest/v1/v2_job_refund_policies" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j job_id "$JOB" policy '=[]')" | code)" "42501"
ok "1次（A社）はこの求人の返金規定を読める" "$(get "$A" "v2_job_refund_policies?select=job_id&job_id=eq.$JOB" | len)" "1"
ok "2次（B社）はこの求人の返金規定を読めない" "$(get "$B" "v2_job_refund_policies?select=job_id&job_id=eq.$JOB" | len)" "0"

echo "== 入社で報酬が記録される =="
ok "RA: 一次面接を通過"   "$(ms 2 2026-10-22 passed | errc)" "none"
ok "RA: 最終面接を通過"   "$(ms 3 2026-10-26 passed | errc)" "none"
ok "RA: 内定を通過"       "$(ms 4 2026-10-28 passed | errc)" "none"
ok "最後の段階の前は報酬の行が無い"          "$(one "select count(*) from v2_rewards where application_id='$JIRO'")" "0"
ok "RA: 入社（最後の段階）を通過"            "$(ms "$LAST" 2026-11-02 passed | errc)" "none"
ok "選考は終了・通過になる"                  "$(one "select stage||'|'||result from v2_applications where id='$JIRO'")" "closed|passed"
ok "報酬: 支払先A99999・税抜300000円・入社日・支払待ち" \
  "$(one "select format('%s|%s|%s|%s', co.code, r.fee_amount, r.joined_on, r.pay_status) from v2_rewards r join v2_companies co on co.id=r.payee_company_id where r.application_id='$JIRO'")" "A99999|300000|2026-11-02|pending"
ok "報酬: 入社時の返金規定が記録される"      "$(one "select (refund_policy = '$POL'::jsonb)::text from v2_rewards where application_id='$JIRO'")" "true"
ok "RA: 求人の返金規定を変更（固定の確認用）" "$(ra "select v2_job_refund_policy_save('$JOB', '$POL6'::jsonb, $PV)::text r" | errc)" "none"
ok "求人の返金規定を変えても、記録済みの報酬の規定は変わらない" "$(one "select (refund_policy = '$POL'::jsonb)::text from v2_rewards where application_id='$JIRO'")" "true"
ok "RA: 求人の返金規定を元に戻す"            "$(ra "select (v2_job_refund_policy_save('$JOB', '$POL'::jsonb, $PV) = '$POL'::jsonb)::text r" | first)" "true"
ok "求人の紹介料を変えても、記録済みの報酬の額は変わらない（変更は取り消す）" \
  "$(sql "begin; update v2_job_kanoa_fees set fee=999999, version=version where job_id='$JOB'; select fee_amount::text r from v2_rewards where application_id='$JIRO'; rollback;" | first)" "300000"
ok "KANOA自身の求職者は入社しても報酬の行ができない（中の変更は取り消す）" \
  "$(ra "${KANOA_DO//__JOB__/$JOB}" | result)" "closed/passed|0"

echo "== 入社日の修正と、入社の取り消し（支払前） =="
ok "RA: 入社日を直す（最後の段階の実施日）"  "$(ms "$LAST" 2026-11-03 passed | errc)" "none"
ok "報酬の入社日も直る"                      "$(one "select joined_on from v2_rewards where application_id='$JIRO'")" "2026-11-03"
ok "RA: 入社日を元に戻す"                    "$(ms "$LAST" 2026-11-02 passed | errc)" "none"
ok "RA: 入社を未定に戻す（支払前・退職の記録なし）" "$(ms "$LAST" null pending | errc)" "none"
ok "支払前なら報酬の行は消える"              "$(one "select count(*) from v2_rewards where application_id='$JIRO'")" "0"
ok "選考は進行中に戻る"                      "$(one "select stage from v2_applications where id='$JIRO'")" "active"
ok "RA: もう一度入社（最後の段階）を通過"    "$(ms "$LAST" 2026-11-02 passed | errc)" "none"
ok "報酬の行がもう一度できる"                "$(rew)" "pending|300000|2026-11-02|"

echo "== 入社日の固定（116） =="
TODAY=$(one "select (now() at time zone 'Asia/Tokyo')::date")   # 日本時間の今日（DBの時刻はUTC）
ok "RA: 入社をいったん未定に戻す"            "$(ms "$LAST" null pending | errc)" "none"
ok "RA: 入社を実施日なしで通過にする"        "$(msx "$LAST" null null passed | errc)" "none"
ok "実施日なしで通過 → 最後の段階の実施日に今日（日本時間）が入る" "$(one "select done_on from v2_milestones where application_id='$JIRO' and seq=$LAST")" "$TODAY"
ok "報酬の入社日も今日（日本時間）になる"                "$(one "select joined_on from v2_rewards where application_id='$JIRO'")" "$TODAY"
ok "RA: 別の段階（一次面接）の予定日を直す"  "$(msx 2 2026-10-23 2026-10-22 passed | errc)" "none"
ok "別の段階を直しても報酬の入社日は変わらない" "$(one "select joined_on from v2_rewards where application_id='$JIRO'")" "$TODAY"
ok "（116より前の形を再現: 入社日 2026-11-02・最後の段階の実施日なし）" \
  "$(sql "update v2_rewards set joined_on='2026-11-02', version=version where application_id='$JIRO'; update v2_milestones set done_on=null, version=version where application_id='$JIRO' and seq=$LAST;")" "[]"
ok "RA: 別の段階（最終面接）を保存"          "$(msx 3 2026-10-27 2026-10-26 passed | errc)" "none"
ok "別の段階の保存では、入社日が今日にずれない" "$(one "select joined_on from v2_rewards where application_id='$JIRO'")" "2026-11-02"
ok "RA: 最後の段階の実施日を 2026-11-02 に戻す" "$(ms "$LAST" 2026-11-02 passed | errc)" "none"
ok "報酬は元のまま（支払待ち・入社日 2026-11-02）" "$(rew)" "pending|300000|2026-11-02|"
ok "RA: 報酬があるときに、最後の段階を実施日なしで保存し直す" "$(msx "$LAST" null null passed | errc)" "none"
ok "保存し直しても入社日は動かない（今日にならない）" "$(rew)" "pending|300000|2026-11-02|"
ok "最後の段階の実施日には入社日が入る"      "$(one "select done_on from v2_milestones where application_id='$JIRO' and seq=$LAST")" "2026-11-02"
ok "外部求人: 最後の段階を実施日なしで通過にしても実施日は空のまま（中の変更は取り消す）" "$(as_a "$EXT_DO" | result)" "null/closed-passed"
ok "月末の入社（1/31）・規定 1か月以内100%: 2/28 の退職 → 100%（変更は取り消す）" \
  "$(sql "begin; update v2_rewards set joined_on='2026-01-31', refund_policy='$POL1'::jsonb, version=version where application_id='$JIRO'; select set_config('request.jwt.claims','$CLAIMS',true); set local role authenticated; select format('%s|%s', r.refund_rate, r.refund_amount) r from v2_reward_record_resignation('$JIRO', '2026-02-28') r; rollback;" | first)" "100|300000"
ok "月末の入社（1/31）・規定 1か月以内100%: 3/1 の退職 → 0%（変更は取り消す）" \
  "$(sql "begin; update v2_rewards set joined_on='2026-01-31', refund_policy='$POL1'::jsonb, version=version where application_id='$JIRO'; select set_config('request.jwt.claims','$CLAIMS',true); set local role authenticated; select format('%s|%s', r.refund_rate, r.refund_amount) r from v2_reward_record_resignation('$JIRO', '2026-03-01') r; rollback;" | first)" "0|0"
ok "取り消した後も報酬は元のまま"            "$(one "select format('%s|%s|%s', joined_on, (refund_policy = '$POL'::jsonb)::text, resigned_on) from v2_rewards where application_id='$JIRO'")" "2026-11-02|true|"

echo "== 金額は1円単位（116） =="
ok "紹介料（基本額）に小数は入らない"        "$(sql "update v2_job_kanoa_fees set fee=300000.5, version=version where job_id='$JOB'" | errc)" "23514"
ok "会社ごとの紹介料に小数は入らない"        "$(sql "update v2_job_shares set fee_override=1000.5, version=version where job_id='$JOB'" | errc)" "23514"
ok "フロント向けの表示額に小数は入らない"    "$(sql "insert into v2_job_offers(job_id, company_id, fee_display) values ('$JOB', (select id from v2_companies where code='A99999'), 1.5)" | errc)" "23514"
ok "報酬の額に小数は入らない"                "$(sql "update v2_rewards set fee_amount=300000.5, version=version where application_id='$JIRO'" | errc)" "23514"
OFFER_BEFORE=$(one "select fee_display from v2_job_offers where job_id='$JOB' and company_id='$ACO'")
ok "1次（A社の代表）: フロント向けの表示額に NaN は入らない" "$(curl -s -X PATCH "$BASE/rest/v1/v2_job_offers?job_id=eq.$JOB&company_id=eq.$ACO" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j fee_display NaN)" | code)" "23514"
ok "1次（A社の代表）: フロント向けの表示額に Infinity は入らない" "$(curl -s -X PATCH "$BASE/rest/v1/v2_job_offers?job_id=eq.$JOB&company_id=eq.$ACO" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j fee_display Infinity)" | code)" "23514"
ok "拒否の後もフロント向けの表示額は元のまま" "$(one "select fee_display from v2_job_offers where job_id='$JOB' and company_id='$ACO'")" "$OFFER_BEFORE"
ok "紹介料（基本額）に NaN は入らない"       "$(sql "update v2_job_kanoa_fees set fee='NaN', version=version where job_id='$JOB'" | errc)" "23514"
ok "紹介料（基本額）に Infinity は入らない"  "$(sql "update v2_job_kanoa_fees set fee='Infinity', version=version where job_id='$JOB'" | errc)" "23514"
ok "紹介料（基本額）に1兆円以上は入らない"   "$(sql "update v2_job_kanoa_fees set fee=1000000000000, version=version where job_id='$JOB'" | errc)" "23514"
ok "小数の拒否の後も紹介料・報酬は元のまま"  "$(one "select format('%s|%s', (select fee from v2_job_kanoa_fees where job_id='$JOB'), (select fee_amount from v2_rewards where application_id='$JIRO'))")" "300000|300000"
ok "報酬が残っている選考は消せない（記録を残す）" "$(sql "begin; delete from v2_applications where id='$JIRO'; rollback;" | errc)" "23503"

echo "== 見える範囲 =="
ok "1次（A社の代表）は自社が支払先の報酬を読める" "$(get "$A" "v2_rewards?select=fee_amount,company:v2_companies!v2_rewards_payee_company_id_fkey(code)&application_id=eq.$JIRO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join("%s|%s" % (x["company"]["code"], x["fee_amount"]) for x in d) if isinstance(d,list) else "ERR")')" "A99999|300000"
ok "1次（A社の代表でないCA）も読める"        "$(get "$AC" "v2_rewards?select=application_id&application_id=eq.$JIRO" | len)" "1"
ok "2次（B社）は次郎の報酬を読めない"        "$(get "$B" "v2_rewards?select=application_id&application_id=eq.$JIRO" | len)" "0"
ok "2次（B社）に見える報酬の行は、B社が支払先のものだけ（＝1行も無い）" \
  "$(get "$B" 'v2_rewards?select=payee_company_id' | python3 -c "import json,sys;d=json.load(sys.stdin);print('OK' if isinstance(d,list) and all(x['payee_company_id']=='$BCO' for x in d) else 'NG:'+str(d)[:120])")" "OK"
ok "2次（B社）は選考から報酬をたどっても読めない" "$(get "$B" "v2_applications?select=id,reward:v2_rewards!v2_rewards_application_id_fkey(fee_amount)&id=eq.$JIRO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["reward"] if isinstance(d,list) and d else "ERR:"+str(d)[:120])')" "None"
ok "未ログインでは報酬が見えない"            "$(curl -s "$BASE/rest/v1/v2_rewards?select=application_id&application_id=eq.$JIRO" -H "apikey: $AK" | len)" "0"

echo "== 操作の権限 =="
ok "1次（A社）は支払済みにできない"          "$(rpc "$A" v2_reward_mark_paid "$(j p_app "$JIRO" p_paid_on 2026-11-30 p_expected_payable '=300000')" | code)" "P0403"
ok "1次（A社のCA）は支払済みにできない"      "$(rpc "$AC" v2_reward_mark_paid "$(j p_app "$JIRO" p_paid_on 2026-11-30 p_expected_payable '=300000')" | code)" "P0403"
ok "2次（B社）は支払済みにできない"          "$(rpc "$B" v2_reward_mark_paid "$(j p_app "$JIRO" p_paid_on 2026-11-30 p_expected_payable '=300000')" | code)" "P0403"
ok "1次（A社）は退職を記録できない"          "$(rpc "$A" v2_reward_record_resignation "$(j p_app "$JIRO" p_resigned_on 2026-11-22)" | code)" "P0403"
ok "1次（A社）は返金済みにできない"          "$(rpc "$A" v2_reward_mark_refunded "$(j p_app "$JIRO" p_refunded_on 2026-11-30)" | code)" "P0403"
ok "1次（A社）は支払済みを取り消せない"      "$(rpc "$A" v2_reward_unmark_paid "$(j p_app "$JIRO")" | code)" "P0403"
ok "未ログインでは支払済みの関数を呼べない"  "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_reward_mark_paid" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_app "$JIRO" p_paid_on 2026-11-30 p_expected_payable '=300000')" | code)" "42501"
ok "未ログインでは退職の関数を呼べない"      "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_reward_record_resignation" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_app "$JIRO" p_resigned_on 2026-11-22)" | code)" "42501"
ok "報酬の表を直接書き換えられない（更新）"  "$(curl -s -X PATCH "$BASE/rest/v1/v2_rewards?application_id=eq.$JIRO" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j pay_status paid paid_on 2026-11-30)" | code)" "42501"
ok "報酬の表に直接行を作れない"              "$(curl -s -X POST "$BASE/rest/v1/v2_rewards" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j application_id "$JIRO" fee_amount '=1')" | code)" "42501"
ok "書き換えの試みの後も報酬は変わらない"    "$(rew)" "pending|300000|2026-11-02|"

echo "== 退職の計算と、支払前の退職＝支払額から差し引き（118。入社 2026-11-02、規定 1か月以内100%・3か月以内50%） =="
ok "支払前・20日後の退職 → 100%・差し引き300000円・支払なし（返金の手続きなし）" "$(resign "'2026-11-22'::date" | first)" "100|300000||deduct|cancelled"
ok "支払前・ちょうど1か月後の退職 → 100%・支払なし" "$(resign "'2026-12-02'::date" | first)" "100|300000||deduct|cancelled"
ok "支払なしは支払済みにできない（P0409）"    "$(paid 2026-11-30 | errc)" "P0409"
ok "支払なしは返金済みにできない（P0409）"    "$(ra "select v2_reward_mark_refunded('$JIRO', '2026-12-10')" | errc)" "P0409"
ok "支払前・1か月と1日後の退職 → 50%・差し引き・支払待ちに戻る" "$(resign "'2026-12-03'::date" | first)" "50|150000||deduct|pending"
ok "支払前・2か月後の退職 → 50%・差し引き150000円・支払待ち" "$(resign "'2027-01-02'::date" | first)" "50|150000||deduct|pending"
ok "支払額（税抜）は 300000 − 150000 = 150000" "$(payable)" "150000|pending|deduct"
ok "支払前・4か月後の退職 → 0%・差し引きなし" "$(resign "'2027-03-02'::date" | first)" "0|0||deduct|pending"
ok "入社日より前の退職日は拒否される"         "$(resign "'2026-11-01'::date" | errc)" "P0400"
ok "退職の記録がある間は入社日を直せない"     "$(ms "$LAST" 2026-11-05 passed | errc)" "P0409"
ok "退職の記録がある間は入社を取り消せない"   "$(ms "$LAST" null pending | errc)" "P0409"
ok "RA: 支払前に20日後の退職を記録（支払なし）" "$(resign "'2026-11-22'::date" | first)" "100|300000||deduct|cancelled"
ok "RA: 支払なしから退職の記録を消すと支払待ちに戻る" "$(resign "null::date" | first)" "||||pending"
ok "差し引きも消え、全額の支払待ちに戻る"     "$(payable)" "300000|pending|"
ok "RA: 支払前に2か月後の退職を記録（差し引き150000円）" "$(resign "'2027-01-02'::date" | first)" "50|150000||deduct|pending"
ok "差し引き: 退職日より前の支払日は拒否される（P0400）" "$(paid 2026-11-30 | errc)" "P0400"
ok "表示と違う支払額（300000）では支払済みにできない（P0409）" "$(ra "select v2_reward_mark_paid('$JIRO', '2027-01-10', 300000)" | errc)" "P0409"
ok "RA: 差し引き後の額で支払済みにする（退職日のあと）" "$(paid 2027-01-10 | errc)" "none"
ok "支払済み（差し引き後の支払額 150000）"    "$(payable)" "150000|paid|deduct"
ok "実際に支払った額 150000 が記録される"     "$(paidamt)" "paid|2027-01-10|150000"
ok "差し引き後の額で支払済みのあとは、退職の記録を消せない（P0409）" "$(resign "null::date" | errc)" "P0409"
ok "差し引き後の額で支払済みのあとは、退職日を変えられない（P0409）" "$(resign "'2027-03-02'::date" | errc)" "P0409"
ok "拒否の後も差し引きと支払済みは変わらない" "$(payable)" "150000|paid|deduct"
ok "拒否の後も支払った額の記録は変わらない"   "$(paidamt)" "paid|2027-01-10|150000"
ok "RA: 差し引きのまま支払済みを取り消せる"   "$(ra "select v2_reward_unmark_paid('$JIRO')" | errc)" "none"
ok "支払待ちに戻り、差し引きは残る"           "$(payable)" "150000|pending|deduct"
ok "取り消すと支払日と支払った額も消える"     "$(paidamt)" "pending||"
ok "RA: 支払前に退職の記録を消す"             "$(resign "null::date" | first)" "||||pending"
ok "退職の記録を消すと返金・差し引きの記録も消える" "$(one "select format('%s|%s|%s|%s|%s', resigned_on, refund_rate, refund_amount, refund_status, refund_mode) from v2_rewards where application_id='$JIRO'")" "||||"
ok "返金・差し引き額が紹介料を超える行は作れない（119の制約）" \
  "$(sql "update v2_rewards set resigned_on=joined_on, refund_rate=100, refund_amount=fee_amount+1, refund_mode='refund', version=version where application_id='$JIRO'" | errc)" "23514"
ok "支払額が0円でないのに「支払なし」にはできない（制約）" \
  "$(sql "update v2_rewards set resigned_on=joined_on, refund_rate=50, refund_amount=150000, refund_mode='deduct', pay_status='cancelled', version=version where application_id='$JIRO'" | errc)" "23514"
ok "支払済みなのに支払った額が空の行は作れない（制約）" \
  "$(sql "update v2_rewards set pay_status='paid', paid_on='2026-11-30', version=version where application_id='$JIRO'" | errc)" "23514"
ok "制約で拒否された後も報酬は元のまま"       "$(rew)" "pending|300000|2026-11-02|"

echo "== 支払済みの後は入社を取り消せない =="
ok "支払日が入社日より前は拒否される（P0400）" "$(paid 2026-11-01 | errc)" "P0400"
ok "RA: 支払済みにする"                        "$(paid 2026-11-30 | errc)" "none"
ok "実際に支払った額 300000 が記録される"     "$(paidamt)" "paid|2026-11-30|300000"
ok "報酬は支払済み"                            "$(rew)" "paid|300000|2026-11-02|2026-11-30"
ok "支払済みの後は入社日（最後の段階の実施日）を直せない（P0409）" "$(ms "$LAST" 2026-11-05 passed | errc)" "P0409"
ok "支払済みでも、別の段階の予定日は直せる"   "$(msx 2 2026-10-21 2026-10-22 passed | errc)" "none"
ok "二重に支払済みにはできない"                "$(paid 2026-12-01 | errc)" "P0409"
ok "支払済みの後、入社を未定に戻せない（P0409）" "$(ms "$LAST" null pending | errc)" "P0409"
ok "支払済みの後、別の段階を不通過にできない（P0409）" "$(ms 2 2026-10-22 failed | errc)" "P0409"
ok "拒否の後も報酬は変わらない"                "$(rew)" "paid|300000|2026-11-02|2026-11-30"
ok "拒否の後も選考は終了・通過のまま、段階も通過のまま" "$(one "select a.stage||'|'||a.result||'|'||m.result||'|'||(select result from v2_milestones where application_id=a.id and seq=2) from v2_applications a join v2_milestones m on m.application_id=a.id and m.seq=$LAST where a.id='$JIRO'")" "closed|passed|passed|passed"
ok "RA: 支払済みを取り消せる（返金の記録なし）" "$(ra "select v2_reward_unmark_paid('$JIRO')" | errc)" "none"
ok "支払待ちに戻る"                            "$(rew)" "pending|300000|2026-11-02|"
ok "RA: もう一度支払済みにする"                "$(paid 2026-11-30 | errc)" "none"

echo "== 返金 =="
ok "RA: 支払済みのあとに4か月後の退職を記録 → 返金の扱い・返金0円" "$(resign "'2027-03-02'::date" | first)" "0|0||refund|paid"
ok "RA: 返金0円なら支払済みを取り消せる"       "$(ra "select v2_reward_unmark_paid('$JIRO')" | errc)" "none"
ok "取り消すと「支払前の退職＝差し引き」の扱いにそろう（支払待ち・支払った額なし）" \
  "$(one "select format('%s|%s|%s|%s|%s', refund_mode, refund_status, pay_status, paid_amount, refund_amount) from v2_rewards where application_id='$JIRO'")" "deduct||pending||0"
ok "RA: 退職の記録を消す"                      "$(resign "null::date" | first)" "||||pending"
ok "RA: もう一度支払済みにする（返金の確認用）" "$(paid 2026-11-30 | errc)" "none"
ok "RA: 支払済みのあとに20日後の退職を記録 → 返金の扱い（返金待ち）" "$(resign "'2026-11-22'::date" | first)" "100|300000|pending|refund|paid"
ok "返金の扱いでは支払額は変わらない（支払済み 300000）" "$(payable)" "300000|paid|refund"
ok "返金待ちの間は支払済みを取り消せない"      "$(ra "select v2_reward_unmark_paid('$JIRO')" | errc)" "P0409"
ok "返金日が支払日より前は拒否される（P0400）" "$(ra "select v2_reward_mark_refunded('$JIRO', '2026-11-29')" | errc)" "P0400"
ok "RA: 返金済みにする"                        "$(ra "select v2_reward_mark_refunded('$JIRO', '2026-12-10')" | errc)" "none"
ok "返金済み・返金日が記録される"              "$(one "select format('%s|%s', refund_status, refunded_on) from v2_rewards where application_id='$JIRO'")" "refunded|2026-12-10"
ok "返金済みの後は退職の記録を消せない"        "$(resign "null::date" | errc)" "P0409"
ok "返金済みの後は退職日を変えられない"        "$(resign "'2027-03-02'::date" | errc)" "P0409"
ok "返金済みの後は支払済みを取り消せない"      "$(ra "select v2_reward_unmark_paid('$JIRO')" | errc)" "P0409"
ok "1次（A社）から返金済みの記録が見える"      "$(get "$A" "v2_rewards?select=refund_status,refund_amount&application_id=eq.$JIRO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("%s|%s" % (d[0]["refund_status"], d[0]["refund_amount"]) if isinstance(d,list) and d else "ERR")')" "refunded|300000"

if [ "${CLEAN_REWARD:-}" != "1" ]; then
  # 画面で試せるように、次郎を「入社済み・支払待ち・退職なし」にして残す（次に流すときは最初に戻す）
  ok "後片付け（画面確認用に残す）: 次郎の選考をいったん最初の状態に戻した" "$(reset_jiro)" "[]"
  ok "RA: 一次面接を通過（画面確認用）" "$(ms 2 2026-10-22 passed | errc)" "none"
  ok "RA: 最終面接を通過（画面確認用）" "$(ms 3 2026-10-26 passed | errc)" "none"
  ok "RA: 内定を通過（画面確認用）"     "$(ms 4 2026-10-28 passed | errc)" "none"
  ok "RA: 入社を通過（画面確認用）"     "$(ms "$LAST" 2026-11-02 passed | errc)" "none"
  ok "画面確認用: 次郎の報酬は A99999 宛て・支払待ち・退職なしで残した" \
    "$(one "select format('%s|%s|%s|%s|%s|%s', co.code, r.joined_on, r.fee_amount, r.pay_status, r.resigned_on, r.paid_amount) from v2_rewards r join v2_companies co on co.id=r.payee_company_id where r.application_id='$JIRO'")" "A99999|2026-11-02|300000|pending||"
else
  ok "後片付け（CLEAN_REWARD=1）: 次郎の選考を最初の状態に戻した" "$(reset_jiro)" "[]"
fi
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
