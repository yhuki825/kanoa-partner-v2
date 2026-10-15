#!/usr/bin/env bash
# 第2段階（求職者・求人・紹介料・書類）の権限テスト。読み取り＋拒否の確認だけ（データは変えない）
# 件数ではなく「見えてはいけないもの」を名指しで確かめる（データが増えても判定がぶれないように）
# 前提: phase1 のテストアカウント、テスト求人「テスト営業職（自動削除予定）」、A社の求職者「テスト花子」
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
len(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 'ERR:'+str(d)[:80])"; }
field(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d[0].get(sys.argv[1]) if isinstance(d,list) and d else ('none' if isinstance(d,list) else 'ERR'))" "$1"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') or d.get('statusCode') or d.get('error') or 'none')"; }
sql(){ python3 -c "import json,sys;print(json.dumps({'query':sys.argv[1]}))" "$1" > "$TMP/q.json"
  curl -s -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json"; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); C=$(login "$A_CA_ID" "$A_CA_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
JOB=$(sql "select id from v2_jobs where title='テスト営業職（自動削除予定）'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')
CAND=$(sql "select id from v2_candidates where name='テスト花子'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')
FILEPATH=$(sql "select storage_path from v2_candidate_files where candidate_id='$CAND' and kind='resume'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["storage_path"])')

echo "== 紹介料 =="
ok "1次(A社): KANOA→自社の額"                       "$(get "$A" "v2_jobs?select=v2_my_fee&id=eq.$JOB" | field v2_my_fee)" "300000"
ok "2次(B社): A社がフロント向けに設定した額"         "$(get "$B" "v2_jobs?select=v2_my_fee&id=eq.$JOB" | field v2_my_fee)" "160000"
ok "2次はKANOAの基本額を読めない"                    "$(get "$B" 'v2_job_kanoa_fees?select=fee' | len)" "0"
ok "2次はKANOA→1次の公開行を読めない"                "$(get "$B" 'v2_job_shares?select=fee_override' | len)" "0"
ok "1次もKANOAの基本額表は読めない"                  "$(get "$A" 'v2_job_kanoa_fees?select=fee' | len)" "0"
ok "非公開のテスト求人はA社に見えない"               "$(get "$A" "v2_jobs?select=id&title=like.*%E9%9D%9E%E5%85%AC%E9%96%8B*" | len)" "0"
J2=$(sql "select id from v2_jobs where title like '非公開%'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')
ok "偽の行で非公開求人の紹介料を引き出せない"        "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_my_fee" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "{\"j\":{\"id\":\"$J2\"}}")" "null"
ok "代表でないCAはフロント提示額を変えられない（0件更新）" "$(curl -s -X PATCH "$BASE/rest/v1/v2_job_offers?job_id=eq.$JOB" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"fee_display":1}' | len)" "0"
ok "CAはKANOA→1次の公開行を作れない"                 "$(curl -s -X POST "$BASE/rest/v1/v2_job_shares" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "{\"job_id\":\"$J2\",\"company_id\":\"$(sql "select id from v2_companies where code='A99999'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')\"}" | code)" "42501"

echo "== 求職者・メモ・書類 =="
ok "A社の別CAも自社の求職者が見える"                 "$(get "$C" "v2_candidates?select=name&id=eq.$CAND" | field name)" "テスト花子"
ok "A社の別CAも自社のメモが見える"                   "$(get "$C" "v2_candidate_notes?select=memo&candidate_id=eq.$CAND" | field memo)" "A社だけのメモ（テスト）"
ok "B社（フロント）からA社の求職者は見えない"          "$(get "$B" 'v2_candidates?select=owner:v2_companies(code)' | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin) if (x.get("owner") or {}).get("code")!="B00001"))')" "0"
ok "B社からA社のメモは見えない"                      "$(get "$B" 'v2_candidate_notes?select=company:v2_companies(code)' | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin) if (x.get("company") or {}).get("code")!="B00001"))')" "0"
ok "B社からA社の書類の記録は見えない"                "$(get "$B" "v2_candidate_files?select=id&candidate_id=eq.$CAND" | len)" "0"
ok "B社はA社の書類ファイルを取得できない"            "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/v2-files/$FILEPATH" -H "apikey: $AK" -H "Authorization: Bearer $B")" "400"
ok "A社は自社の書類ファイルを取得できる"             "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/v2-files/$FILEPATH" -H "apikey: $AK" -H "Authorization: Bearer $A")" "200"
ok "B社はA社の求職者の場所に書類を置けない"           "$(curl -s -X POST "$BASE/storage/v1/object/v2-files/candidates/$CAND/evil.pdf" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/pdf' --data-binary 'x' -o /dev/null -w '%{http_code}')" "400"
ok "未ログインでは書類を取得できない"               "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/v2-files/$FILEPATH" -H "apikey: $AK")" "400"
ok "B社はA社の求職者を書き換えられない（0件更新）"     "$(curl -s -X PATCH "$BASE/rest/v1/v2_candidates?id=eq.$CAND" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"name":"x"}' | len)" "0"
ok "同じ電話番号（表記違い）は二重登録できない"      "$(curl -s -X POST "$BASE/rest/v1/v2_candidates" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "{\"name\":\"重複テスト\",\"phone\":\"09000001111\",\"owner_company_id\":\"$(sql "select id from v2_companies where code='B00001'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')\"}" | code)" "23505"
ok "他社を持ち主にして登録できない"                  "$(curl -s -X POST "$BASE/rest/v1/v2_candidates" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "{\"name\":\"なりすまし\",\"owner_company_id\":\"$(sql "select id from v2_companies where code='A99999'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')\"}" | code)" "42501"
ok "B社の検索結果にA社の求職者が出ない"              "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_candidate_list" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d '{"p_q":"テスト花子"}' | len)" "0"

RAUID=$(sql "select user_id from v2_members where role='ra' limit 1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["user_id"])')
ok "RA: KANOAの基本額が読める（1件以上）" \
  "$(sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; select ((select count(*) from v2_job_kanoa_fees) > 0)::text r; commit;" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "true"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
