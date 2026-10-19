#!/usr/bin/env bash
# 第1段階（土台）の権限テスト。何度流してもよい（読み取り＋拒否の確認だけ。最後の更新1件は元に戻す）
# 使い方: bash tests/phase1_check.sh
# 前提: tests/.test-accounts.env（テスト用アカウント）、Supabase CLI にログイン済み（キーチェーン）
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
email(){ echo "$(echo "$1" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid"; }
login(){ curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "{\"email\":\"$(email "$1")\",\"password\":\"$2\"}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))"; }
get(){ curl -s "$BASE/rest/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
codes(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(','.join(sorted(str(x[sys.argv[1]]) for x in d)) if isinstance(d,list) else 'ERR')" "$1"; }
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

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); C=$(login "$A_CA_ID" "$A_CA_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
ok "3アカウントでログインできる" "$([ -n "$A" ] && [ -n "$C" ] && [ -n "$B" ] && echo y)" "y"

ok "A社: 自社と自分のフロントだけ見える"   "$(get "$A" 'v2_companies?select=code' | codes code)" "A99999,B00001"
ok "B社: 自社だけ見える（アップは見えない）" "$(get "$B" 'v2_companies?select=code' | codes code)" "B00001"
ok "A社: 他社のメンバーはフロントの代表者だけ見える" "$(get "$A" 'v2_members?select=login_id,is_owner,company:v2_companies!v2_members_company_id_fkey(code)' | python3 -c 'import json,sys;d=json.load(sys.stdin);o=[x for x in d if x["company"]["code"]!="A99999"];print("OK" if o and all(x["is_owner"] for x in o) and any(x["login_id"]=="B00001-01" for x in o) else "NG:"+",".join(x["login_id"] for x in o))')" "OK"
ok "B社: 自社メンバーだけ"                 "$(get "$B" 'v2_members?select=login_id' | codes login_id)" "B00001-01"
ok "未ログイン: 会社は何も見えない"         "$(curl -s "$BASE/rest/v1/v2_companies?select=code" -H "apikey: $AK")" "[]"

# V1 から移行した本物のお知らせ（全社向け）も見えるため、名前の照合はテスト用のお知らせに絞る（2026-10-19 移行のお試しで変更）
tn(){ python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join(sorted(x["title"] for x in d if x["title"].endswith("（テスト）"))) if isinstance(d,list) else "ERR")'; }
cnt(){ python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else "ERR")'; }
pub_for(){ sql "select count(*) n from v2_notices where status='published' and (audience='all' or (select id from v2_companies where code='$1') = any(target_company_ids))" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["n"])'; }
ok "お知らせ: A社は全社向けだけ（下書き・B社向けは見えない）" "$(get "$A" 'v2_notices?select=title' | tn)" "全社向け（テスト）"
ok "お知らせ: B社は全社向け＋B社向け"                         "$(get "$B" 'v2_notices?select=title' | tn)" "B社向け（テスト）,全社向け（テスト）"
ok "お知らせ: A社に見えるのは公開中の全社向け＋自社向けの全件（移行分を含む・DBの実数と一致）" "$(get "$A" 'v2_notices?select=id' | cnt)" "$(pub_for A99999)"
ok "お知らせ: B社に見えるのは公開中の全社向け＋自社向けの全件（移行分を含む・DBの実数と一致）" "$(get "$B" 'v2_notices?select=id' | cnt)" "$(pub_for B00001)"
ok "CAはお知らせを作れない" "$(curl -s -X POST "$BASE/rest/v1/v2_notices" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d '{"title":"x"}' | python3 -c 'import json,sys;print(json.load(sys.stdin).get("code"))')" "42501"

ok "代表でないCAはCAを追加できない" "$(curl -s -X POST "$BASE/functions/v1/v2-member-create" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -d '{"name":"x"}' | python3 -c 'import json,sys;print(json.load(sys.stdin).get("error"))')" "owner_only"
ok "代表でないCAは招待できない"     "$(curl -s -X POST "$BASE/functions/v1/v2-invite-issue" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -d '{"company_name":"x"}' | python3 -c 'import json,sys;print(json.load(sys.stdin).get("error"))')" "owner_only"
ok "CAは自分を代表者にできない（エラーで止まる）" "$(curl -s -X PATCH "$BASE/rest/v1/v2_members?login_id=eq.$A_CA_ID" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -d '{"is_owner":true}' | python3 -c 'import json,sys;print(json.load(sys.stdin).get("code"))')" "P0403"

V=$(get "$C" "v2_members?select=version&login_id=eq.$A_CA_ID" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')
ok "古いversionでの更新は衝突で止まる" "$(curl -s -X PATCH "$BASE/rest/v1/v2_members?login_id=eq.$A_CA_ID" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -d "$(j name "古い画面" version "=$((V-1))")" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("code"))')" "P0409"

RAUID=$(sql "select user_id from v2_members where role='ra' limit 1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["user_id"])')
ok "RA: 全社・全お知らせ（下書き含む）が見える" "$(sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; select (select count(*) from v2_companies)||'/'||(select count(*) from v2_notices where title like '%（テスト）') r; commit;" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" \
  "$(sql "select (select count(*) from v2_companies)||'/3' r" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')"   # 全社＝DBの実数（V1 から移行した会社を含む）

ok "V1が無傷（V1のログイン用アカウント26件）" "$(sql "select count(*) c from auth.users where email like '%@partner.kanoa.local'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["c"])')" "26"

echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
