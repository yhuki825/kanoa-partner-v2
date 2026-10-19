#!/usr/bin/env bash
# 第5段階（前半: 各種資料・パートナー管理・CA一覧）の権限テスト。読み取り＋拒否の確認だけ
# 前提: テスト資料「公開資料（テスト）」「非公開資料（テスト）」、A社のCA A99999-02 / -03、取消済みの招待 B00002
set -u
cd "$(dirname "$0")/.."
source tests/.test-accounts.env
BASE=https://oicpfsfvywdhdriqehyr.supabase.co
AK=sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms
TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# 判定: 受け取る値は「名前・実際・期待」の3つちょうど。ずれていたら必ず不合格にする
ok(){ if [ "$#" -ne 3 ]; then echo "FAIL  $1  （テストの書き方の誤り: 値が$#個）"; fail=$((fail+1)); return; fi
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  期待=[$3] 実際=[$2]"; fail=$((fail+1)); fi; }
# 問い合わせ用のJSON（$( ) の中に \" を入れ子にしない）
j(){ python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps({a[i]:(json.loads(a[i+1][1:]) if a[i+1].startswith("=") else a[i+1]) for i in range(0,len(a),2)},ensure_ascii=False))' "$@"; }
login(){ curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $AK" -H "Content-Type: application/json" \
  -d "$(j email "$(echo "$1" | tr 'A-Z' 'a-z')@id.kanoa-portal.invalid" password "$2")" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))"; }
rpc(){ curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
fn(){ curl -s -X POST "$BASE/functions/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
get(){ curl -s "$BASE/rest/v1/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('code') or d.get('error')) if isinstance(d,dict) else 'none')"; }
titles(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(','.join(sorted(x['title'] for x in d if 'テスト' in x['title'])) if isinstance(d,list) else 'ERR')"; }
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

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); C=$(login "$A_CA_ID" "$A_CA_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
M01=$(one "select id from v2_members where login_id='A99999-01'"); M03=$(one "select id from v2_members where login_id='A99999-03'"); MB=$(one "select id from v2_members where login_id='B00001-01'")

echo "== 各種資料 =="
ok "CAには公開中の資料だけ見える"               "$(get "$A" 'v2_resources?select=title' | titles)" "公開資料（テスト）"
ok "2次（B社）にも公開中の資料だけ見える"       "$(get "$B" 'v2_resources?select=title' | titles)" "公開資料（テスト）"
ok "未ログインでは資料が見えない"               "$(curl -s "$BASE/rest/v1/v2_resources?select=title" -H "apikey: $AK" | titles)" ""
ok "CAは資料を登録できない"                      "$(curl -s -X POST "$BASE/rest/v1/v2_resources" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j title x kind link url https://example.com)" | code)" "42501"
ok "CAは資料の置き場にファイルを置けない"        "$(curl -s -X POST "$BASE/storage/v1/object/v2-files/resources/x/evil.pdf" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/pdf' --data-binary 'x' -o /dev/null -w '%{http_code}')" "400"

echo "== CAの停止・再開 =="
ok "代表でないCAは他のCAを停止できない"          "$(rpc "$C" v2_set_member_status "$(j p_member "$M03" p_status suspended)" | code)" "P0403"
ok "代表者は自分自身を停止できない"              "$(rpc "$A" v2_set_member_status "$(j p_member "$M01" p_status suspended)" | code)" "P0403"
ok "代表者は他社（B社）のCAを停止できない"        "$(rpc "$A" v2_set_member_status "$(j p_member "$MB" p_status suspended)" | code)" "P0403"
ok "B社の代表者はA社のCAを停止できない"          "$(rpc "$B" v2_set_member_status "$(j p_member "$M03" p_status suspended)" | code)" "P0403"
ok "未ログインでは停止の関数を呼べない"          "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_set_member_status" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_member "$M03" p_status suspended)" | code)" "42501"
ok "CAは自分の状態を直接書き換えられない"        "$(curl -s -X PATCH "$BASE/rest/v1/v2_members?id=eq.$(one "select id from v2_members where login_id='A99999-02'")" -H "apikey: $AK" -H "Authorization: Bearer $C" -H 'Content-Type: application/json' -d "$(j status suspended)" | code)" "P0403"

echo "== パスワード再設定・招待の再発行 =="
ok "代表でないCAはパスワードを再設定できない"    "$(fn "$C" v2-member-reset "$(j member_id "$M03")" | code)" "owner_only"
ok "B社の代表者はA社のCAを再設定できない"        "$(fn "$B" v2-member-reset "$(j member_id "$M03")" | code)" "owner_only"
ok "自分のパスワードはこの方法では変えない"      "$(fn "$A" v2-member-reset "$(j member_id "$M01")" | code)" "use_account_page"
ok "B社はA社が出した招待を再発行できない"        "$(fn "$B" v2-invite-issue "$(j reissue_code B00002)" | code)" "not_found"
ok "取り消した招待は再発行できない"              "$(fn "$A" v2-invite-issue "$(j reissue_code B00002)" | code)" "already_used"
ok "代表でないCAは招待を発行できない"            "$(fn "$C" v2-invite-issue "$(j company_name x)" | code)" "owner_only"

echo "== V1 から移したアカウント（切替日まで変更できない・V1 の本番のログイン用アカウントを書き換えない） =="
RAUID=$(one "select user_id from v2_members where role='ra' and status='active' order by created_at limit 1")
ra(){ sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; $1; commit;"; }
errk(){ python3 -c 'import json,sys;d=json.load(sys.stdin);m=d.get("message","") if isinstance(d,dict) else "";print("v1_locked" if "v1_locked" in m else ("none" if isinstance(d,list) else m[:60]))'; }
MIG=$(one "select coalesce((select m.id::text from v2_members m join v2_v1_map x on x.kind='owner_member' and x.v2_id=m.id order by m.login_id limit 1),'')")
if [ -n "$MIG" ] && [ "$(one "select v2_v1_cutover_done()::text")" = "false" ]; then
  # V1 のログイン用アカウント（移したメンバーの分）のパスワードと更新日時の要約（md5 で比べるだけ。値は出さない）
  V1H(){ one "select md5(coalesce(string_agg(u.id::text||coalesce(u.encrypted_password,'')||coalesce(u.updated_at::text,''),'|' order by u.id),'')) from auth.users u join v2_members m on m.user_id=u.id join v2_v1_map x on x.kind='owner_member' and x.v2_id=m.id"; }
  H0=$(V1H); S0=$(one "select status||'/'||must_change_pw from v2_members where id='$MIG'")
  ok "移したアカウントのパスワード再設定は止まる（v2-member-reset）"   "$(fn "$A" v2-member-reset "$(j member_id "$MIG")" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("error"))')" "v1_locked"
  ok "RA: 移したアカウントを再開できない（v2_set_member_status）"     "$(ra "select v2_set_member_status('$MIG','active')" | errk)" "v1_locked"
  ok "RA: 移したアカウントを停止できない（v2_set_member_status）"     "$(ra "select v2_set_member_status('$MIG','suspended')" | errk)" "v1_locked"
  ok "RA: 移したアカウントの状態を表から直接書き換えられない"        "$(ra "update v2_members set status='active' where id='$MIG'" | errk)" "v1_locked"
  ok "RA: 移したアカウントのログイン用アカウントを付け替えられない"  "$(ra "update v2_members set user_id='$RAUID' where id='$MIG'" | errk)" "v1_locked"
  # 直せることの確認だけ（移した行を変えると流し直しの点検に掛かるため、取り消して終える）
  ok "RA: 移したアカウントの表示名は直せる（V2 の中だけの項目）"     "$(sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; update v2_members set name=name where id='$MIG'; rollback;" | errk)" "none"
  ok "移したアカウントの状態は変わっていない"                        "$(one "select status||'/'||must_change_pw from v2_members where id='$MIG'")" "$S0"
  ok "V1 のログイン用アカウント（パスワード・更新日時）は変わっていない（md5 で比較）" "$([ "$(V1H)" = "$H0" ] && echo same || echo changed)" "same"
  ok "画面用: 移したアカウントには印が付く"                          "$(ra "select (select v2_v1_locked(m) from v2_members m where id='$MIG')::text r" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "true"
else
  echo "SKIP  移したアカウントが無い（または切替済み）ため、V1 アカウントの保護の確認を省略"
fi
ok "（対照）テスト用のCAはパスワード再設定できる"                     "$(fn "$A" v2-member-reset "$(j member_id "$M03")" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok" if d.get("ok") and d.get("temp_password") else d.get("error"))')" "ok"
ok "（対照）テスト用のCAには印が付かない"                             "$(one "select (select v2_member_v1_locked(id) from v2_members where id='$M03')::text")" "false"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
