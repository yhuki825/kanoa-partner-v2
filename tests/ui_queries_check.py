#!/usr/bin/env python3
"""画面のコード（js/）とサーバー処理（supabase/functions/）に書かれた表の問い合わせ .from('v2_…').select('…') を全部抜き出し、
テスト用アカウントで実際に流して、DB側の変更で壊れていないかを確かめる。
（2026-10-15: 既読の表を足したら、ログイン時の「自分の会社」の取得が曖昧になって壊れた。その再発防止）
使い方: python3 tests/ui_queries_check.py"""
import json, re, glob, os, sys, urllib.parse, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = 'https://oicpfsfvywdhdriqehyr.supabase.co'
AK = 'sb_publishable_fBK1T1Xhx1Luj-OjbzFvaQ_4pUgNOms'
env = dict(l.strip().split('=', 1) for l in open(os.path.join(ROOT, 'tests/.test-accounts.env')) if '=' in l and not l.startswith('#'))

def curl(args):
    return subprocess.run(['curl', '-s'] + args, capture_output=True, text=True).stdout

def login(lid, pw):
    r = curl(['-X', 'POST', f'{BASE}/auth/v1/token?grant_type=password', '-H', f'apikey: {AK}', '-H', 'Content-Type: application/json',
              '-d', json.dumps({'email': f'{lid.lower()}@id.kanoa-portal.invalid', 'password': pw})])
    return json.loads(r)['access_token']

pat = re.compile(r"""from\(['"](v2_[a-z_]+)['"]\)\s*\.select\(\s*['"]([^'"]+)['"]""", re.S)
queries = set()
files = glob.glob(os.path.join(ROOT, 'js/**/*.js'), recursive=True) + glob.glob(os.path.join(ROOT, 'supabase/functions/**/*.ts'), recursive=True)
for f in files:
    if '/_old' in f: continue
    for t, sel in pat.findall(open(f, encoding='utf-8').read()):
        queries.add((os.path.relpath(f, ROOT), t, re.sub(r'\s+', '', sel)))

tokens = {'A社代表': login(env['A_OWNER_ID'], env['A_OWNER_PW']), 'B社代表': login(env['B_OWNER_ID'], env['B_OWNER_PW'])}
fail = 0
for f, t, sel in sorted(queries):
    for who, tok in tokens.items():
        url = f"{BASE}/rest/v1/{t}?select={urllib.parse.quote(sel, safe='*,()!:')}&limit=1"
        out = curl([url, '-H', f'apikey: {AK}', '-H', f'Authorization: Bearer {tok}'])
        try: d = json.loads(out)
        except Exception: d = {'message': out[:120]}
        ok = isinstance(d, list)
        if not ok: fail += 1
        print(f"{'PASS' if ok else 'FAIL'}  {who}  {t}  ({f})" + ('' if ok else f"  → {d.get('code')} {d.get('message','')[:100]}"))
print('----'); print(f'問い合わせ {len(queries)}種 × {len(tokens)}アカウント  FAIL {fail}')
sys.exit(1 if fail else 0)
