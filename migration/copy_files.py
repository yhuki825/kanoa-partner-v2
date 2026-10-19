#!/usr/bin/env python3
"""V1 の書類ファイル（置き場 candidate-docs）を V2 の置き場 v2-files へコピーする。何度流してもよい。
・コピー元は読むだけ（candidate-docs には書き込まない・消さない）
・コピー先の一覧は DB の移行記録（v2_v1_map の document / intake_doc）から作る（パスは candidates/{求職者ID}/{ID}.{拡張子}）
・コピー済み台帳（v2_v1_file_copies）と置き場の実物を見て、同じコピー元で済んでいるものは飛ばす
・台帳にあるのに今回のコピー先に無いもの（V1 で消えた書類）は v2-files から消す
・消すのは台帳（v2_v1_file_copies）に記録した、このスクリプトがコピーしたものだけ。それ以外（画面から置かれたファイル等）は決して消さない
  （コピー先に台帳に無いファイルが既にあれば、大きさが同じなら台帳に記録して使い、違えば触らずに失敗として報告する）
使い方: python3 migration/copy_files.py   （画面に出すのは件数だけ。ファイル名・パスは出さない）"""
import json, os, sys, urllib.parse
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _mgmt import sql, lit, storage  # noqa: E402

SRC_BUCKET, DST_BUCKET = 'candidate-docs', 'v2-files'


def q(p):
    return urllib.parse.quote(p, safe='/')


def main():
    expected = {r['dst']: r for r in sql(
        "select extra->>'src' src, extra->>'dst' dst, (extra->>'size')::bigint size, extra->>'mime' mime "
        "from v2_v1_map where kind in ('document','intake_doc') and status = 'migrated'")}
    ledger = {r['dst_path']: r for r in sql('select dst_path, src_path, size from v2_v1_file_copies')}
    # 移行した求職者（今回分＋台帳にある過去分）のフォルダ
    cand_dirs = {d.rsplit('/', 1)[0] + '/' for d in list(expected) + list(ledger)}
    objs = {}
    if cand_dirs:
        rows = sql("select name, (metadata->>'size')::bigint size from storage.objects where bucket_id = 'v2-files' "
                   "and name like 'candidates/%' and split_part(name, '/', 2) in ("
                   + ','.join(lit(d.split('/')[1]) for d in cand_dirs) + ')')
        objs = {r['name']: r['size'] for r in rows}

    to_copy, skipped, adopted, conflicts, replace = [], 0, [], [], []
    for dst, e in expected.items():
        led = ledger.get(dst)
        if dst in objs:
            if led is None:
                # 台帳に無い = このスクリプトのコピーと確かめられない。消さない
                if objs[dst] == e['size']:
                    adopted.append(e)          # 前回の途中終了などで台帳だけ書けなかったコピー
                else:
                    conflicts.append(e)
                continue
            if objs[dst] == e['size'] and led['src_path'] == e['src']:
                skipped += 1
                continue
            replace.append(dst)                # 台帳にある自分のコピーだが中身が古い → 消して取り直す
        to_copy.append(e)

    stale = sorted(set(ledger) - set(expected))                       # V1 から消えた書類のコピー（台帳にある分だけ）
    unknown = sorted(n for n in objs if n not in expected and n not in ledger)   # 台帳に無いファイル: 数えるだけで消さない

    remove = [d for d in stale + replace if d in ledger]               # 念のため: 台帳にあるものしか消さない
    removed = 0
    for i in range(0, len(remove), 100):
        chunk = remove[i:i + 100]
        st, out = storage(f'object/{DST_BUCKET}', 'DELETE', {'prefixes': chunk})
        if st != 200:
            raise RuntimeError(f'delete failed (HTTP {st})')
        removed += len(chunk)
    if stale:
        sql('delete from v2_v1_file_copies where dst_path in (' + ','.join(lit(x) for x in stale) + ')')

    def copy_one(e):
        st, out = storage('object/copy', 'POST', {'bucketId': SRC_BUCKET, 'sourceKey': e['src'],
                                                  'destinationBucket': DST_BUCKET, 'destinationKey': e['dst']})
        if st == 200:
            return e, 'copy'
        # コピーが使えない場合は、読み出して置き直す（コピー元は読むだけ）
        k_st, data = storage(f'object/{SRC_BUCKET}/{q(e["src"])}')
        if k_st != 200:
            return e, f'download failed HTTP {k_st}'
        from _mgmt import service_key, BASE, _request
        k = service_key()
        u_st, _ = _request(f'{BASE}/storage/v1/object/{DST_BUCKET}/{q(e["dst"])}', 'POST', data,
                           {'apikey': k, 'Authorization': f'Bearer {k}', 'Content-Type': e['mime'] or 'application/octet-stream',
                            'x-upsert': 'true'})
        return e, ('upload' if u_st == 200 else f'upload failed HTTP {u_st} (copy HTTP {st})')

    done, failed, how = list(adopted), [(e, 'exists in v2-files but not recorded as our copy (left untouched)') for e in conflicts], {}
    if adopted: how['adopted_existing'] = len(adopted)
    with ThreadPoolExecutor(max_workers=6) as ex:
        for e, res in ex.map(copy_one, to_copy):
            if res in ('copy', 'upload'):
                done.append(e); how[res] = how.get(res, 0) + 1
            else:
                failed.append((e, res))
    for i in range(0, len(done), 200):
        chunk = done[i:i + 200]
        sql('insert into v2_v1_file_copies(dst_path, src_path, size) values '
            + ','.join(f"({lit(e['dst'])},{lit(e['src'])},{int(e['size'] or 0)})" for e in chunk)
            + ' on conflict (dst_path) do update set src_path = excluded.src_path, size = excluded.size, copied_at = now()')

    # 確認: 期待どおりの場所に、期待どおりの大きさで全部あるか
    chk = sql("select count(*) n, coalesce(sum((o.metadata->>'size')::bigint), 0) b, "
              "count(*) filter (where (o.metadata->>'size')::bigint is distinct from (m.extra->>'size')::bigint) bad "
              "from v2_v1_map m join storage.objects o on o.bucket_id = 'v2-files' and o.name = m.extra->>'dst' "
              "where m.kind in ('document','intake_doc') and m.status = 'migrated'")[0]
    summary = {'expected': len(expected), 'already_copied_skipped': skipped, 'copied': how, 'failed': len(failed),
               'removed_stale_copies': len(stale), 'unknown_files_left_untouched': len(unknown),
               'removed_total_incl_replaced': removed, 'present_in_v2_files': chk['n'], 'present_bytes': chk['b'],
               'size_mismatch': chk['bad']}
    print(json.dumps(summary, ensure_ascii=False))
    for e, res in failed[:20]:
        print('FAILED', e['dst'].split('/')[1][:8] + '…', res)   # 求職者IDの頭だけ（ファイル名は出さない）
    return 1 if failed or chk['n'] != len(expected) or chk['bad'] else 0


if __name__ == '__main__':
    sys.exit(main())
