#!/usr/bin/env bash
# 第4段階（選考チャット）の権限テスト。送信テストは「テスト（自動削除予定）」の選考の中だけで行う
# 前提: B社の「テスト次郎」の選考（B社→A社→KANOA まで届いている）、「テスト四郎」の選考（A社の判断待ち）
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
rpc(){ curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
code(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') if isinstance(d,dict) else 'none')"; }
# 問い合わせ用のJSONを組み立てる（bash 3.2 は $( ) の中の \" を正しく読めないため、引用符を入れ子にしない）
# 使い方: j キー 値 キー 値 …（値を = で始めると、数値・null・配列などをそのまま入れる）
j(){ python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps({a[i]:(json.loads(a[i+1][1:]) if a[i+1].startswith("=") else a[i+1]) for i in range(0,len(a),2)},ensure_ascii=False))' "$@"; }
sql(){ python3 -c "import json,sys;print(json.dumps({'query':sys.argv[1]}))" "$1" > "$TMP/q.json"
  curl -s -X POST "https://api.supabase.com/v1/projects/oicpfsfvywdhdriqehyr/database/query" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @"$TMP/q.json"; }
one(){ sql "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(list(d[0].values())[0])'; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW"); C=$(login "$A_CA_ID" "$A_CA_PW")
APP=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
HANA=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト花子' and a.kind='internal'")
EXT=$(one "select id from v2_applications where kind='external' limit 1")
AID=$(one "select id from v2_companies where code='A99999'"); BID=$(one "select id from v2_companies where code='B00001'")
RAUID=$(one "select user_id from v2_members where role='ra' limit 1")
ra(){ sql "begin; select set_config('request.jwt.claims','{\"sub\":\"$RAUID\",\"role\":\"authenticated\"}',true); set local role authenticated; $1; commit;"; }
sides(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(','.join(x['my_side'] for x in d) if isinstance(d,list) else 'ERR')"; }

echo "== 参加できる会話 =="
ok "B社: A社との会話だけ（下側）"                  "$(rpc "$B" v2_my_threads "$(j p_app "$APP")" | sides)" "self"
ok "A社: アップライン→紹介元の順で2本"            "$(rpc "$A" v2_my_threads "$(j p_app "$APP")" | sides)" "self,up"
ok "A社の別CAも同じ2本に参加できる"               "$(rpc "$C" v2_my_threads "$(j p_app "$APP")" | sides)" "self,up"
ok "RA: A社との会話だけ（上側）"                   "$(ra "select string_agg(my_side, ',') r from v2_my_threads('$APP')" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "up"
ok "外部求人の選考には会話がない"                  "$(rpc "$A" v2_my_threads "$(j p_app "$EXT")" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "0"
ok "A社自身の選考（花子）はKANOAとの会話だけ"      "$(rpc "$A" v2_my_threads "$(j p_app "$HANA")" | sides)" "self"
ok "B社は関係のない選考（花子）の会話を持たない"    "$(rpc "$B" v2_my_threads "$(j p_app "$HANA")" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "0"

echo "== 読み書きの権限 =="
ok "B社はA社⇔KANOAの会話を読めない"                "$(rpc "$B" v2_thread_messages "$(j p_app "$APP" p_thread "$AID")" | code)" "P0403"
ok "B社はA社⇔KANOAの会話に書けない"                "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$AID" p_body "x")" | code)" "P0403"
ok "B社の表の直接読み取りにA社⇔KANOAの行が出ない"  "$(curl -s "$BASE/rest/v1/v2_messages?select=id&application_id=eq.$APP&thread_company_id=eq.$AID" -H "apikey: $AK" -H "Authorization: Bearer $B" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "0"
ok "RAはB社⇔A社の会話を読めない"                    "$(ra "select count(*) r from v2_messages where application_id='$APP' and thread_company_id='$BID'" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
ok "表に直接書き込めない"                            "$(curl -s -X POST "$BASE/rest/v1/v2_messages" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "$(j application_id "$APP" thread_company_id "$BID" sender_member_id "$(one "select id from v2_members where login_id='B00001-01'")" side "self" body "x")" | code)" "42501"
ok "表を直接書き換えられない（権限エラー）"          "$(curl -s -X PATCH "$BASE/rest/v1/v2_messages?application_id=eq.$APP" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"body":"改ざん"}' | code)" "42501"
MID=$(one "select id from v2_messages where application_id='$APP' and thread_company_id='$BID' and side='self' and not deleted order by created_at limit 1")
ok "他人のメッセージは編集できない"                  "$(rpc "$A" v2_msg_edit "$(j p_id "$MID" p_version '=1' p_body "改ざん")" | code)" "P0403"
ok "他人のメッセージは削除できない"                  "$(rpc "$A" v2_msg_delete "$(j p_id "$MID")" | code)" "P0403"
ok "決められた以外の絵文字は付けられない"            "$(rpc "$A" v2_msg_react "$(j p_id "$MID" p_emoji "<script>")" | code)" "P0400"
ok "空のメッセージは送れない"                        "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body "   ")" | code)" "P0400"
ok "別の会話のメッセージに返信を付けられない"        "$(rpc "$A" v2_msg_send "$(j p_app "$APP" p_thread "$AID" p_body "x" p_reply_to "$MID")" | code)" "P0400"

echo "== 未読 =="
rpc "$B" v2_thread_mark_read "$(j p_app "$APP" p_thread "$BID")" > /dev/null
ok "B社: 既読にすると未読0"                           "$(rpc "$B" v2_chat_unread '{}' | python3 -c 'import json,sys;print(sum(x["unread"] for x in json.load(sys.stdin)))')" "0"
rpc "$B" v2_thread_mark_unread "$(j p_app "$APP" p_thread "$BID")" > /dev/null
ok "B社: 未読に戻すと未読1"                           "$(rpc "$B" v2_chat_unread '{}' | python3 -c 'import json,sys;print(sum(x["unread"] for x in json.load(sys.stdin)))')" "1"
rpc "$B" v2_thread_mark_read "$(j p_app "$APP" p_thread "$BID")" > /dev/null

echo "== 独立レビューの指摘への対策 =="
ok "削除したメッセージの本文は表から直接読めない"    "$(curl -s "$BASE/rest/v1/v2_messages?select=body&deleted=eq.true" -H "apikey: $AK" -H "Authorization: Bearer $A" | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin) if x["body"]))')" "0"
SHIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト四郎'")
ok "KANOAに届く前の選考では、A社はKANOAとの会話を持たない（紹介元とだけ）" "$(rpc "$A" v2_my_threads "$(j p_app "$SHIRO")" | sides)" "up"
ok "KANOAに届く前の選考で、A社はKANOAとの会話に書けない" "$(rpc "$A" v2_msg_send "$(j p_app "$SHIRO" p_thread "$AID" p_body "x")" | code)" "P0403"
ok "未ログインではチャットの関数を呼べない"          "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_chat_unread" -H "apikey: $AK" -H 'Content-Type: application/json' -d '{}' | code)" "42501"
ok "決められたスタンプ以外は送れない"                "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_stamp "x")" | code)" "P0400"
ok "空のスタンプは送れない"                          "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_stamp "")" | code)" "P0400"
ok "本文とスタンプを同時には送れない"                "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body "x" p_stamp "👍")" | code)" "P0400"

echo "== 送信者名（相手の会社の人の名前は出さない） =="
ok "B社: A社の人のメッセージに名前が無い"           "$(rpc "$B" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin) if x["side"]=="up" and x["sender_name"]))')" "0"
ok "A社: B社の人のメッセージに名前が無い"           "$(rpc "$A" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | python3 -c 'import json,sys;print(sum(1 for x in json.load(sys.stdin) if x["side"]=="self" and x["sender_name"]))')" "0"
ok "A社: 自社側のメッセージには名前がある"           "$(rpc "$A" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | python3 -c 'import json,sys;d=[x for x in json.load(sys.stdin) if x["side"]=="up" and not x["deleted"]];print(all(x["sender_name"] for x in d) and len(d)>0)')" "True"
ok "RA: A社の人のメッセージに名前が無い"            "$(ra "select count(*) r from v2_thread_messages('$APP','$AID') where side='self' and sender_name is not null" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["r"])')" "0"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
