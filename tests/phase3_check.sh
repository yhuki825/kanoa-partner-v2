#!/usr/bin/env bash
# 第3段階（選考）の権限テスト。読み取り＋拒否の確認だけ（データは変えない）
# 前提（テストデータ）: B社の「テスト次郎」（KANOA受入済み・選考中）、「テスト三郎」（A社が送客→KANOA受入待ち）、
#                       A社の「テスト花子」（社内求人に応募→KANOA受入待ち／外部求人に登録→辞退）、B社の「テスト四郎」（A社の判断待ち）
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
login(){ curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "{\"email\":\"$(echo "$1" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid\",\"password\":\"$2\"}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))"; }
get(){ curl -s "$BASE/rest/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
rpc(){ curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
len(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 'ERR:'+str(d)[:80])"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') if isinstance(d,dict) else 'none')"; }
names(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(','.join(sorted(x[sys.argv[1]] for x in d)) if isinstance(d,list) else 'ERR')" "$1"; }
# 判定: 名前の一覧に「含むべき名前」がすべてあり、「含まない名前」が1つも無ければ OK
incl(){ python3 -c "import json,sys;d=json.load(sys.stdin);k=sys.argv[1];names={x[k] for x in d} if isinstance(d,list) else set();inc=[v for v in sys.argv[2].split(',') if v];exc=[v for v in sys.argv[3].split(',') if v];print('OK' if all(v in names for v in inc) and not any(v in names for v in exc) else 'NG:'+','.join(sorted(names)))" "$1" "$2" "${3:-}"; }
# 問い合わせ用のJSONを組み立てる（bash 3.2 は $( ) の中の \" を正しく読めないため、引用符を入れ子にしない）
# 使い方: j キー 値 キー 値 …（値を = で始めると、数値・null・配列などをそのまま入れる）
j(){ python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps({a[i]:(json.loads(a[i+1][1:]) if a[i+1].startswith("=") else a[i+1]) for i in range(0,len(a),2)},ensure_ascii=False))' "$@"; }
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
one(){ sql "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(list(d[0].values())[0])'; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
JIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
SABU=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト三郎'")
# 判断待ちの選考（A社が持っている）。権限の拒否は「判断済み」より先に確かめたいので、未判断のものを使う
SHIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト四郎' and a.stage='relay'")
EXT=$(one "select id from v2_applications where kind='external' limit 1")
JOB=$(one "select id from v2_jobs where title='テスト営業職（自動削除予定）'")
CJIRO=$(one "select id from v2_candidates where name='テスト次郎'")

echo "== 見える範囲 =="
ok "B社: 自社で紹介した選考に次郎・三郎があり、A社の花子は無い" "$(rpc "$B" v2_selection_list '{"p_tab":"mine"}' | incl candidate_name テスト次郎,テスト三郎 テスト花子)" "OK"
ok "B社: 紹介された選考はない"                    "$(rpc "$B" v2_selection_list '{"p_tab":"received"}' | len)" "0"
ok "A社: 紹介された選考に次郎・三郎があり、自社の花子は無い" "$(rpc "$A" v2_selection_list '{"p_tab":"received"}' | incl candidate_name テスト次郎,テスト三郎 テスト花子)" "OK"
ok "A社: 自社で紹介した選考（花子の社内・外部）"  "$(rpc "$A" v2_selection_list '{"p_tab":"mine"}' | len)" "2"
ok "B社から見える選考の行はすべてB社が紹介したもの" "$(get "$B" 'v2_applications?select=applied_by_company' | python3 -c "import json,sys;print(len({x['applied_by_company'] for x in json.load(sys.stdin)}))")" "1"
ok "外部求人はフロント（B社）から見えない"         "$(get "$B" "v2_applications?select=id&id=eq.$EXT" | len)" "0"
ok "B社はA社の求職者（花子）を見られない"          "$(get "$B" 'v2_candidates?select=name' | incl name テスト次郎 テスト花子)" "OK"
ok "A社には届いた選考の求職者（次郎・三郎）も見える" "$(get "$A" 'v2_candidates?select=name' | incl name テスト次郎,テスト三郎,テスト花子)" "OK"
ok "A社からB社のメモは見えない"                    "$(get "$A" "v2_candidate_notes?select=memo&candidate_id=eq.$CJIRO" | len)" "0"
ok "B社から見た経路: KANOAのコメントは伏せられる"  "$(rpc "$B" v2_application_events_for "$(j p_app "$JIRO")" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="accepted"][0])')" "None"
ok "A社から見た経路: KANOAのコメントが見える"      "$(rpc "$A" v2_application_events_for "$(j p_app "$JIRO")" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="accepted"][0] is not None)')" "True"
ok "B社から見た経路: 段階の結果（事実）は見える"   "$(rpc "$B" v2_application_events_for "$(j p_app "$JIRO")" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="milestone"][0])')" "書類選考：通過"

echo "== 操作の権限 =="
ok "A社はB社の選考を辞退させられない"              "$(rpc "$A" v2_withdraw "$(j p_app "$JIRO")" | code)" "P0403"
ok "A社（1次）は受入できない（判断待ちの四郎で確認）"  "$(rpc "$A" v2_relay_decide "$(j p_app "$SHIRO" p_action "accept")" | code)" "P0403"
ok "B社は自分の選考を送客できない（判断はA社）"     "$(rpc "$B" v2_relay_decide "$(j p_app "$SHIRO" p_action "forward")" | code)" "P0403"
ok "社内求人の進み具合はCAが更新できない"           "$(rpc "$A" v2_milestone_save "$(j p_id "$(one "select id from v2_milestones where application_id='$JIRO' and seq=2")" p_version '=1' p_scheduled '=null' p_done '=null' p_result "passed")" | code)" "P0403"
ok "同じ求職者を同じ求人に二重応募できない"         "$(rpc "$B" v2_apply "$(j p_candidate "$CJIRO" p_job "$JOB")" | code)" "P0409"
ok "B社はA社の求職者を応募させられない"             "$(rpc "$B" v2_apply "$(j p_candidate "$(one "select id from v2_candidates where name='テスト花子'")" p_job "$JOB")" | code)" "P0403"
ok "選考の行を直接作れない"                         "$(curl -s -X POST "$BASE/rest/v1/v2_applications" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "$(j candidate_id "$CJIRO" kind "internal" job_id "$JOB" stage "active")" | code)" "42501"
ok "選考の状態を直接書き換えられない（0件更新）"   "$(curl -s -X PATCH "$BASE/rest/v1/v2_applications?id=eq.$JIRO" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"stage":"closed","result":"passed"}' | len)" "0"
ok "外部求人のURLは http(s) のみ"                  "$(rpc "$A" v2_register_external "$(j p_candidate "$(one "select id from v2_candidates where name='テスト花子'")" p_url "javascript:alert(1)" p_company "x" p_title "x" p_applied_on '=null' p_flow '=["面接"]')" | code)" "P0400"

RAUID=$(one "select user_id from v2_members where role='ra' limit 1")
ra(){ sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; $1; commit;"; }
ok "RA: 紹介された選考は次郎・三郎・花子（外部求人は見えない）" \
  "$(ra "select string_agg(l.candidate_name, ',' order by l.candidate_name) r from v2_selection_list('received', 'テスト', 200, 0) l join v2_applications a on a.id = l.id join v2_companies co on co.id = a.applied_by_company where co.code in ('A99999','B00001')" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "テスト三郎,テスト次郎,テスト花子"   # V1 から移行した選考も並ぶため、テスト用の会社の分に絞る
RECV=$(one "select count(*) from v2_applications where applied_by_company is not null and kanoa_visible")
ok "RA: 紹介された選考の総数がDBの実数と一致（KANOA自身の選考・KANOAに届いていない選考は含まない）" \
  "$(ra "select coalesce(max(total), 0) r from v2_selection_list('received', '', 1, 0)" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "$RECV"
EXPECT=$(one "select count(*) from v2_applications where stage='relay' and holder_company_id is null and kanoa_visible")
ok "RA: 受入待ちの件数がDBの実数と一致"             "$(ra "select v2_waiting_count() r" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "$EXPECT"
ok "RA: 外部求人の行は読めない"                     "$(ra "select count(*) r from v2_applications where kind='external'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
ok "RA: B社の求職者のメモは読めない"                "$(ra "select count(*) r from v2_candidate_notes where company_id is not null" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
