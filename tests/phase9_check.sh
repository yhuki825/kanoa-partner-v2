#!/usr/bin/env bash
# 選考チャットのファイル添付（124・125・126）のテスト。何度流してもよい
# 前提（テストデータ）: B社の「テスト次郎」の選考（B00001→A99999→KANOA、KANOA受入済み）
# 会話: B00001⇔A99999（会話の会社ID＝B00001）、A99999⇔KANOA（会話の会社ID＝A99999）
# 確かめること: 会話の2社だけが置ける・開ける／送信の関数が置き場の記録で本人・場所・大きさ・種類を確かめる／
#              削除したメッセージのファイルは開けない／紐づかなかった自分のファイルだけ消せる／
#              送信済みの場所には置き直せない（中身のすり替え防止）／置ける場所の形／消し残しの一覧（本人の分だけ）
# テストで送ったメッセージは最後に削除する（ファイルは開けなくなる）
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
# 置き場の操作（戻り値はHTTPの番号）: up トークン 場所 種類 ファイル ／ dl トークン 場所 ／ rm トークン 場所
up(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/storage/v1/object/v2-files/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H "Content-Type: $3" --data-binary @"$4"; }
dl(){ curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/v2-files/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
rm_(){ curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/storage/v1/object/v2-files/$2" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
exists(){ one "select count(*) from storage.objects where bucket_id='v2-files' and name='$1'"; }
# 添付の指定（JSONの配列）: files 場所 名前 場所 名前 …
files(){ python3 -c 'import json,sys;a=sys.argv[1:];print(json.dumps([{"path":a[i],"name":a[i+1]} for i in range(0,len(a),2)],ensure_ascii=False))' "$@"; }
# 関数のエラーの理由（hint）
hint(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('hint') if isinstance(d,dict) else 'none')"; }
# 会話のメッセージ（id）の添付: 名前|種類|大きさ（無ければ空）
mfiles(){ python3 -c "import json,sys;d=json.load(sys.stdin);m=[x for x in d if x['id']==sys.argv[1]] if isinstance(d,list) else None
print('ERR:'+str(d)[:120] if m is None else ('NOMSG' if not m else ','.join('%s|%s|%s'%(f['name'],f['mime'],f['size']) for f in m[0]['files'])))" "$1"; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW"); C=$(login "$A_CA_ID" "$A_CA_PW")
ok "3アカウントでログインできる" "$([ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && echo y)" "y"
APP=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
AID=$(one "select id from v2_companies where code='A99999'"); BID=$(one "select id from v2_companies where code='B00001'")
# テスト用のファイル（PDF・PNG・テキスト・11MB）
printf '%%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%%%EOF\n' > "$TMP/a.pdf"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$TMP/a.png"
echo "text" > "$TMP/a.txt"
head -c 11000000 /dev/zero > "$TMP/big.pdf"
PDFSIZE=$(wc -c < "$TMP/a.pdf" | tr -d ' ')
# 置き場の場所はランダムなUUID＋拡張子でないと置けない（126）。テストも画面と同じ形で作る
nu(){ python3 -c 'import uuid;print(uuid.uuid4())'; }
PB="chat/$APP/$BID/$(nu).pdf"       # B社がB⇔Aの会話に置くPDF
PA="chat/$APP/$AID/$(nu).png"       # A社がA⇔KANOAの会話に置く画像
PZ="chat/$APP/$BID/$(nu).pdf"       # A社の代表がB⇔Aの会話に置くが送らないPDF
PBIG="chat/$APP/$BID/$(nu).pdf"; PTXT="chat/$APP/$BID/$(nu).pdf"; PB2="chat/$APP/$BID/$(nu).png"
PU="chat/$APP/$BID/$(nu).pdf"       # B社が置くだけで送らないPDF（相手から見えないことの確認用）
PS="chat/$APP/$BID/$(nu).pdf"       # スタンプと一緒に送ろうとするPDF（未使用）
PX="chat/$APP/$AID/$(nu).png"       # A社がA⇔KANOAの会話に置き、B⇔Aの会話に付けようとする画像
PM="chat/$APP/$BID/$(nu).pdf"       # すり替えの手順を確かめるPDF
PAD="chat/$APP/$BID/$(nu).pdf"      # A社がB⇔Aの会話で送って削除するPDF（B社の消し残し一覧に出ないことの確認用）
# 未ログイン: 公開用のキー（sb_publishable_…）だけを付けて呼ぶ（他のテストと同じ）。窓口がこれを未ログイン（anon）の
# 身分に置き換えるので、置き場の権限（RLS）で判定される。身分の誤り（例: 壊れたトークン）なら
# 「JWS Protected Header is invalid」になり、RLSまで届かない。そこで「RLSで止められた」ことまで確かめる
msg(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('message') if isinstance(d,dict) else 'none')"; }
scode(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('code') if isinstance(d,dict) else 'none')"; }
anon_up(){ curl -s -X POST "$BASE/storage/v1/object/v2-files/$1" -H "apikey: $AK" -H "Content-Type: application/pdf" --data-binary @"$TMP/a.pdf" | msg; }
anon_dl(){ curl -s "$BASE/storage/v1/object/authenticated/v2-files/$1?nocache=$RANDOM$RANDOM" -H "apikey: $AK" | scode; }
# 上書き（x-upsert）・コピー・移動・開くためのURL
upx(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/storage/v1/object/v2-files/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H "Content-Type: $3" -H "x-upsert: true" --data-binary @"$4"; }
cpmv(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/storage/v1/object/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$(j bucketId v2-files sourceKey "$3" destinationKey "$4")"; }
sign(){ curl -s -X POST "$BASE/storage/v1/object/sign/v2-files/$2" -H "apikey: $AK" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"expiresIn":600}' | python3 -c "import json,sys;print(json.load(sys.stdin).get('signedURL',''))"; }
# 中身のmd5（配信の覚えを避けるため、毎回違う問い合わせにする）
dlmd5(){ curl -s "$BASE/storage/v1/object/authenticated/v2-files/$2?nocache=$RANDOM$RANDOM" -H "apikey: $AK" -H "Authorization: Bearer $1" | python3 -c "import hashlib,sys;print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())"; }
fmd5(){ python3 -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
# 置き場の記録の id と大きさ
objinfo(){ one "select coalesce((select id::text||'|'||(metadata->>'size') from storage.objects where bucket_id='v2-files' and name='$1'),'none')"; }
# 消し残しの一覧（v2_my_chat_files_pending_removal）に、その場所が入っているか
pend(){ rpc "$1" v2_my_chat_files_pending_removal "$(j p_app "$APP")" | python3 -c "import json,sys;d=json.load(sys.stdin);print('ERR:'+str(d)[:100] if not isinstance(d,list) else ('in' if sys.argv[1] in d else 'out'))" "$2"; }
# 関数のエラー: code|hint
codehint(){ python3 -c "import json,sys;d=json.load(sys.stdin);print('%s|%s'%(d.get('code'),d.get('hint')) if isinstance(d,dict) else 'none')"; }
msgid(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d if isinstance(d,str) else 'ERR:'+str(d)[:120])"; }

echo "== 置ける人 =="
ok "B社: 自社の会話（B⇔A）にPDFを置ける"           "$(up "$B" "$PB" application/pdf "$TMP/a.pdf")" "200"
NOPUT=$(up "$B" "chat/$APP/$AID/$(nu).pdf" application/pdf "$TMP/a.pdf")
ok "B社: A⇔KANOAの会話には置けない（200以外）"     "$([ "$NOPUT" != 200 ] && echo denied || echo "allowed:$NOPUT")" "denied"
ok "未ログインでは置けない（RLSで止められる）"       "$(anon_up "chat/$APP/$BID/$(nu).pdf")" "new row violates row-level security policy"
NOBAD=$(up "$B" "chat/$APP/not-a-uuid/$(nu).pdf" application/pdf "$TMP/a.pdf")
ok "形の違う場所には置けない"                        "$([ "$NOBAD" != 200 ] && echo denied || echo allowed)" "denied"
UPAPP=$(echo "$APP" | tr 'a-f' 'A-F'); UPN=$(nu | tr 'a-f' 'A-F')
L1A=$(up "$B" "chat/$UPAPP/$BID/$(nu).pdf" application/pdf "$TMP/a.pdf")
L1B=$(up "$B" "chat/$APP/$BID/$UPN.pdf" application/pdf "$TMP/a.pdf")
L1C=$(up "$B" "chat/$APP/$BID/x/$(nu).pdf" application/pdf "$TMP/a.pdf")
L1D=$(up "$B" "chat/$APP/$BID/t$(nu | cut -c1-8).pdf" application/pdf "$TMP/a.pdf")
L1E=$(up "$B" "chat/$APP/$BID/$(nu).txt" application/pdf "$TMP/a.pdf")
ok "置けない: 選考IDが大文字／ファイル名が大文字／階層が多い／ファイル名がUUIDでない／拡張子が違う" \
   "$(for c in "$L1A" "$L1B" "$L1C" "$L1D" "$L1E"; do [ "$c" != 200 ] && printf d || printf A; done)" "ddddd"
ok "A社: A⇔KANOAの会話に画像を置ける"              "$(up "$A" "$PA" image/png "$TMP/a.png")" "200"

echo "== 送っていないファイルは相手から見えない =="
ok "B社: 送らずに置くだけ置ける"                     "$(up "$B" "$PU" application/pdf "$TMP/a.pdf")" "200"
NOAU=$(dl "$A" "$PU")
ok "A社: B社の送っていないファイルは開けない"        "$([ "$NOAU" != 200 ] && echo denied || echo "allowed:$NOAU")" "denied"
ok "A社: B社の送っていないファイルの開くためのURLも作れない" "$(sign "$A" "$PU")" ""
ok "（対照）B社は自分のファイルを開ける"             "$(dl "$B" "$PU")" "200"
ok "（対照）B社は開くためのURLを作れる"              "$([ -n "$(sign "$B" "$PU")" ] && echo y)" "y"

echo "== 送信（置き場の記録で確かめる） =="
MB=$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_files "=$(files "$PB" "見積書.pdf")")" | msgid)
ok "B社: ファイルだけのメッセージを送れる"           "$(echo "$MB" | grep -cE '^[0-9a-f-]{36}$')" "1"
MA=$(rpc "$A" v2_msg_send "$(j p_app "$APP" p_thread "$AID" p_body "画像です" p_files "=$(files "$PA" "写真.png")")" | msgid)
ok "A社: 本文＋画像のメッセージを送れる"             "$(echo "$MA" | grep -cE '^[0-9a-f-]{36}$')" "1"
ok "A社（上側）から見える: 名前・種類・大きさは置き場の記録" "$(rpc "$A" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | mfiles "$MB")" "見積書.pdf|application/pdf|$PDFSIZE"
ok "B社（送った側）からも見える"                     "$(rpc "$B" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | mfiles "$MB")" "見積書.pdf|application/pdf|$PDFSIZE"
ok "送信時に置き場の記録の id も覚える"              "$(one "select count(*) from v2_message_files f join storage.objects o on o.id=f.object_id and o.name=f.storage_path where f.storage_path='$PB'")" "1"

echo "== 開ける人 =="
ok "A社の代表: B⇔Aの会話のPDFを開ける"             "$(dl "$A" "$PB")" "200"
ok "A社の別CA: 開ける"                               "$(dl "$C" "$PB")" "200"
ok "B社: 自分が送ったPDFを開ける"                    "$(dl "$B" "$PB")" "200"
NOB=$(dl "$B" "$PA")
ok "B社: A⇔KANOAの会話の画像は開けない"            "$([ "$NOB" != 200 ] && echo denied || echo allowed)" "denied"
ok "（対照）A社はその画像を開ける"                   "$(dl "$A" "$PA")" "200"
ok "未ログインでは開けない（RLSで見えない＝無いのと同じ扱い）" "$(anon_dl "$PB")" "NoSuchKey"
# 開ける条件は「送信時に確かめた実体（同じ id）がまだその場所にあること」。id がずれたら開けないことを
# DBの中で確かめる（A社として判定。書き換えは最後に例外で取り消すので、何も残らない）
AUID=$(echo "$A" | python3 -c "import sys,json,base64;p=sys.stdin.read().split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['sub'])")
VIS=$(sql "do \$\$ declare r1 boolean; r2 boolean; begin
  perform set_config('request.jwt.claims', json_build_object('sub','$AUID','role','authenticated')::text, true);
  r1 := v2_chat_file_visible('$PB');
  update v2_message_files set object_id = gen_random_uuid() where storage_path = '$PB';
  r2 := v2_chat_file_visible('$PB');
  raise exception 'RESULT:%/%', r1, r2;
end \$\$;" | grep -oE 'RESULT:[a-z]+/[a-z]+' | head -1)
ok "開けるのは同じ id の実体があるときだけ（そのまま→開ける／id違い→開けない）" "$VIS" "RESULT:t/f"

echo "== 送信済みの場所は上書き・置き直しできない（中身のすり替え防止） =="
BEFORE=$(objinfo "$PB")
ok "B社（置いた本人）: 送信済みのPDFを上書き（x-upsert）できない" "$(c=$(upx "$B" "$PB" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "A社（相手）: 送信済みのPDFを上書き（x-upsert）できない"       "$(c=$(upx "$A" "$PB" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "上書きを試した後も、置き場の記録（id・大きさ）は同じ"        "$(objinfo "$PB")" "$BEFORE"
ok "上書きを試した後も、中身は送ったときのまま"                   "$(dlmd5 "$A" "$PB")" "$(fmd5 "$TMP/a.pdf")"
CPD="chat/$APP/$AID/$(nu).pdf"; MVD="chat/$APP/$AID/$(nu).pdf"
ok "B社: 送信済みのPDFを別の会話の場所へコピーできない"           "$(c=$(cpmv "$B" copy "$PB" "$CPD"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "B社: 送っていないPDFを別の会話の場所へ移動できない"           "$(c=$(cpmv "$B" move "$PU" "$MVD"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "（対照）コピー・移動の先には何も無く、元はそのまま"           "$(exists "$CPD")$(exists "$MVD")$(exists "$PU")" "001"
ok "B社: すり替え用のPDFを置ける"                                 "$(up "$B" "$PM" application/pdf "$TMP/a.pdf")" "200"
MM=$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body "すり替え確認" p_files "=$(files "$PM" "m.pdf")")" | msgid)
ok "…送る"                                                       "$(echo "$MM" | grep -cE '^[0-9a-f-]{36}$')" "1"
MBEFORE=$(objinfo "$PM")
ok "…送った後は、置き場の削除で消せない（紐づいているため）"    "$(rm_ "$B" "$PM" >/dev/null; objinfo "$PM")" "$MBEFORE"
ok "…同じ場所に置き直せない（上書きなし）"                      "$(c=$(up "$B" "$PM" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "…同じ場所に置き直せない（上書きあり）"                      "$(c=$(upx "$B" "$PM" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
ok "…置き場の記録（id・大きさ）は送ったときのまま"              "$(objinfo "$PM")" "$MBEFORE"

echo "== 送信の拒否 =="
ok "A社: A⇔KANOAの会話の場所に画像を置ける"        "$(up "$A" "$PX" image/png "$TMP/a.png")" "200"
ok "別の会話の場所のファイルは付けられない（両方の会話にいるA社が、A⇔KANOAの場所のファイルをB⇔Aへ）" \
   "$(rpc "$A" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body x p_files "=$(files "$PX" "x.png")")" | codehint)" "P0400|添付ファイルの置き場所が正しくありません。もう一度選び直してください"
rm_ "$A" "$PX" >/dev/null
ok "A社の代表: 送らずに置くだけ置ける（B⇔A）"      "$(up "$A" "$PZ" application/pdf "$TMP/a.pdf")" "200"
ok "人が置いたファイルは付けられない（A社の別CA→代表のファイル）" "$(rpc "$C" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body x p_files "=$(files "$PZ" "z.pdf")")" | code)" "P0400"
ok "置いた本人は、紐づかなかったファイルを消せる"   "$(rm_ "$A" "$PZ" >/dev/null; exists "$PZ")" "0"
ok "送ったファイル（紐づいたもの）は、置いた本人でも消せない" "$(rm_ "$B" "$PB" >/dev/null; exists "$PB")" "1"
ok "送信済みのファイルをもう一度付けられない"        "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body x p_files "=$(files "$PB" "again.pdf")")" | code)" "P0400"
ok "10MBを超えるPDF: 置けても（置き場の上限は20MB）…" "$(up "$B" "$PBIG" application/pdf "$TMP/big.pdf")" "200"
ok "…送信の関数が大きさで止める"                    "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_files "=$(files "$PBIG" "big.pdf")")" | hint)" "1つのファイルは10MBまでです"
ok "PDF・画像以外（中身はテキスト、場所は.pdf）: 置けても…" "$(up "$B" "$PTXT" text/plain "$TMP/a.txt")" "200"
ok "…送信の関数が種類で止める"                      "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_files "=$(files "$PTXT" "a.txt")")" | hint)" "送れるのはPDFと画像（JPEG・PNG・GIF・WebP）だけです"
ok "後始末: 送れなかったファイルは本人が消せる"     "$(rm_ "$B" "$PBIG" >/dev/null; rm_ "$B" "$PTXT" >/dev/null; echo "$(exists "$PBIG")$(exists "$PTXT")")" "00"
ok "6つ以上は送れない"                               "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_files "=$(files a 1 b 2 c 3 d 4 e 5 f 6)")" | hint)" "一度に送れるファイルは5つまでです"
ok "B社: スタンプ用に未使用のPDFを置ける"            "$(up "$B" "$PS" application/pdf "$TMP/a.pdf")" "200"
ok "スタンプとファイルは一緒に送れない"              "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_stamp "👍" p_files "=$(files "$PS" "x.pdf")")" | hint)" "スタンプとファイルは一緒に送れません"
ok "（対照）そのPDFは紐づいていない"                 "$(one "select count(*) from v2_message_files where storage_path='$PS'")" "0"
rm_ "$B" "$PS" >/dev/null
ok "B社: 2つ目の画像を置ける"                        "$(up "$B" "$PB2" image/png "$TMP/a.png")" "200"
ok "同じファイルを1回に2つ付けられない"              "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body x p_files "=$(files "$PB2" "1.png" "$PB2" "2.png")")" | code)" "P0400"
ok "（対照）失敗した送信ではメッセージが増えない"    "$(one "select count(*) from v2_message_files where storage_path='$PB2'")" "0"
ok "空のメッセージは今までどおり送れない"            "$(rpc "$B" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body "  " p_files '=[]')" | code)" "P0400"
ok "未ログインでは送信の関数を呼べない"              "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_msg_send" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_app "$APP" p_thread "$BID" p_body x)" | code)" "42501"
ok "未ログインでは消し残しの一覧を呼べない"          "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_my_chat_files_pending_removal" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_app "$APP")" | code)" "42501"
ok "添付の記録を直接は書けない"                      "$(curl -s -X POST "$BASE/rest/v1/v2_message_files" -H "apikey: $AK" -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "$(j message_id "$MB" application_id "$APP" thread_company_id "$BID" name x size '=1' mime application/pdf storage_path "$PB2" uploaded_by "$BID")" | code)" "42501"
ok "B社: 添付の記録はA⇔KANOAの会話の分が見えない" "$(curl -s "$BASE/rest/v1/v2_message_files?select=name&storage_path=eq.$PA" -H "apikey: $AK" -H "Authorization: Bearer $B")" "[]"
ok "（対照）A社には見える"                           "$(curl -s "$BASE/rest/v1/v2_message_files?select=name&storage_path=eq.$PA" -H "apikey: $AK" -H "Authorization: Bearer $A")" '[{"name":"写真.png"}]'
rm_ "$B" "$PB2" >/dev/null; rm_ "$B" "$PU" >/dev/null

echo "== 削除したメッセージ =="
# 画面と同じく「開くためのURL」をA社が先に受け取っておく（削除の前）
SURL=$(sign "$A" "$PB")
surl(){ curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1$1"; }
ok "（対照）削除の前は、A社が受け取ったURLで開ける"   "$(surl "$SURL")" "200"
ok "（対照）削除の前は、消し残しの一覧に出ない"       "$(pend "$B" "$PB")" "out"
ok "B社: ファイルのメッセージを削除できる"           "$(rpc "$B" v2_msg_delete "$(j p_id "$MB")")" ""
ok "削除後は添付が返らない"                          "$(rpc "$A" v2_thread_messages "$(j p_app "$APP" p_thread "$BID")" | mfiles "$MB")" ""
ok "削除したメッセージのファイルは、送ったB社の消し残しの一覧に出る" "$(pend "$B" "$PB")" "in"
# B社が持ち主でないファイル: A社がB⇔Aの会話で送って削除したPDF（A社の一覧には出る＝対照）
ok "A社: B⇔Aの会話にPDFを置ける"                    "$(up "$A" "$PAD" application/pdf "$TMP/a.pdf")" "200"
MAD=$(rpc "$A" v2_msg_send "$(j p_app "$APP" p_thread "$BID" p_body '=null' p_files "=$(files "$PAD" "ad.pdf")")" | msgid)
ok "…送って削除する"                                 "$(rpc "$A" v2_msg_delete "$(j p_id "$MAD")")" ""
ok "B社の消し残しの一覧には、A社が置いたファイルは出ない" "$(pend "$B" "$PAD")" "out"
ok "（対照）A社の消し残しの一覧には出る"             "$(pend "$A" "$PAD")" "in"
ok "後片付け: A社がそのファイルを消せる"             "$(rm_ "$A" "$PAD" >/dev/null; exists "$PAD")" "0"
ok "送った本人以外（A社の別CA）は、そのファイルを消せない" "$(rm_ "$C" "$PB" >/dev/null; exists "$PB")" "1"
ok "送った本人（B社）は、削除したメッセージのファイルを消せる（画面が削除のときに消す）" "$(rm_ "$B" "$PB" >/dev/null; exists "$PB")" "0"
ok "消した後は、消し残しの一覧から消える"            "$(pend "$B" "$PB")" "out"
ok "消した後も、送信済みの場所には置き直せない"      "$(c=$(up "$B" "$PB" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c"; )" "denied"
ok "（対照）その場所は空のまま"                      "$(exists "$PB")" "0"
# すり替え確認のメッセージも削除して、ファイルを消す
rpc "$B" v2_msg_delete "$(j p_id "$MM")" >/dev/null
ok "すり替え確認のメッセージを削除すると、そのファイルも本人が消せる" "$(rm_ "$B" "$PM" >/dev/null; exists "$PM")" "0"
ok "…消した後も、同じ場所に置き直せない"            "$(c=$(up "$B" "$PM" application/pdf "$TMP/a.png"); [ "$c" != 200 ] && echo denied || echo "allowed:$c")" "denied"
# 置き場の配信は、直前に開いたファイルや発行済みのURLをしばらく覚えていることがある（2026-10-19 実測で数秒〜30秒超）。
# 画面は「開くためのURL」で開くので、そのURLが実体の削除で使えなくなることを、5秒おき・最大120秒待って確かめる
sgone(){ local t=0; while :; do [ "$(surl "$1")" != 200 ] && { echo "$t"; return; }; [ $t -ge 120 ] && { echo never; return; }; sleep 5; t=$((t+5)); done; }
SG=$(sgone "$SURL")
echo "      （A社が受け取っていたURLが使えなくなるまで: ${SG}秒）"
ok "消した後は、A社が先に受け取っていたURLでも開けない（120秒以内に。実測 ${SG}秒）" "$([ "$SG" != never ] && echo denied || echo allowed)" "denied"
# ログイン中の取得（配信の覚えを避けるため、毎回違う問い合わせにする）: 置き場の実体も権限も無い
dlx(){ curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/v2-files/$2?nocache=$RANDOM$RANDOM" -H "apikey: $AK" -H "Authorization: Bearer $1"; }
ok "消した後はA社も開けない"                         "$([ "$(dlx "$A" "$PB")" != 200 ] && echo denied || echo allowed)" "denied"
ok "消した後は送ったB社も開けない"                   "$([ "$(dlx "$B" "$PB")" != 200 ] && echo denied || echo allowed)" "denied"
ok "後片付け: A社のテストのメッセージも削除し、ファイルも消す" "$(rpc "$A" v2_msg_delete "$(j p_id "$MA")"; rm_ "$A" "$PA" >/dev/null; exists "$PA")" "0"
NODE_CF=$(node --input-type=module -e "
import { checkChatFile, fmtSize } from './js/ui/chat-file-rules.js';
const t = (f) => { try { checkChatFile(f); return 'ok'; } catch (e) { return 'ng'; } };
console.log([t({ name: 'a.pdf', type: 'application/pdf', size: 10 }), t({ name: 'a.webp', type: 'image/webp', size: 10 }), t({ name: 'a.txt', type: 'text/plain', size: 10 }),
  t({ name: 'b.pdf', type: 'application/pdf', size: 10 * 1024 * 1024 + 1 }), t({ name: 'e.pdf', type: 'application/pdf', size: 0 }), fmtSize(1536), fmtSize(10485760)].join('/'));" 2>&1)
ok "画面: 送る前の確認（PDF・画像は可／テキスト・10MB超・空は不可）" "$NODE_CF" "ok/ok/ng/ng/ng/2KB/10.0MB"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
