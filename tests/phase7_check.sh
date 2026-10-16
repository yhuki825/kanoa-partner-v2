#!/usr/bin/env bash
# 多段報酬（120・設計書14.1）のテスト。何度流してもよい
# 前提（テストデータ）: 求人「テスト営業職（自動削除予定）」（A99999に公開・基本額300000円・A99999のフロント向けの額160000円）、
#                       B社の「テスト次郎」の選考（B00001→A99999→KANOA、KANOA受入済み）
# 流れ: 次郎の選考と報酬を決まった状態に戻す → RAが段階を通過させて入社 → 段ごとの行（KANOA→A99999・A99999→B00001）を確かめる
#       → 見える範囲（会社ごと）→ A社の代表が「フロントへの支払い」を記録（支払済み・退職・差し引き・返金）→ 権限のない人の拒否
#       → 119 のレビュー Low 4件 → 最後に次郎を「入社済み・両方の段が支払待ち」にして残す（画面での確認用）
# 確かめるのは名指し（会社コード・金額）で。件数が増えても判定がぶれないようにする
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
# SQLのエラーコード（ERROR:  P0403: … の P0403）。エラーでなければ none
errc(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"ERROR:\s+([0-9A-Z]{5}):",d.get("message","")) if isinstance(d,dict) else None;print(m.group(1) if m else ("none" if isinstance(d,list) else "ERR:"+str(d)[:120]))'; }
# SQLのエラーで引っかかった制約の名前（エラーでなければ none）
cons(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"constraint \"([a-z0-9_]+)\"",d.get("message","")) if isinstance(d,dict) else None;print(m.group(1) if m else "none:"+str(d)[:120])'; }
# 画面と同じ経路（REST）のエラーの理由（hint）
rhint(){ python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("hint") if isinstance(d,dict) else "none")'; }
# SQLのエラーの理由（HINT）に、指定の文字が入っているか（yes/no）
hint_has(){ python3 -c 'import json,sys,re;d=json.load(sys.stdin);m=re.search(r"HINT:\s+(.*)",d.get("message","")) if isinstance(d,dict) else None;print("yes" if m and sys.argv[1] in m.group(1) else "no:"+(m.group(1) if m else str(d)[:120]))' "$1"; }

A=$(login "$A_OWNER_ID" "$A_OWNER_PW"); AC=$(login "$A_CA_ID" "$A_CA_PW"); B=$(login "$B_OWNER_ID" "$B_OWNER_PW")
ok "3アカウントでログインできる" "$([ -n "$A" ] && [ -n "$AC" ] && [ -n "$B" ] && echo y)" "y"
JIRO=$(one "select a.id from v2_applications a join v2_candidates c on c.id=a.candidate_id where c.name='テスト次郎'")
JOB=$(one "select id from v2_jobs where title='テスト営業職（自動削除予定）'")
ACO=$(one "select id from v2_companies where code='A99999'")
BCO=$(one "select id from v2_companies where code='B00001'")
LAST=$(one "select max(seq) from v2_milestones where application_id='$JIRO'")
RAUID=$(one "select user_id from v2_members where role='ra' and status='active' limit 1")
CLAIMS=$(j sub "$RAUID" role authenticated)
CLAIMS_A=$(j sub "$(one "select user_id from v2_members where company_id='$ACO' and is_owner and status='active' limit 1")" role authenticated)
CLAIMS_AC=$(j sub "$(one "select user_id from v2_members where company_id='$ACO' and not is_owner and status='active' limit 1")" role authenticated)
CLAIMS_B=$(j sub "$(one "select user_id from v2_members where company_id='$BCO' and is_owner and status='active' limit 1")" role authenticated)
# 誰として実行するか（ログイン中の本人と同じ権限の判定になる）
ra(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS',true); set local role authenticated; $1; commit;"; }
as_a(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; $1; commit;"; }
as_ac(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS_AC',true); set local role authenticated; $1; commit;"; }
as_b(){ sql "begin; select set_config('request.jwt.claims','$CLAIMS_B',true); set local role authenticated; $1; commit;"; }
POL='[{"months":1,"rate":100},{"months":3,"rate":50}]'
PV="(select version from v2_job_refund_policies where job_id='$JOB')"
# 次郎の段ごとの報酬の行: KW = KANOA→A99999（KANOAが払う）／FW = A99999→B00001（A社が払う＝フロントへの支払い）
KW="application_id='$JIRO' and payer_company_id is null"
FW="application_id='$JIRO' and payer_company_id='$ACO'"
FR="(select id from v2_rewards where $FW)"
# その行の今の version（121 から4つの操作は読んだときの version を渡す。古ければ P0409）
FV="(select version from v2_rewards where $FW)"
KV="(select version from v2_rewards where $KW)"
fv(){ one "select version from v2_rewards where $FW"; }
# 次郎の報酬を段の順に「支払う側>受け取る側|額」で（KANOAは KANOA と書く）
CHAIN="select coalesce(string_agg(format('%s>%s|%s', coalesce(pr.code,'KANOA'), pe.code, r.fee_amount), ',' order by pr.code nulls first), '') from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id left join v2_companies pr on pr.id=r.payer_company_id where r.application_id='$JIRO'"
# 次郎の段階を保存（RA）: ms 段階番号 日付（'YYYY-MM-DD' または null） 結果
ms(){ local d="null"; [ "$2" != "null" ] && d="'$2'::date"
  ra "select v2_milestone_save(m.id, m.version, $d, $d, '$3') from v2_milestones m where m.application_id='$JIRO' and m.seq=$1"; }
# 同じことを、トランザクションの中で続けて書く用（ra/as_a の外で使う）
MS_UNJOIN="select v2_milestone_save(m.id, m.version, null, null, 'pending') from v2_milestones m where m.application_id='$JIRO' and m.seq=$LAST"
MS_REJOIN="select v2_milestone_save(m.id, m.version, '2026-11-02', '2026-11-02', 'passed') from v2_milestones m where m.application_id='$JIRO' and m.seq=$LAST"
SET_RA="select set_config('request.jwt.claims','$CLAIMS',true); set local role authenticated"
# A99999→B00001 の行の状態: 額|支払の状態|支払日|支払った額|扱い|返金・差し引き額
fstate(){ one "select format('%s|%s|%s|%s|%s|%s', fee_amount, pay_status, paid_on, paid_amount, refund_mode, refund_amount) from v2_rewards where $FW"; }
# A社の代表として A99999→B00001 の退職を記録: 返金率|返金・差し引き額|返金の状態|扱い|支払の状態
fres(){ as_a "select format('%s|%s|%s|%s|%s', r.refund_rate, r.refund_amount, r.refund_status, r.refund_mode, r.pay_status) r from v2_reward_record_resignation($FR, $FV, $1) r"; }
# A社の代表として A99999→B00001 を支払済みにする（画面と同じく「今の支払額」を確認用に送る）
FPAYX="(select fee_amount - coalesce(case when refund_mode='deduct' then refund_amount end, 0) from v2_rewards where $FW)"
fpaid(){ as_a "select v2_reward_mark_paid($FR, $FV, '$1', $FPAYX)"; }
kstate(){ one "select format('%s|%s|%s', fee_amount, pay_status, resigned_on) from v2_rewards where $KW"; }
reset_jiro(){ sql "delete from v2_rewards where application_id='$JIRO';
  update v2_milestones set result='pending', done_on=null, scheduled_on=null, version=version where application_id='$JIRO' and seq>1;
  update v2_milestones set result='passed', done_on='2026-10-20', scheduled_on='2026-10-20', version=version where application_id='$JIRO' and seq=1;
  update v2_applications set stage='active', result=null, version=version where id='$JIRO';"; }
join_jiro(){ ms 2 2026-10-22 passed | errc; ms 3 2026-10-26 passed | errc; ms 4 2026-10-28 passed | errc; ms "$LAST" 2026-11-02 passed | errc; }

echo "== 準備（次郎の選考を決まった状態に戻し、入社まで進める） =="
ok "次郎の選考と報酬を最初の状態に戻せた"     "$(reset_jiro)" "[]"
ok "A99999 のフロント向けの額は 160000（前提）" "$(one "select fee_display from v2_job_offers where job_id='$JOB' and company_id='$ACO'")" "160000"
ok "RA: 返金規定を 1か月以内100%・3か月以内50% にする" "$(ra "select (v2_job_refund_policy_save('$JOB', '$POL'::jsonb, $PV) = '$POL'::jsonb)::text r" | first)" "true"
ok "RA: 入社まで通過（4段階）"                "$(join_jiro | tr '\n' ' ')" "none none none none "

echo "== 入社で段ごとの報酬が記録される =="
ok "次郎の報酬は KANOA→A99999（300000）と A99999→B00001（160000）" "$(one "$CHAIN")" "KANOA>A99999|300000,A99999>B00001|160000"
ok "A99999→B00001: 入社日・返金規定（KANOAの規定）・支払待ち・退職なし" \
  "$(one "select format('%s|%s|%s|%s', joined_on, (refund_policy = '$POL'::jsonb)::text, pay_status, resigned_on) from v2_rewards where $FW")" "2026-11-02|true|pending|"
ok "A99999→B00001 の額は入社後にフロント向けの額を変えても変わらない（変更は取り消す）" \
  "$(sql "begin; update v2_job_offers set fee_display=1, version=version where job_id='$JOB' and company_id='$ACO'; select fee_amount::text r from v2_rewards where $FW; rollback;" | first)" "160000"
ok "額は入社確定の時点のもの: 表示額 170000 にしてから入社し直すと 170000（変更は取り消す）" \
  "$(sql "begin; update v2_job_offers set fee_display=170000, version=version where job_id='$JOB' and company_id='$ACO'; $SET_RA; $MS_UNJOIN; $MS_REJOIN; $CHAIN; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|170000"
ok "フロント向けの額が無い段は行を作らない（額を作り出さない。変更は取り消す）" \
  "$(sql "begin; delete from v2_job_offers where job_id='$JOB' and company_id='$ACO'; $SET_RA; $MS_UNJOIN; $MS_REJOIN; $CHAIN; rollback;" | first)" "KANOA>A99999|300000"
ok "公開を止めていても、設定された額で作る（変更は取り消す）" \
  "$(sql "begin; update v2_job_offers set published=false, version=version where job_id='$JOB' and company_id='$ACO'; $SET_RA; $MS_UNJOIN; $MS_REJOIN; $CHAIN; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|160000"
ok "取り消した後も次郎の報酬は2段のまま"      "$(one "$CHAIN")" "KANOA>A99999|300000,A99999>B00001|160000"
# v2_reward_make_chain そのもので3段を作る: B00001 の下に3次 C99999 を作り、経路（選考の関係会社）に C99999 を足し、
# B00001 のフロント向けの額 50000 を置いて、A99999→B00001 の行を消してから作り直す（すべて取り消す）
THREE="insert into v2_companies(code, tier, parent_id, name) values ('C99999', 3, '$BCO', '一時テスト3次（取り消し）');
  insert into v2_application_parties values ('$JIRO', (select id from v2_companies where code='C99999'));
  insert into v2_job_offers(job_id, company_id, fee_display) values ('$JOB', '$BCO', 50000)
    on conflict (job_id, company_id) do update set fee_display=50000, version=v2_job_offers.version;
  delete from v2_rewards where $FW; select v2_reward_make_chain('$JIRO')"
ok "v2_reward_make_chain: 経路 C99999→B00001→A99999 で3段を作る（取り消す）" \
  "$(sql "begin; $THREE; $CHAIN; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|160000,B00001>C99999|50000"
ok "3段目の入社日・返金規定は KANOA→A99999 の行と同じ（取り消す）" \
  "$(sql "begin; $THREE; select format('%s|%s', r.joined_on, (r.refund_policy = k.refund_policy)::text) from v2_rewards r join v2_rewards k on k.application_id=r.application_id and k.payer_company_id is null where r.application_id='$JIRO' and r.payee_company_id=(select id from v2_companies where code='C99999'); rollback;" | first)" "2026-11-02|true"
# 直上の会社が経路にいない会社は対象外: A99999 の下に別の2次 B99998、その下に3次 C99998 を作り、経路には C99998 だけ足す
# （B99998 のフロント向けの額はあるが、B99998 が経路にいないので B99998→C99998 の行は作らない）
ok "v2_reward_make_chain: 直上の会社が経路にいない段は作らない（取り消す）" \
  "$(sql "begin; insert into v2_companies(code, tier, parent_id, name) values ('B99998', 2, '$ACO', '一時テスト2次（取り消し）');
    insert into v2_companies(code, tier, parent_id, name) values ('C99998', 3, (select id from v2_companies where code='B99998'), '一時テスト3次（取り消し）');
    insert into v2_application_parties values ('$JIRO', (select id from v2_companies where code='C99998'));
    insert into v2_job_offers(job_id, company_id, fee_display) values ('$JOB', (select id from v2_companies where code='B99998'), 40000);
    delete from v2_rewards where $FW; select v2_reward_make_chain('$JIRO'); $CHAIN; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|160000"
ok "取り消した後も次郎の報酬は2段のまま（3段の確認の後）" "$(one "$CHAIN")" "KANOA>A99999|300000,A99999>B00001|160000"

echo "== 見える範囲（会社ごと） =="
ok "A社の代表: 受け取る分（KANOAから）と支払う分（B00001へ）の両方が見える" \
  "$(get "$A" "v2_rewards?select=fee_amount,payee:v2_companies!v2_rewards_payee_company_id_fkey(code)&application_id=eq.$JIRO&order=fee_amount.desc" | rows 'payee.code|fee_amount')" "A99999|300000,B00001|160000"
ok "A社の代表でないCAも両方が見える（閲覧）"  \
  "$(get "$AC" "v2_rewards?select=fee_amount,payee:v2_companies!v2_rewards_payee_company_id_fkey(code)&application_id=eq.$JIRO&order=fee_amount.desc" | rows 'payee.code|fee_amount')" "A99999|300000,B00001|160000"
ok "B社: 次郎の報酬は自社が受け取る分（160000）だけ" \
  "$(get "$B" "v2_rewards?select=fee_amount,payee:v2_companies!v2_rewards_payee_company_id_fkey(code)&application_id=eq.$JIRO" | rows 'payee.code|fee_amount')" "B00001|160000"
ok "B社: KANOAが払う行は1行も見えない"         "$(get "$B" 'v2_rewards?select=id&payer_company_id=is.null' | len)" "0"
ok "B社: 見える行はすべて自社が受け取る分か、自社が払う分" \
  "$(get "$B" 'v2_rewards?select=payee_company_id,payer_company_id' | python3 -c "import json,sys;d=json.load(sys.stdin);print('OK' if isinstance(d,list) and all('$BCO' in (x['payee_company_id'], x['payer_company_id']) for x in d) else 'NG:'+str(d)[:120])")" "OK"
ok "B社: 選考から報酬をたどっても KANOA→A99999 の額（300000）は出ない" \
  "$(get "$B" "v2_applications?select=reward:v2_rewards!v2_rewards_application_id_fkey(fee_amount)&id=eq.$JIRO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join(str(x["fee_amount"]) for x in d[0]["reward"]) if isinstance(d,list) and d else "ERR:"+str(d)[:120])')" "160000"
ok "B社の報酬画面の問い合わせ（受け取る分）: 求職者・求人・額が読める" \
  "$(get "$B" "v2_rewards?select=fee_amount,candidate:v2_candidates!v2_rewards_candidate_id_fkey(name),job:v2_jobs!v2_rewards_job_id_fkey(title)&payee_company_id=eq.$BCO&application_id=eq.$JIRO" | rows 'candidate.name|job.title|fee_amount')" "テスト次郎|テスト営業職（自動削除予定）|160000"
ok "A社のパートナー管理の問い合わせ（支払う分）: 支払先・求職者・額が読める" \
  "$(get "$A" "v2_rewards?select=fee_amount,company:v2_companies!v2_rewards_payee_company_id_fkey(code),candidate:v2_candidates!v2_rewards_candidate_id_fkey(name)&payer_company_id=eq.$ACO&application_id=eq.$JIRO" | rows 'company.code|candidate.name|fee_amount')" "B00001|テスト次郎|160000"
# 他の組の行: B社の下に3次（C99999）がいるとして B→C の行を足し（取り消す）、A社から見えないこと・B社には見えることを確かめる
PAIR_SETUP="insert into v2_companies(code, tier, parent_id, name) values ('C99999', 3, '$BCO', '一時テスト3次（取り消し）');
  insert into v2_rewards(application_id, payer_company_id, payee_company_id, job_id, candidate_id, joined_on, fee_amount)
  select application_id, payee_company_id, (select id from v2_companies where code='C99999'), job_id, candidate_id, joined_on, 7000 from v2_rewards where $FW"
PAIR_Q="select coalesce(string_agg(format('%s>%s|%s', coalesce(pr.code,'KANOA'), pe.code, r.fee_amount), ',' order by pr.code nulls first), '') from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id left join v2_companies pr on pr.id=r.payer_company_id where r.application_id='$JIRO'"
ok "（対照）RAには3段とも見える（取り消す）"   "$(sql "begin; $PAIR_SETUP; $SET_RA; $PAIR_Q; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|160000,B00001>C99999|7000"
ok "A社からは B→C（他の組）の行が見えない（取り消す）" \
  "$(sql "begin; $PAIR_SETUP; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; $PAIR_Q; rollback;" | first)" "KANOA>A99999|300000,A99999>B00001|160000"
ok "B社には自社が受け取る分と自社が払う分だけ見える（取り消す）" \
  "$(sql "begin; $PAIR_SETUP; select set_config('request.jwt.claims','$CLAIMS_B',true); set local role authenticated; select coalesce(string_agg(format('%s|%s', pe.code, r.fee_amount), ',' order by r.fee_amount desc), '') from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id where r.application_id='$JIRO'; rollback;" | first)" "B00001|160000,C99999|7000"
ok "B社の直上の会社は A99999（報酬画面の説明に出す）" "$(rpc "$B" v2_my_upline '{}' | rows 'code')" "A99999"
ok "A社（1次）には直上の会社の行が無い（KANOA）"     "$(rpc "$A" v2_my_upline '{}' | len)" "0"
ok "未ログインでは直上の会社を読めない"               "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_my_upline" -H "apikey: $AK" -H 'Content-Type: application/json' -d '{}' | code)" "42501"

echo "== フロントへの支払い: 権限 =="
FRID=$(one "select id from v2_rewards where $FW")
KRID=$(one "select id from v2_rewards where $KW")
# 画面と同じく「行ID＋今の version」を送る（使い方: jf キー 値 …）
jf(){ j p_reward "$FRID" p_version "=$(fv)" "$@"; }
jk(){ j p_reward "$KRID" p_version "=$(one "select version from v2_rewards where $KW")" "$@"; }
ok "A社の代表でないCAは支払済みにできない"    "$(rpc "$AC" v2_reward_mark_paid "$(jf p_paid_on 2026-11-30 p_expected_payable '=160000')" | code)" "P0403"
ok "B社（受け取る側）は支払済みにできない"     "$(rpc "$B" v2_reward_mark_paid "$(jf p_paid_on 2026-11-30 p_expected_payable '=160000')" | code)" "P0403"
ok "RAもフロントへの支払いは記録できない"     "$(ra "select v2_reward_mark_paid($FR, $FV, '2026-11-30', 160000)" | errc)" "P0403"
ok "B社は退職を記録できない"                   "$(rpc "$B" v2_reward_record_resignation "$(jf p_resigned_on 2026-11-22)" | code)" "P0403"
ok "A社の代表でないCAは退職を記録できない"    "$(as_ac "select v2_reward_record_resignation($FR, $FV, '2026-11-22')" | errc)" "P0403"
ok "A社の代表も KANOA→A99999 の行は記録できない" "$(rpc "$A" v2_reward_mark_paid "$(jk p_paid_on 2026-11-30 p_expected_payable '=300000')" | code)" "P0403"
ok "未ログインでは支払済みの関数を呼べない"   "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_reward_mark_paid" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(jf p_paid_on 2026-11-30 p_expected_payable '=160000')" | code)" "42501"
ok "報酬の表を直接書き換えられない（A社の代表）" "$(curl -s -X PATCH "$BASE/rest/v1/v2_rewards?id=eq.$FRID" -H "apikey: $AK" -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d "$(j pay_status paid)" | code)" "42501"
ok "拒否の後も A99999→B00001 は支払待ちのまま" "$(fstate)" "160000|pending||||"

echo "== 楽観ロックと、行の有無を漏らさない返事（121） =="
OLDV=$(fv)
ok "A社の代表: 古い version では支払済みにできない（P0409）" "$(rpc "$A" v2_reward_mark_paid "$(j p_reward "$FRID" p_version "=$((OLDV - 1))" p_paid_on 2026-11-30 p_expected_payable '=160000')" | code)" "P0409"
ok "A社の代表: 読んだ version で退職を記録できる（2か月後・差し引き）" "$(rpc "$A" v2_reward_record_resignation "$(j p_reward "$FRID" p_version "=$OLDV" p_resigned_on 2027-01-02)" | col 'refund_mode|refund_amount')" "deduct|80000"
ok "記録すると version が1つ上がる"            "$(fv)" "$((OLDV + 1))"
ok "古い画面（記録前の version）からは退職の記録を消せない（P0409）" "$(rpc "$A" v2_reward_record_resignation "$(j p_reward "$FRID" p_version "=$OLDV" p_resigned_on '=null')" | code)" "P0409"
ok "拒否の後も退職の記録は残る"                "$(fstate)" "160000|pending|||deduct|80000"
ok "A社の代表: 今の version なら退職の記録を消せる" "$(rpc "$A" v2_reward_record_resignation "$(jf p_resigned_on '=null')" | col 'pay_status|refund_mode')" "pending|"
NOID=$(one "select gen_random_uuid()")
ok "A社の代表: 無い行IDは P0403（行の有無を漏らさない）" "$(rpc "$A" v2_reward_unmark_paid "$(j p_reward "$NOID" p_version '=1')" | code)" "P0403"
ok "無い行と、権限の無い行（B社から A99999→B00001 の行）で理由も同じ" \
  "$([ "$(rpc "$A" v2_reward_unmark_paid "$(j p_reward "$NOID" p_version '=1')" | rhint)" = "$(rpc "$B" v2_reward_unmark_paid "$(jf)" | rhint)" ] && echo same || echo differ)" "same"
ok "RA: 無い行IDは P0409（画面の読み込み直しを促す）" "$(ra "select v2_reward_unmark_paid('$NOID', 1)" | errc)" "P0409"
ok "RA: 消えた行（同時に入社を取り消した等）への操作は成功にならない（P0409・取り消す）" \
  "$(sql "begin; delete from v2_rewards where id='$KRID'; $SET_RA; select v2_reward_mark_paid('$KRID', 1, '2026-11-30', 300000); rollback;" | errc)" "P0409"
ok "A社の代表: 消えた行への操作も成功にならない（P0403・取り消す）" \
  "$(sql "begin; delete from v2_rewards where id='$FRID'; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; select v2_reward_unmark_paid('$FRID', 1); rollback;" | errc)" "P0403"
ok "取り消した後も2段とも支払待ちのまま"        "$(one "$CHAIN")|$(fstate)" "KANOA>A99999|300000,A99999>B00001|160000|160000|pending||||"

echo "== フロントへの支払い: A社の代表が記録する =="
ok "A社の代表: 支払済みにする（画面と同じ経路）" "$(rpc "$A" v2_reward_mark_paid "$(jf p_paid_on 2026-11-30 p_expected_payable '=160000')" | col 'pay_status|paid_amount')" "paid|160000"
ok "支払済み・支払った額 160000"               "$(fstate)" "160000|paid|2026-11-30|160000||"
ok "KANOA→A99999 は支払待ちのまま（段ごとに別）" "$(kstate)" "300000|pending|"
ok "B社から支払済みが見える"                   "$(get "$B" "v2_rewards?select=pay_status,paid_amount&id=eq.$FRID" | rows 'pay_status|paid_amount')" "paid|160000"
ok "二重に支払済みにはできない（P0409）"       "$(fpaid 2026-12-01 | errc)" "P0409"
ok "A社の代表でないCAは支払済みを取り消せない" "$(rpc "$AC" v2_reward_unmark_paid "$(jf)" | code)" "P0403"
ok "B社は支払済みを取り消せない"               "$(rpc "$B" v2_reward_unmark_paid "$(jf)" | code)" "P0403"
ok "RAは支払済みを取り消せない"                "$(ra "select v2_reward_unmark_paid($FR, $FV)" | errc)" "P0403"
ok "フロントへの支払いが支払済みの間は、RAが入社日を直せない（P0409）" "$(ms "$LAST" 2026-11-05 passed | errc)" "P0409"
ok "そのときの理由に、支払った会社（A99999）が出る" "$(ms "$LAST" 2026-11-05 passed | hint_has A99999)" "yes"
ok "フロントへの支払いが支払済みの間は、RAが入社を取り消せない（P0409）" "$(ms "$LAST" null pending | errc)" "P0409"
ok "拒否の後も報酬は2段とも元のまま"            "$(one "select format('%s|%s', (select joined_on from v2_rewards where $KW), (select joined_on from v2_rewards where $FW))")" "2026-11-02|2026-11-02"
ok "A社の代表: 支払済みを取り消す（返る支払の状態は支払待ち）" "$(rpc "$A" v2_reward_unmark_paid "$(jf)" | col 'pay_status')" "pending"
ok "支払日・支払った額も消える"                 "$(fstate)" "160000|pending||||"

echo "== フロントへの支払い: 支払前の退職＝差し引き（規定 1か月以内100%・3か月以内50%） =="
ok "A社の代表: 2か月後の退職 → 50%・差し引き 80000・支払待ち" "$(fres "'2027-01-02'::date" | first)" "50|80000||deduct|pending"
ok "KANOA→A99999 には反映しない（自動で連動しない）" "$(kstate)" "300000|pending|"
ok "表示と違う支払額（160000）では支払済みにできない（P0409）" "$(as_a "select v2_reward_mark_paid($FR, $FV, '2027-01-10', 160000)" | errc)" "P0409"
ok "差し引き: 退職日より前の支払日は拒否される（P0400）" "$(fpaid 2026-12-01 | errc)" "P0400"
ok "A社の代表: 差し引き後の額で支払済みにする" "$(fpaid 2027-01-10 | errc)" "none"
ok "支払った額 80000（差し引き後）"             "$(fstate)" "160000|paid|2027-01-10|80000|deduct|80000"
ok "B社から差し引き後の支払額が見える"          "$(get "$B" "v2_rewards?select=paid_amount,refund_mode,refund_amount&id=eq.$FRID" | rows 'paid_amount|refund_mode|refund_amount')" "80000|deduct|80000"
ok "差し引き後の額で支払済みのあとは退職を消せない（P0409）" "$(fres "null::date" | errc)" "P0409"
ok "A社の代表: 支払済みを取り消す"              "$(as_a "select v2_reward_unmark_paid($FR, $FV)" | errc)" "none"
ok "A社の代表: 1か月以内の退職に直す → 100%・支払なし" "$(fres "'2026-11-22'::date" | first)" "100|160000||deduct|cancelled"
ok "支払なしは支払済みにできない（P0409）"      "$(fpaid 2026-11-30 | errc)" "P0409"
ok "A社の代表: 退職の記録を消す → 支払待ちに戻る" "$(fres "null::date" | first)" "||||pending"
ok "全額の支払待ちに戻る"                       "$(fstate)" "160000|pending||||"

echo "== フロントへの支払い: 支払後の退職＝返金 =="
ok "A社の代表: 支払済みにする"                  "$(fpaid 2026-11-30 | errc)" "none"
ok "A社の代表: 支払後に20日後の退職 → 返金待ち 160000" "$(fres "'2026-11-22'::date" | first)" "100|160000|pending|refund|paid"
ok "返金待ちの間は支払済みを取り消せない（P0409）" "$(as_a "select v2_reward_unmark_paid($FR, $FV)" | errc)" "P0409"
ok "B社は返金済みにできない"                    "$(rpc "$B" v2_reward_mark_refunded "$(jf p_refunded_on 2026-12-10)" | code)" "P0403"
ok "返金日が支払日より前は拒否される（P0400）"  "$(as_a "select v2_reward_mark_refunded($FR, $FV, '2026-11-29')" | errc)" "P0400"
ok "A社の代表: 返金済みにする"                  "$(rpc "$A" v2_reward_mark_refunded "$(jf p_refunded_on 2026-12-10)" | col 'refund_status|refunded_on')" "refunded|2026-12-10"
ok "B社から返金済みが見える"                    "$(get "$B" "v2_rewards?select=refund_status,refund_amount&id=eq.$FRID" | rows 'refund_status|refund_amount')" "refunded|160000"
ok "KANOA→A99999 は支払待ち・退職なしのまま"    "$(kstate)" "300000|pending|"
ok "フロントへの支払いに退職がある間は、RAが入社日を直せない（P0409・理由に A99999）" "$(ms "$LAST" 2026-11-05 passed | hint_has A99999)" "yes"

echo "== 119 のレビュー Low 4件 =="
# 準備: 次郎を入社し直して、2段ともまっさらな支払待ちにする（返金済みの行は関数では戻せないため）
ok "準備: 次郎をいったん戻して入社し直す"       "$(reset_jiro)$(join_jiro | tr '\n' ' ')" "[]none none none none "
ok "準備: 2段とも支払待ち"                       "$(one "$CHAIN")" "KANOA>A99999|300000,A99999>B00001|160000"
ok "a) 0円の行は支払済みにできない: フロントへの支払い（P0400・変更は取り消す）" \
  "$(sql "begin; update v2_rewards set fee_amount=0, version=version where $KW or $FW; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; select v2_reward_mark_paid($FR, $FV, '2026-11-30', 0); rollback;" | errc)" "P0400"
ok "a) 0円の行は支払済みにできない: KANOA→1次（P0400・変更は取り消す）" \
  "$(sql "begin; update v2_rewards set fee_amount=0, version=version where $KW; $SET_RA; select v2_reward_mark_paid((select id from v2_rewards where $KW), $KV, '2026-11-30', 0); rollback;" | errc)" "P0400"
NODE_A=$(node --input-type=module -e "
import { actionsOf } from './js/ui/reward-rows.js';
const k = (r) => actionsOf(r).map((a) => a[0]).join('+');
console.log(k({ pay_status: 'pending', fee_amount: '0' }) + '/' + k({ pay_status: 'pending', fee_amount: '160000' }));" 2>&1)
ok "a) 画面: 0円の行には「支払済みにする」が出ない（対照: 160000 の行には出る）" "$NODE_A" "resign/paid+resign"
ok "b) 返金の扱いで支払待ちの行は作れない（制約 v2_rewards_refund_paid）" \
  "$(sql "begin; update v2_rewards set resigned_on=joined_on, refund_rate=0, refund_amount=0, refund_mode='refund', refund_status=null, refunded_on=null, version=version where application_id='$JIRO' and payer_company_id is null; rollback;" | cons)" "v2_rewards_refund_paid"
ok "b) （対照）返金の扱いで支払済みの行は作れる（取り消す）" \
  "$(sql "begin; update v2_rewards set resigned_on=joined_on, refund_rate=0, refund_amount=0, refund_mode='refund', pay_status='paid', paid_on=joined_on, paid_amount=fee_amount, version=version where $KW; select refund_mode||'|'||pay_status r from v2_rewards where $KW; rollback;" | first)" "refund|paid"
ok "c) A社の代表: 2026-11-30 に支払済み"        "$(fpaid 2026-11-30 | errc)" "none"
ok "c) 支払後・4か月後の退職 → 返金の扱い・返金0円" "$(fres "'2027-03-02'::date" | first)" "0|0||refund|paid"
ok "c) 支払済みを取り消す → 差し引き0円の支払待ち" "$(as_a "select format('%s|%s|%s', r.refund_mode, r.pay_status, r.refund_amount) r from v2_reward_unmark_paid($FR, $FV) r" | first)" "deduct|pending|0"
ok "c) 本来の支払日（2026-11-30・退職日より前）で支払済みに戻せる" "$(fpaid 2026-11-30 | errc)" "none"
ok "c) 取り消す前の形（返金の扱い・支払済み・160000）に戻る" "$(fstate)" "160000|paid|2026-11-30|160000|refund|0"
ok "c) 戻した後は退職日を直せる（返金の扱い）"  "$(fres "'2026-11-22'::date" | first)" "100|160000|pending|refund|paid"
ok "c) A社の代表: 退職の記録を消す"            "$(fres "null::date" | first)" "||||paid"
ok "c) （対照）差し引きがある（80000）と、退職日より前の支払日は今までどおり拒否" \
  "$(as_a "select v2_reward_unmark_paid($FR, $FV)" | errc)|$(fres "'2027-01-02'::date" | first)|$(fpaid 2026-12-01 | errc)" "none|50|80000||deduct|pending|P0400"
ok "d) 取り消しで「支払なし」になる行は、返る支払の状態が cancelled（0円の旧データを再現・取り消す）" \
  "$(sql "begin; update v2_rewards set fee_amount=0, resigned_on=null, refund_rate=null, refund_amount=null, refund_mode=null, version=version where $FW; update v2_rewards set pay_status='paid', paid_on='2026-11-30', paid_amount=0, resigned_on='2027-03-02', refund_rate=0, refund_amount=0, refund_mode='refund', version=version where $FW; select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated; select r.pay_status from v2_reward_unmark_paid($FR, $FV) r; rollback;" | first)" "cancelled"
NODE_D=$(node --input-type=module -e "
import { unpaidToast } from './js/ui/reward-rows.js';
console.log(unpaidToast({ pay_status: 'cancelled' }) + '/' + unpaidToast({ pay_status: 'pending' }));" 2>&1)
ok "d) 画面: 取り消し後の知らせは返った支払の状態に合わせる" "$NODE_D" "支払済みを取り消しました（支払はありません）/支払待ちに戻しました"

# 画面で試せるように、次郎を「入社済み・2段とも支払待ち・退職なし」にして残す（次に流すときは最初に戻す）
ok "後片付け: 次郎をいったん戻して入社し直す"   "$(reset_jiro)$(join_jiro | tr '\n' ' ')" "[]none none none none "
ok "画面確認用: KANOA→A99999 300000・A99999→B00001 160000（どちらも支払待ち・退職なし）" \
  "$(one "select string_agg(format('%s>%s|%s|%s|%s|%s', coalesce(pr.code,'KANOA'), pe.code, r.fee_amount, r.pay_status, r.resigned_on, r.paid_amount), ',' order by pr.code nulls first) from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id left join v2_companies pr on pr.id=r.payer_company_id where r.application_id='$JIRO'")" \
  "KANOA>A99999|300000|pending||,A99999>B00001|160000|pending||"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
