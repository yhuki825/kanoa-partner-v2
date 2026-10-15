#!/usr/bin/env bash
# 第3段階（選考）の権限テスト。読み取り＋拒否の確認だけ（データは変えない）
# 前提（テストデータ）: B社の「テスト次郎」（KANOA受入済み・選考中）、「テスト三郎」（A社が送客→KANOA受入待ち）、
#                       A社の「テスト花子」（社内求人に応募→KANOA受入待ち／外部求人に登録→辞退）
set -u
cd "$(dirname "$0")/.."
source tests/.test-accounts.env
BASE=https://oicpfsfvywdhdriqehyr.supabase.co
AK=sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms
TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  期待=[$3] 実際=[$2]"; fail=$((fail+1)); fi; }
login(){ curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "{\"email\":\"$(echo "$1" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid\",\"password\":\"$2\"}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))"; }
get(){ curl -s "$BASE/rest/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
rpc(){ curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
len(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 'ERR:'+str(d)[:80])"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') if isinstance(d,dict) else 'none')"; }
names(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(','.join(sorted(x[sys.argv[1]] for x in d)) if isinstance(d,list) else 'ERR')" "$1"; }
# 判定: 名前の一覧に「含むべき名前」がすべてあり、「含まない名前」が1つも無ければ OK
incl(){ python3 -c "import json,sys;d=json.load(sys.stdin);k=sys.argv[1];names={x[k] for x in d} if isinstance(d,list) else set();inc=[v for v in sys.argv[2].split(',') if v];exc=[v for v in sys.argv[3].split(',') if v];print('OK' if all(v in names for v in inc) and not any(v in names for v in exc) else 'NG:'+','.join(sorted(names)))" "$1" "$2" "${3:-}"; }
sql(){ python3 -c "import json,sys;print(json.dumps({'query':sys.argv[1]}))" "$1" > "$TMP/q.json"
  curl -s -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json"; }
one(){ sql "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(list(d[0].values())[0])'; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
JIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
SABU=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト三郎'")
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
ok "B社から見た経路: KANOAのコメントは伏せられる"  "$(rpc "$B" v2_application_events_for "{\"p_app\":\"$JIRO\"}" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="accepted"][0])')" "None"
ok "A社から見た経路: KANOAのコメントが見える"      "$(rpc "$A" v2_application_events_for "{\"p_app\":\"$JIRO\"}" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="accepted"][0] is not None)')" "True"
ok "B社から見た経路: 段階の結果（事実）は見える"   "$(rpc "$B" v2_application_events_for "{\"p_app\":\"$JIRO\"}" | python3 -c 'import json,sys;print([x["note"] for x in json.load(sys.stdin) if x["action"]=="milestone"][0])')" "書類選考：通過"

echo "== 操作の権限 =="
ok "A社はB社の選考を辞退させられない"              "$(rpc "$A" v2_withdraw "{\"p_app\":\"$JIRO\"}" | code)" "P0403"
ok "A社（1次）は受入できない"                       "$(rpc "$A" v2_relay_decide "{\"p_app\":\"$SABU\",\"p_action\":\"accept\"}" | code)" "P0403"
ok "B社は自分の選考を送客できない（判断はKANOA）"  "$(rpc "$B" v2_relay_decide "{\"p_app\":\"$SABU\",\"p_action\":\"forward\"}" | code)" "P0403"
ok "社内求人の進み具合はCAが更新できない"           "$(rpc "$A" v2_milestone_save "{\"p_id\":\"$(one "select id from v2_milestones where application_id='$JIRO' and seq=2")\",\"p_version\":1,\"p_scheduled\":null,\"p_done\":null,\"p_result\":\"passed\"}" | code)" "P0403"
ok "同じ求職者を同じ求人に二重応募できない"         "$(rpc "$B" v2_apply "{\"p_candidate\":\"$CJIRO\",\"p_job\":\"$JOB\"}" | code)" "P0409"
ok "B社はA社の求職者を応募させられない"             "$(rpc "$B" v2_apply "{\"p_candidate\":\"$(one "select id from v2_candidates where name='テスト花子'")\",\"p_job\":\"$JOB\"}" | code)" "P0403"
ok "選考の行を直接作れない"                         "$(curl -s -X POST "$BASE/rest/v1/v2_applications" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "{\"candidate_id\":\"$CJIRO\",\"kind\":\"internal\",\"job_id\":\"$JOB\",\"stage\":\"active\"}" | code)" "42501"
ok "選考の状態を直接書き換えられない（0件更新）"   "$(curl -s -X PATCH "$BASE/rest/v1/v2_applications?id=eq.$JIRO" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"stage":"closed","result":"passed"}' | len)" "0"
ok "外部求人のURLは http(s) のみ"                  "$(rpc "$A" v2_register_external "{\"p_candidate\":\"$(one "select id from v2_candidates where name='テスト花子'")\",\"p_url\":\"javascript:alert(1)\",\"p_company\":\"x\",\"p_title\":\"x\",\"p_applied_on\":null,\"p_flow\":[\"面接\"]}" | code)" "P0400"

RAUID=$(one "select user_id from v2_members where role='ra' limit 1")
ra(){ sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; $1; commit;"; }
ok "RA: 紹介された選考は次郎・三郎・花子（外部求人は見えない）" \
  "$(ra "select string_agg(candidate_name, ',' order by candidate_name) r from v2_selection_list('received')" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "テスト三郎,テスト次郎,テスト花子"
EXPECT=$(one "select count(*) from v2_applications where stage='relay' and holder_company_id is null and kanoa_visible")
ok "RA: 受入待ちの件数がDBの実数と一致"             "$(ra "select v2_waiting_count() r" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "$EXPECT"
ok "RA: 外部求人の行は読めない"                     "$(ra "select count(*) r from v2_applications where kind='external'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
ok "RA: B社の求職者のメモは読めない"                "$(ra "select count(*) r from v2_candidate_notes where company_id is not null" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
