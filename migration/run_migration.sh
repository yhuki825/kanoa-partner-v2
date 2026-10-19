#!/usr/bin/env bash
# ============================================================
# V1 → V2 データ移行（お試し・何度流してもよい）
#   1) V1 の件数とハッシュを記録（読むだけ）
#   2) DB の移行: v2_v1_migrate()（supabase/migrations/127_v1_migration.sql）
#      前回の移行分（v2_v1_map に記録した行）だけを消してから、V1 の今の状態で入れ直す。テスト用の会社には触れない
#   3) 会社単位の V1 連絡を CSV へ（migration/exports/ は Git に上げない）
#   4) 書類ファイルのコピー: migration/copy_files.py（コピー済みは飛ばす・V1 から消えた分は消す）
#   5) V1 の件数とハッシュをもう一度記録し、照合レポート migration/reconciliation_<日付>.md を作る
#
# 使い方: bash migration/run_migration.sh [--joined-until YYYY-MM-DD] [--activate-members] [--force-after-cutover] [--discard-preview-edits] [--skip-files] [--tests-log FILE]
#   --joined-until     この日以前の V1 入社日を「入社」として報酬を作る（既定: 日本時間の今日）
#   --activate-members 代表CA を利用中にする（切替のときだけ。お試し中は付けない＝V1 の ID で V2 に入れない）
#   --force-after-cutover 切替（--activate-members で流した）後に、あえて流し直すときだけ。V2 で作られたデータが移行した行に付いていれば、それでも止まる
#   --discard-preview-edits 切替前だけ: お試し中に移行した行へ加えた変更・追加（チャット・段階・メモ等）を捨てて作り直す。
#                      移していない行（テスト用の会社・他の人の既読など）に及ぶ場合は、それでも止まる。切替後は使えない
#   --tests-log        V2 のテスト結果の件数（PASS/FAIL の数だけ）をレポートに載せる
# 前提: Supabase CLI にログイン済み（キーチェーン）。V2 のテスト（tests/*_check.sh）を同時に流さないこと
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
JOINED=-; ACT=-; FORCE=-; DISCARD=""; FILES=1; TESTS_LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --joined-until) JOINED="$2"; shift 2 ;;
    --activate-members) ACT=activate; shift ;;
    --force-after-cutover) FORCE=force; shift ;;
    --discard-preview-edits) DISCARD=discard; shift ;;
    --skip-files) FILES=0; shift ;;
    --tests-log) TESTS_LOG="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if pgrep -f '_check.sh' >/dev/null; then echo "V2 のテストが実行中です。終わってから流してください" >&2; exit 1; fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "[1/5] V1 の件数を記録（読むだけ）"
python3 migration/migrate.py snapshot > "$WORK/before.json"
echo "[2/5] DB の移行"
python3 migration/migrate.py run "$JOINED" "$ACT" "$FORCE" "$DISCARD" > "$WORK/run.json"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("  ", json.dumps({k:v for k,v in d["map"].items()}, ensure_ascii=False))' "$WORK/run.json"
echo "[3/5] 会社単位の連絡を CSV へ"
python3 migration/migrate.py export > "$WORK/export.json"; cat "$WORK/export.json"
echo "[4/5] 書類ファイルのコピー"
if [ "$FILES" = 1 ]; then python3 migration/copy_files.py > "$WORK/copy_raw.json" || { cat "$WORK/copy_raw.json"; echo "書類のコピーで失敗があります" >&2; COPY_FAIL=1; }
else echo '{"skipped": true}' > "$WORK/copy_raw.json"; fi
head -1 "$WORK/copy_raw.json"
python3 -c 'import json,sys;c=json.loads(open(sys.argv[1]).readline());e=json.load(open(sys.argv[2]));print(json.dumps({"_copy":c,"_export":e}))' "$WORK/copy_raw.json" "$WORK/export.json" > "$WORK/copy.json"
echo "[5/5] V1 の件数をもう一度記録して照合レポート"
python3 migration/migrate.py snapshot > "$WORK/after.json"
python3 migration/migrate.py report "$WORK/before.json" "$WORK/after.json" "$WORK/run.json" "$WORK/copy.json" ${TESTS_LOG:+"$TESTS_LOG"}
python3 -c '
import json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2]))
ch=[k for k in b if b[k]!=a.get(k)]
print("  V1 の変化:", "なし" if not ch else ", ".join(ch)+"（V1 は本番稼働中。利用者の操作の可能性）")' "$WORK/before.json" "$WORK/after.json"
[ "${COPY_FAIL:-0}" = 0 ]
