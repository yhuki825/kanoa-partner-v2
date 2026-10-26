#!/usr/bin/env bash
# 求人のCSV一括登録（136 v2_jobs_import）のテスト。何度流してもよい（登録はすべて begin…rollback の中で確かめる）
# 前提（テストデータ）: 求人企業「テスト求人企業（自動削除予定）」の求人「テスト営業職（自動削除予定）」、1次パートナー A99999
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
# 関数が返した報酬の行の列（エラーならそのコード）: 使い方 col 列名|列名…
col(){ python3 -c 'import json,sys;d=json.load(sys.stdin);d=d[0] if isinstance(d,list) and d else d
print(("ERR:"+str(d.get("code"))) if isinstance(d,dict) and "code" in d and "pay_status" not in d else "|".join("" if d.get(k) is None else str(d.get(k)) for k in sys.argv[1].split("|")))' "$1"; }
# 一覧を「列|列,…」の文字列に（埋め込みは a.b で読む）: 使い方 rows 列|列…
rows(){ python3 -c 'import json,sys
d=json.load(sys.stdin)
def g(x,k):
  for p in k.split("."): x=(x or {}).get(p)
  return "" if x is None else str(x)
print(",".join("|".join(g(x,k) for k in sys.argv[1].split("|")) for x in d) if isinstance(d,list) else "ERR:"+str(d)[:120])' "$1"; }
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
A=$(login "$A_OWNER_ID" "$A_OWNER_PW")
ok "A社の代表でログインできる" "$([ -n "$A" ] && echo y)" "y"
RAUID=$(one "select user_id from v2_members where role='ra' and status='active' limit 1")
SET_RA="select set_config('request.jwt.claims','$(j sub "$RAUID" role authenticated)',true); set local role authenticated"
# 取り消し前提でRAとして呼ぶ（結果の JSON を返す）: imp 'JSON配列' true|false
imp(){ sql "begin; $SET_RA; select v2_jobs_import('$1'::jsonb, $2)::text r; rollback;"; }
res(){ python3 -c 'import json,sys;d=json.load(sys.stdin)
if isinstance(d,list) and d: d=json.loads(d[0]["r"]); print(sys.argv[1].format(**d) if "{" in sys.argv[1] else ",".join(str(r[sys.argv[1]]) for r in d["rows"]))
else: print("ERR:"+str(d)[:200])' "$1"; }
# 行ごとの「行番号:結果:理由の先頭」
rowsum(){ python3 -c 'import json,sys;d=json.load(sys.stdin);d=json.loads(d[0]["r"]) if isinstance(d,list) and d else None
print("ERR" if d is None else "|".join("%s:%s:%s" % (r["line"], r["result"], (r["messages"][0][:6] if r["messages"] else "")) for r in d["rows"]))'; }
# SQLのエラーコード（ERROR:  P0400: … の P0400）。エラーでなければ none
errc(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"ERROR:\s+([0-9A-Z]{5}):",d.get("message","")) if isinstance(d,dict) else None;print(m.group(1) if m else ("none" if isinstance(d,list) else "ERR:"+str(d)[:120]))'; }
NEWC="テスト一括登録会社（自動削除予定）"
OKROW='{"line":2,"client":"'$NEWC'","title":"一括A","description":"説明","fee":300000,"shares":"all","refund":[{"months":3,"rate":50},{"months":1,"rate":100}],"spi":true,"compliance":false,"flow":[],"entry_requirements":["phone","resume"]}'
OKROW2='{"line":3,"client":"'$NEWC'","title":"一括B","status":"一時停止","shares":["A99999"],"flow":["書類選考","面接"]}'
SKIPROW='{"line":4,"client":"テスト求人企業（自動削除予定）","title":"テスト営業職（自動削除予定）"}'
NACT=$(one "select count(*) from v2_companies where tier=1 and status='active'")

echo "== 権限 =="
ok "1次パートナー（A社の代表）は呼べない（P0403）" "$(rpc "$A" v2_jobs_import "$(j p_rows "=[$OKROW]" p_commit '=false')" | code)" "P0403"
ok "未ログインでは呼べない" "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_jobs_import" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_rows "=[$OKROW]" p_commit '=false')" | code)" "42501"

echo "== 確認だけ（登録しない） =="
ok "登録します2件・スキップ1件（登録済みの求人）" "$(imp "[$OKROW,$OKROW2,$SKIPROW]" false | res '{ok}/{skip}/{error}/{committed}')" "2/1/0/False"
ok "確認だけでは求人が増えない" "$(imp "[$OKROW]" false >/dev/null; one "select count(*) from v2_jobs j join v2_clients c on c.id=j.client_id where c.name='$NEWC'")" "0"
ok "空の求人企業・求人名はエラー" "$(imp '[{"line":5,"client":" ","title":""}]' false | rowsum)" "5:error:求人企業が空"
ok "状態の誤りはエラー" "$(imp '[{"line":6,"client":"x社","title":"y","status":"休止"}]' false | rowsum)" "6:error:状態は「募集"
ok "公開先に知らない会社コードはエラー" "$(imp '[{"line":7,"client":"x社","title":"y","shares":["Z99999"]}]' false | rowsum)" "7:error:公開先に1次"
ok "返金規定の範囲外（月数0）はエラー" "$(imp '[{"line":8,"client":"x社","title":"y","refund":[{"months":0,"rate":50}]}]' false | rowsum)" "8:error:返金規定の月"
ok "紹介料の小数はエラー" "$(imp '[{"line":9,"client":"x社","title":"y","fee":1.5}]' false | rowsum)" "9:error:紹介料は0以"
ok "知らない必須項目はエラー" "$(imp '[{"line":10,"client":"x社","title":"y","entry_requirements":["color"]}]' false | rowsum)" "10:error:エントリー時"
ok "ひな形の見本の行はエラー" "$(imp '[{"line":2,"client":"（例）株式会社サンプル","title":"y"}]' false | rowsum)" "2:error:ひな形の見本"
ok "CSVの中の重複は2つ目がエラー" "$(imp "[$OKROW,$(echo "$OKROW" | sed 's/"line":2/"line":7/')]" false | rowsum)" "2:ok:|7:error:CSVの中に"
ok "画面が見つけた誤りもエラーとして返す" "$(imp '[{"line":3,"client":"x社","title":"y","errors":["紹介料は半角数字で入れてください（abc）"]}]' false | rowsum)" "3:error:紹介料は半角"
ok "空のCSVは拒否（P0400）" "$(imp '[]' false | errc)" "P0400"

echo "== 登録 =="
BADROW='{"line":9,"client":"","title":""}'
ok "エラーの行があれば1件も登録しない（P0400）" "$(imp "[$OKROW,$BADROW]" true | errc)" "P0400"
ok "（対照）その後も求人は増えていない" "$(one "select count(*) from v2_jobs j join v2_clients c on c.id=j.client_id where c.name='$NEWC'")" "0"
REG="begin; $SET_RA; select v2_jobs_import('[$OKROW,$OKROW2,$SKIPROW]'::jsonb, true);"
ok "登録: 2件（同じ新しい求人企業は1社だけ作る）" \
  "$(sql "$REG select format('%s|%s', (select count(*) from v2_clients where name='$NEWC'), (select count(*) from v2_jobs j join v2_clients c on c.id=j.client_id where c.name='$NEWC')); rollback;" | first)" "1|2"
ok "登録: 一括A の中身（状態・選考フロー既定・必須項目・チェック）" \
  "$(sql "$REG select format('%s|%s|%s|%s', j.status, j.flow, j.entry_requirements, j.checks) from v2_jobs j where j.title='一括A'; rollback;" | first)" \
  'open|["書類選考", "一次面接", "二次面接", "最終面接", "内定", "入社"]|["name", "phone", "resume"]|{"spi": true, "compliance": false}'
ok "登録: 一括A の紹介料・公開先（全社＝利用中の1次全社）・返金規定（月数の順に並べ替え）" \
  "$(sql "$REG select format('%s|%s|%s', (select fee from v2_job_kanoa_fees f join v2_jobs j on j.id=f.job_id where j.title='一括A'), (select count(*) from v2_job_shares s join v2_jobs j on j.id=s.job_id where j.title='一括A' and s.published), (select policy from v2_job_refund_policies p join v2_jobs j on j.id=p.job_id where j.title='一括A')); rollback;" | first)" \
  "300000|$NACT|[{\"rate\": 100, \"months\": 1}, {\"rate\": 50, \"months\": 3}]"
ok "登録: 一括B は一時停止・公開先は A99999 だけ・紹介料と返金規定なし" \
  "$(sql "$REG select format('%s|%s|%s|%s|%s', j.status, j.flow, (select string_agg(co.code, ',') from v2_job_shares s join v2_companies co on co.id=s.company_id where s.job_id=j.id), (select count(*) from v2_job_kanoa_fees f where f.job_id=j.id), (select count(*) from v2_job_refund_policies p where p.job_id=j.id)) from v2_jobs j where j.title='一括B'; rollback;" | first)" \
  'paused|["書類選考", "面接"]|A99999|0|0'
ok "登録済みの求人は二重に作らない" \
  "$(sql "$REG select count(*)::text from v2_jobs j join v2_clients c on c.id=j.client_id where c.name='テスト求人企業（自動削除予定）' and j.title='テスト営業職（自動削除予定）'; rollback;" | first)" "1"
ok "取り消した後は何も残っていない" "$(one "select count(*) from v2_clients where name='$NEWC'")" "0"

echo "== 画面のCSV読み取り =="
NODE=$(node --input-type=module -e "
import { parseCsv, rowsToJobs, templateCsv, decodeCsvBytes } from './js/features/jobs/import-rules.js';
const t = rowsToJobs(parseCsv(templateCsv()));
const c = rowsToJobs(parseCsv('求人企業,求人名・職種,選考フロー,紹介料（基本額・円）,返金規定,SPI,公開先\r\nA社,\"営業,職\",\"書類選考\n面接\",\"300,000\",1か月以内100%／３ヶ月以内５０％,○,全社\r\n\r\nB社,事務,,abc,1か月,はい？,a00001/A00002\r\n')).rows;
console.log([t.fileErrors.length, t.rows[0].client, c.map(r=>r.line).join('+'), c[0].title, c[0].flow.join('>'), c[0].fee, JSON.stringify(c[0].refund), c[0].spi, c[0].shares, c[1].shares.join('/'), c[1].errors.length,
  rowsToJobs(parseCsv('会社,求人')).fileErrors.length, decodeCsvBytes(new Uint8Array([0x8b,0x81,0x90,0x6c]).buffer)].join(' '));" 2>&1)
ok "ひな形・セル内のカンマ/改行・全角数字・行番号・Shift_JIS を読める" "$NODE" \
  '0 （例）株式会社サンプル 2+4 営業,職 書類選考>面接 300000 [{"months":1,"rate":100},{"months":3,"rate":50}] true all A00001/A00002 3 2 求人'
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
