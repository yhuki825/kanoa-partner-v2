"""V1→V2 移行スクリプトの共通部品（Supabase Management API 経由で SQL を流す・Storage API を使う）
秘密（管理用トークン・service_role キー）は画面にもファイルにも出さない。メモリの中だけで使う。"""
import base64, json, subprocess, time, urllib.request, urllib.error

REF = 'oicpfsfvywdhdriqehyr'
BASE = f'https://{REF}.supabase.co'
API = f'https://api.supabase.com/v1/projects/{REF}'

_token = None
_service_key = None


def _mgmt_token():
    global _token
    if _token is None:
        t = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'],
                           capture_output=True, text=True, check=True).stdout.strip()
        if t.startswith('go-keyring-base64:'):
            t = base64.b64decode(t.split(':', 1)[1]).decode()
        _token = t
    return _token


def _request(url, method='GET', body=None, headers=None, retries=3):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    last = None
    for i in range(retries):
        req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            last = (e.code, e.read())
            if e.code in (429, 500, 502, 503, 504):
                time.sleep(2 * (i + 1)); continue
            return last
        except urllib.error.URLError as e:
            last = (0, str(e).encode())
            time.sleep(2 * (i + 1))
    return last


def redact(text, limit=500):
    """サーバーのエラー文から、行の中身が出うる部分（Failing row contains… / DETAIL: …）を落とす"""
    import re
    t = re.split(r'Failing row contains|DETAIL:', text, maxsplit=1)[0]
    t = re.sub(r'Key \(([^)]*)\)=\([^)]*\)', r'Key (\1)=(…)', t)   # 一意制約の値も伏せる
    return t[:limit] + (' …(redacted)' if t != text[:len(t)] or len(text) > len(t) else '')


def sql(query):
    """SQL を1回流して結果（行のリスト）を返す。SQL のエラーは例外にする"""
    st, out = _request(f'{API}/database/query', 'POST', {'query': query},
                       {'Authorization': f'Bearer {_mgmt_token()}', 'Content-Type': 'application/json'})
    if st not in (200, 201):
        raise RuntimeError(f'SQL failed (HTTP {st}): {redact(out.decode(errors="replace"))}')
    return json.loads(out)


def lit(v):
    """SQL の文字列リテラル（値は自分たちの DB から読んだものだけを渡す）"""
    if v is None:
        return 'null'
    return "'" + str(v).replace("'", "''") + "'"


def service_key():
    """Storage を操作するための service_role キー（表示・保存しない）"""
    global _service_key
    if _service_key is None:
        st, out = _request(f'{API}/api-keys?reveal=true', headers={'Authorization': f'Bearer {_mgmt_token()}'})
        if st != 200:
            raise RuntimeError(f'could not obtain service key (HTTP {st})')
        keys = json.loads(out)
        k = next((x.get('api_key') for x in keys if x.get('name') == 'service_role' and x.get('api_key')), None) \
            or next((x.get('api_key') for x in keys if x.get('type') == 'secret' and x.get('api_key')), None)
        if not k:
            raise RuntimeError('service key not found')
        _service_key = k
    return _service_key


def storage(path, method='GET', body=None):
    k = service_key()
    h = {'apikey': k, 'Authorization': f'Bearer {k}', 'Content-Type': 'application/json'}
    return _request(f'{BASE}/storage/v1/{path}', method, body, h)
