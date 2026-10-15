#!/usr/bin/env bash
# テストデータの削除（切替前・作り直したいとき）
# 1) テスト求職者の書類ファイルを置き場から消す（DBから直接は消せないため、A社のテストアカウントで消す）
# 2) tests/cleanup_test_data.sql でDBのテストデータを消す
set -eu
cd "$(dirname "$0")/.."
source tests/.test-accounts.env
BASE=https://oicpfsfvywdhdriqehyr.supabase.co
AK=sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms
TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sql(){ python3 -c "import json,sys;print(json.dumps({'query':sys.argv[1]}))" "$1" > "$TMP/q.json"
  curl -s -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json"; }
A=$(curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "{\"email\":\"$(echo "$A_OWNER_ID" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid\",\"password\":\"$A_OWNER_PW\"}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
PATHS=$(sql "select coalesce(json_agg(f.storage_path),'[]') p from v2_candidate_files f join v2_candidates c on c.id=f.candidate_id join v2_companies co on co.id=c.owner_company_id where co.code in ('A99999','B00001')" | python3 -c 'import json,sys;print(json.dumps({"prefixes":json.load(sys.stdin)[0]["p"]}))')
curl -s -X DELETE "$BASE/storage/v1/object/v2-files" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$PATHS" > /dev/null
python3 -c "import json,sys;print(json.dumps({'query':open('tests/cleanup_test_data.sql').read()}))" > "$TMP/q.json"
curl -s -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json"
echo; echo "テストデータを削除しました"
