#!/usr/bin/env bash
# 多段報酬の運用ルール（122・設計書14.1。2026-10-16 ユーザー決定「全部推奨どおり」）のテスト。何度流してもよい
#  1) 退職の自動反映（下の段へ。消すときは同じ日付の行だけ。額が確定した行は動かさない）
#  2) フロント向けの額が未設定 → 0円（未設定）の行 → 支払う側が「紹介料を入れる」
#  3) 支払う会社が記録できない状態（利用停止中・利用中の代表者なし）→ RAが代わりに記録できる
#  4) 123（レビュー修正）: 退職の記録は選考の行を先にロック／記録の無い行の「消す」で下の段を動かさない ほか
# 前提・準備・後片付けは第7段階と同じ（最後に次郎を「入社済み・2段とも支払待ち・退職なし」にして残す）
# 変更はできるだけ begin…rollback の中で確かめる（本物の行を動かすものは最後に戻す）
# 書き込む関数を呼ぶ確認は、拒否される想定でも必ず begin…rollback の中で（$SET_A/$SET_RA）。ra/as_a は commit するので、
# 守りが壊れたときに本物の行へ書き込んでしまう（ra/as_a で書くのは、準備・後片付けの返金規定と段階の保存だけ）
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
# A99999→B00001 の今の支払額（画面と同じく、支払済みにするときに確認用に送る）
FPAYX="(select fee_amount - coalesce(case when refund_mode='deduct' then refund_amount end, 0) from v2_rewards where $FW)"
kstate(){ one "select format('%s|%s|%s', fee_amount, pay_status, resigned_on) from v2_rewards where $KW"; }
reset_jiro(){ sql "delete from v2_rewards where application_id='$JIRO';
  update v2_milestones set result='pending', done_on=null, scheduled_on=null, version=version where application_id='$JIRO' and seq>1;
  update v2_milestones set result='passed', done_on='2026-10-20', scheduled_on='2026-10-20', version=version where application_id='$JIRO' and seq=1;
  update v2_applications set stage='active', result=null, version=version where id='$JIRO';"; }
join_jiro(){ ms 2 2026-10-22 passed | errc; ms 3 2026-10-26 passed | errc; ms 4 2026-10-28 passed | errc; ms "$LAST" 2026-11-02 passed | errc; }

KR="(select id from v2_rewards where $KW)"
# 誰として続きを実行するか（ログイン中の本人と同じく、RLSも効く role で）
SET_A="select set_config('request.jwt.claims','$CLAIMS_A',true); set local role authenticated"
SET_B="select set_config('request.jwt.claims','$CLAIMS_B',true); set local role authenticated"
SET_AC="select set_config('request.jwt.claims','$CLAIMS_AC',true); set local role authenticated"
SET_RA2="select set_config('request.jwt.claims','$CLAIMS',true)"
# RAとして KANOA→A99999 の退職を記録（トランザクションの中で続けて書く用。日付は 'YYYY-MM-DD'::date か null::date）
KRES(){ echo "select v2_reward_record_resignation($KR, $KV, $1)"; }
FRES(){ echo "select v2_reward_record_resignation($FR, $FV, $1)"; }
FPAID(){ echo "select v2_reward_mark_paid($FR, $FV, '$1', $FPAYX)"; }
# A99999→B00001 の退職まわり: 退職日|返金率|額|扱い|支払の状態|返金の状態
FST="select format('%s|%s|%s|%s|%s|%s', resigned_on, refund_rate, refund_amount, refund_mode, pay_status, refund_status) from v2_rewards where $FW"
# フロント向けの額を消してから入社し直す（A99999→B00001 が0円＝未設定になる）
NOFEE="delete from v2_job_offers where job_id='$JOB' and company_id='$ACO'; $SET_RA; $MS_UNJOIN; $MS_REJOIN"
# 3段（第7段階と同じ: B00001 の下に C99999、B00001 のフロント向けの額 50000）
THREE="insert into v2_companies(code, tier, parent_id, name) values ('C99999', 3, '$BCO', '一時テスト3次（取り消し）');
  insert into v2_application_parties values ('$JIRO', (select id from v2_companies where code='C99999'));
  insert into v2_job_offers(job_id, company_id, fee_display) values ('$JOB', '$BCO', 50000)
    on conflict (job_id, company_id) do update set fee_display=50000, version=v2_job_offers.version;
  delete from v2_rewards where $FW; select v2_reward_make_chain('$JIRO')"
SUSPEND_A="update v2_companies set status='suspended', version=version where id='$ACO'"
NO_OWNER_A="update v2_members set status='suspended', version=version where company_id='$ACO' and is_owner"

echo "== 準備（次郎の選考を決まった状態に戻し、入社まで進める） =="
ok "次郎の選考と報酬を最初の状態に戻せた"     "$(reset_jiro)" "[]"
ok "RA: 返金規定を 1か月以内100%・3か月以内50% にする" "$(ra "select (v2_job_refund_policy_save('$JOB', '$POL'::jsonb, $PV) = '$POL'::jsonb)::text r" | first)" "true"
ok "RA: 入社まで通過（4段階）"                "$(join_jiro | tr '\n' ' ')" "none none none none "
ok "次郎の報酬は2段（前提）"                  "$(one "$CHAIN")" "KANOA>A99999|300000,A99999>B00001|160000"

echo "== 1) 退職の自動反映 =="
ok "RAが退職を記録（2026-11-22・支払前）→ 下の段も同じ日・100%・全額差し引き＝支払なし（取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "'2026-11-22'::date"); $FST; rollback;" | first)" "2026-11-22|100|160000|deduct|cancelled|"
ok "RAが退職日を 2027-01-02 に直す → 下の段も 50%・80000 差し引き・支払待ち（取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "'2026-11-22'::date"); $(KRES "'2027-01-02'::date"); $FST; rollback;" | first)" "2027-01-02|50|80000|deduct|pending|"
ok "RAが退職の記録を消す → 下の段も消える（取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "'2026-11-22'::date"); $(KRES "null::date"); $FST; rollback;" | first)" "||||pending|"
ok "（対照）反映しなかった場合の形: 下の段だけに記録すると上の段は動かない（取り消す）" \
  "$(sql "begin; $SET_A; $(FRES "'2026-11-22'::date"); select format('%s|%s', (select resigned_on from v2_rewards where $KW), (select resigned_on from v2_rewards where $FW)); rollback;" | first)" "|2026-11-22"
ok "消すときは同じ日付の行だけ: 下の段が独自に直した日付（2027-01-10）は残る（取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "'2027-01-02'::date"); $SET_A; $(FRES "'2027-01-10'::date"); $SET_RA2; $(KRES "null::date"); $FST; rollback;" | first)" "2027-01-10|50|80000|deduct|pending|"
ok "支払済みの下の段には返金の扱いで反映（A社が 2026-11-30 に支払済み → RAが 2026-11-22 退職。取り消す）" \
  "$(sql "begin; $SET_A; $(FPAID 2026-11-30); $SET_RA2; $(KRES "'2026-11-22'::date"); $FST; rollback;" | first)" "2026-11-22|100|160000|refund|paid|pending"
ok "返金済みの下の段は動かさない（その後RAが退職日を直しても 2026-11-22 のまま。取り消す）" \
  "$(sql "begin; $SET_A; $(FPAID 2026-11-30); $SET_RA2; $(KRES "'2026-11-22'::date"); $SET_A; select v2_reward_mark_refunded($FR, $FV, '2026-12-10'); $SET_RA2; $(KRES "'2027-01-02'::date"); $FST; rollback;" | first)" "2026-11-22|100|160000|refund|paid|refunded"
ok "差し引き後の額で支払済みの下の段は動かさない（取り消す）" \
  "$(sql "begin; $SET_A; $(FRES "'2027-01-02'::date"); $(FPAID 2027-01-10); $SET_RA2; $(KRES "'2026-11-22'::date"); $FST; rollback;" | first)" "2027-01-02|50|80000|deduct|paid|"
ok "反映された下の段の version が上がり、古い画面からの操作は P0409（取り消す）" \
  "$(OLDV=$(fv); sql "begin; $SET_RA; $(KRES "'2027-01-02'::date"); $SET_A; select v2_reward_record_resignation($FR, $OLDV, null); rollback;" | errc)" "P0409"
ok "3段: RAの記録が A99999→B00001 と B00001→C99999 の両方に反映（取り消す）" \
  "$(sql "begin; $THREE; $SET_RA; $(KRES "'2027-01-02'::date"); select string_agg(format('%s:%s|%s', pe.code, r.resigned_on, r.refund_amount), ',' order by pe.code) from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id where r.application_id='$JIRO'; rollback;" | first)" "A99999:2027-01-02|150000,B00001:2027-01-02|80000,C99999:2027-01-02|25000"
ok "3段: 真ん中（A社）の記録は下（C99999）にだけ反映し、上（KANOA→A99999）は動かさない（取り消す）" \
  "$(sql "begin; $THREE; $SET_A; $(FRES "'2027-01-02'::date"); $SET_RA2; select string_agg(format('%s:%s', pe.code, r.resigned_on), ',' order by pe.code) from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id where r.application_id='$JIRO'; rollback;" | first)" "A99999:,B00001:2027-01-02,C99999:2027-01-02"
ok "反映の確認の後も、次郎の報酬は退職なしのまま" "$(one "select string_agg(coalesce(resigned_on::text,'-'), ',') from v2_rewards where application_id='$JIRO'")" "-,-"

echo "== 2) フロント向けの額が未設定 → 0円（未設定）の行 → 紹介料を入れる =="
ok "額が未設定でも A99999→B00001 の行ができる（0円・支払待ち。取り消す）" \
  "$(sql "begin; $NOFEE; select format('%s|%s', fee_amount, pay_status) from v2_rewards where $FW; rollback;" | first)" "0|pending"
ok "B社からも自社の行が見える形（0円の行）になる（取り消す）" \
  "$(sql "begin; $NOFEE; $SET_B; select count(*)::text from v2_rewards where application_id='$JIRO' and fee_amount=0; rollback;" | first)" "1"
ok "0円の行は支払済みにできない（P0400。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_A; select v2_reward_mark_paid($FR, $FV, '2026-11-30', 0); rollback;" | errc)" "P0400"
ok "A社の代表が紹介料 150000 を入れる → 150000・支払待ち（取り消す）" \
  "$(sql "begin; $NOFEE; $SET_A; select format('%s|%s', r.fee_amount, r.pay_status) from v2_reward_set_fee($FR, $FV, 150000) r; rollback;" | first)" "150000|pending"
ok "入れた後は支払済みにできる（取り消す）" \
  "$(sql "begin; $NOFEE; $SET_A; select v2_reward_set_fee($FR, $FV, 150000); select r.pay_status from v2_reward_mark_paid($FR, $FV, '2026-11-30', 150000) r; rollback;" | first)" "paid"
ok "一度入れた紹介料は変えられない（P0409。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_A; select v2_reward_set_fee($FR, $FV, 150000); select v2_reward_set_fee($FR, $FV, 1); rollback;" | errc)" "P0409"
ok "額が入っている行（160000）には入れられない（P0409。取り消す）" \
  "$(sql "begin; $SET_A; select v2_reward_set_fee($FR, $FV, 1); rollback;" | errc)" "P0409"
ok "支払前の退職がある0円の行: 入れると固定済みの返金率（50%）で差し引きを計算し直す（取り消す）" \
  "$(sql "begin; $NOFEE; $(KRES "'2027-01-02'::date"); $SET_A; select format('%s|%s|%s|%s|%s', r.fee_amount, r.refund_rate, r.refund_amount, r.refund_mode, r.pay_status) from v2_reward_set_fee($FR, $FV, 160000) r; rollback;" | first)" "160000|50|80000|deduct|pending"
ok "（対照）その0円の行は、退職の反映直後は「支払なし」（取り消す）" \
  "$(sql "begin; $NOFEE; $(KRES "'2027-01-02'::date"); select pay_status from v2_rewards where $FW; rollback;" | first)" "cancelled"
ok "受け取る側（B社の代表）は入れられない（P0403。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_B; select v2_reward_set_fee($FR, $FV, 150000); rollback;" | errc)" "P0403"
ok "A社の代表でないCAは入れられない（P0403。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_AC; select v2_reward_set_fee($FR, $FV, 150000); rollback;" | errc)" "P0403"
ok "0円・小数・マイナスは拒否（P0400。取り消す）" \
  "$(for v in 0 1.5 -1; do sql "begin; $NOFEE; $SET_A; select v2_reward_set_fee($FR, $FV, $v); rollback;" | errc; done | tr '\n' ' ')" "P0400 P0400 P0400 "
ok "古い version では入れられない（P0409。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_A; select v2_reward_set_fee($FR, ($FV) - 1, 150000); rollback;" | errc)" "P0409"
ok "未ログインでは呼べない" \
  "$(curl -s -X POST "$BASE/rest/v1/rpc/v2_reward_set_fee" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(j p_reward 00000000-0000-0000-0000-000000000000 p_version =1 p_fee =1)" | code)" "42501"
NODE_F=$(node --input-type=module -e "
import { actionsOf } from './js/ui/reward-rows.js';
const k = (r) => actionsOf(r).map((a) => a[0]).join('+');
console.log([k({ fee_amount: '0', pay_status: 'pending' }), k({ fee_amount: '0', pay_status: 'cancelled', resigned_on: '2027-01-02', refund_mode: 'deduct', refund_amount: '0' }), k({ fee_amount: '160000', pay_status: 'pending' })].join('/'));" 2>&1)
ok "画面: 0円の行には「紹介料を入れる」が出る（退職ありでも）。額のある行には出ない" "$NODE_F" "fee+resign/fee+resign+unresign/paid+resign"

echo "== 3) 支払う会社が記録できない状態 → RAが代わりに記録 =="
ok "（対照）A社が利用中なら、RAは A99999→B00001 を記録できない（P0403。取り消す）" \
  "$(sql "begin; $SET_RA; select v2_reward_mark_paid($FR, $FV, '2026-11-30', $FPAYX); rollback;" | errc)" "P0403"
ok "A社が利用停止中: RAが支払済みにできる（取り消す）" \
  "$(sql "begin; $SUSPEND_A; $SET_RA; select r.pay_status from v2_reward_mark_paid($FR, $FV, '2026-11-30', $FPAYX) r; rollback;" | first)" "paid"
ok "A社の代表が停止中（会社は利用中）: RAが退職を記録できる（取り消す）" \
  "$(sql "begin; $NO_OWNER_A; $SET_RA; select r.refund_mode from v2_reward_record_resignation($FR, $FV, '2027-01-02') r; rollback;" | first)" "deduct"
ok "A社が利用停止中でも、受け取る側（B社の代表）は記録できない（P0403。取り消す）" \
  "$(sql "begin; $SUSPEND_A; $SET_B; select v2_reward_mark_paid($FR, $FV, '2026-11-30', $FPAYX); rollback;" | errc)" "P0403"
ok "画面の絞り込み（v2_payer_stuck）: RAには停止中の会社の行だけ true（取り消す）" \
  "$(sql "begin; $SUSPEND_A; $SET_RA; select string_agg(coalesce(pr.code,'KANOA')||':'||v2_payer_stuck(r), ',' order by pr.code nulls first) from v2_rewards r left join v2_companies pr on pr.id=r.payer_company_id where r.application_id='$JIRO'; rollback;" | first)" "KANOA:false,A99999:true"
ok "画面の絞り込み: RA以外には true にならない（停止中でも。取り消す）" \
  "$(sql "begin; $SUSPEND_A; $SET_B; select string_agg(v2_payer_stuck(r)::text, ',') from v2_rewards r where r.application_id='$JIRO'; rollback;" | first)" "false"
ok "画面と同じ経路（REST）の絞り込みが通る（A社: 該当なし＝空の一覧）" \
  "$(get "$A" 'v2_rewards?select=id&payer_company_id=not.is.null&v2_payer_stuck=eq.true' | len)" "0"
ok "停止中の会社の支払済みが残っている選考は、入社の取り消しで KANOA の画面を案内する（取り消す）" \
  "$(sql "begin; $SUSPEND_A; $SET_RA; select v2_reward_mark_paid($FR, $FV, '2026-11-30', $FPAYX); $MS_UNJOIN; rollback;" | hint_has 'KANOAが報酬の画面')" "yes"
ok "（対照）利用中の会社なら、その会社に依頼するよう案内する（取り消す）" \
  "$(sql "begin; $SET_A; $(FPAID 2026-11-30); $SET_RA2; $MS_UNJOIN; rollback;" | hint_has 'パートナー管理')" "yes"

echo "== 4) 123（レビュー修正） =="
# 下の段（A99999→B00001）の version と操作の記録の件数
FVA="select format('%s|%s', version, (select count(*) from v2_audit_log where row_id=$FR)) from v2_rewards where $FW"
F_BEFORE=$(one "$FVA")
ok "前提: 下の段の version と操作の記録の件数が読める" "$(echo "$F_BEFORE" | grep -Eq '^[0-9]+\|[0-9]+$' && echo y)" "y"
ok "退職の記録が無い上の段で「消す」→ 下の段の version も操作の記録も変わらない（取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "null::date"); reset role; $FVA; rollback;" | first)" "$F_BEFORE"
ok "（対照）上の段の「消す」自体は通る（上の段は退職なし・支払待ちのまま。取り消す）" \
  "$(sql "begin; $SET_RA; select format('%s|%s', r.resigned_on, r.pay_status) from v2_reward_record_resignation($KR, $KV, null) r; rollback;" | first)" "|pending"
# 選考の行のロック: FOR UPDATE でロックした行は xmax が自分のトランザクション番号になる（更新はしないので、ロックだけが残る）
APPLOCK="reset role; select (xmax::text = (txid_current() % 4294967296)::text)::text from v2_applications where id='$JIRO'"
ok "退職の記録は選考の行をロックする（マイルストーンの更新と同じ 選考→報酬 の順。取り消す）" \
  "$(sql "begin; $SET_RA; $(KRES "'2027-01-02'::date"); $APPLOCK; rollback;" | first)" "true"
ok "退職の記録を消すときも選考の行をロックする（下の段のA社の記録。取り消す）" \
  "$(sql "begin; $SET_A; $(FRES "'2027-01-02'::date"); $(FRES "null::date"); $APPLOCK; rollback;" | first)" "true"
ok "（対照）支払済みにする（選考の行をロックしない）ではロックされない（取り消す）" \
  "$(sql "begin; $SET_A; $(FPAID 2026-11-30); $APPLOCK; rollback;" | first)" "false"
ok "関数の本体で、報酬の行をロックする前に選考の行をロックしている" \
  "$(one "select (position('from v2_applications' in d) between 1 and position('v2_reward_lock(' in d))::text from (select pg_get_functiondef('v2_reward_record_resignation(uuid,int,date)'::regprocedure) d) x")" "true"
ok "無い報酬の id: A社は P0403・RAは P0409（これまでどおり。取り消す）" \
  "$(for s in "$SET_A" "$SET_RA"; do sql "begin; $s; select v2_reward_record_resignation('00000000-0000-0000-0000-000000000000', 1, null); rollback;" | errc; done | tr '\n' ' ')" "P0403 P0409 "
# 支払済みの下の段に反映された退職（返金待ち）を、RAが上の段で消す → 下の段は支払済みに戻り、返金は無くなる
FST2="select format('%s|%s|%s|%s|%s|%s', resigned_on, refund_amount, refund_mode, pay_status, refund_status, paid_on) from v2_rewards where $FW"
ok "支払済みの下の段: 反映で返金待ち → RAが消すと支払済みのまま返金なしに戻る（取り消す）" \
  "$(sql "begin; $SET_A; $(FPAID 2026-11-30); $SET_RA2; $(KRES "'2026-11-22'::date"); reset role; create temp table mid on commit drop as $FST2; $SET_RA; $(KRES "null::date"); reset role; select (select format from mid) || ' -> ' || ($FST2); rollback;" | first)" \
  "2026-11-22|160000|refund|paid|pending|2026-11-30 -> |||paid||2026-11-30"
ok "A社が利用停止中: RAが0円の行に紹介料を入れられる（取り消す）" \
  "$(sql "begin; $SUSPEND_A; $NOFEE; $SET_RA; select format('%s|%s', r.fee_amount, r.pay_status) from v2_reward_set_fee($FR, $FV, 150000) r; rollback;" | first)" "150000|pending"
ok "（対照）A社が利用中なら、RAは0円の行に紹介料を入れられない（P0403。取り消す）" \
  "$(sql "begin; $NOFEE; $SET_RA; select v2_reward_set_fee($FR, $FV, 150000); rollback;" | errc)" "P0403"

# 画面で試せるように、次郎を「入社済み・2段とも支払待ち・退職なし」にして残す
ok "後片付け: 次郎をいったん戻して入社し直す"   "$(reset_jiro)$(join_jiro | tr '\n' ' ')" "[]none none none none "
ok "画面確認用: KANOA→A99999 300000・A99999→B00001 160000（どちらも支払待ち・退職なし）" \
  "$(one "select string_agg(format('%s>%s|%s|%s|%s', coalesce(pr.code,'KANOA'), pe.code, r.fee_amount, r.pay_status, r.resigned_on), ',' order by pr.code nulls first) from v2_rewards r join v2_companies pe on pe.id=r.payee_company_id left join v2_companies pr on pr.id=r.payer_company_id where r.application_id='$JIRO'")" \
  "KANOA>A99999|300000|pending|,A99999>B00001|160000|pending|"
ok "A社は利用中・代表者も利用中のまま" "$(one "select format('%s|%s', (select status from v2_companies where id='$ACO'), (select string_agg(status, ',') from v2_members where company_id='$ACO' and is_owner))")" "active|active"
echo "----"; echo "PASS $pass / FAIL $fail"; [ "$fail" -eq 0 ]
