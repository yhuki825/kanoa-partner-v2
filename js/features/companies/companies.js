// フロント企業（パートナー）／パートナー一覧（KANOA）＋招待コード発行
import { register } from '../../router.js';
import { sb, callFn } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { toast, openModal, confirmDialog } from '../../ui/components.js';
import { tierLabel } from '../../config.js';

async function authToken() {
  const { data } = await sb().auth.getSession();
  return data?.session?.access_token || null;
}

// 招待文（コピーして相手に送る定型文）
function inviteText({ companyName, code, tempPw, expiresAt }) {
  const url = location.origin + location.pathname;
  return `【KANOA Partner Portal ご招待】
${companyName} 様

パートナーポータルへご招待します。以下からログインしてください。

ログインURL: ${url}
企業コード: ${code}
初期パスワード: ${tempPw}

※ログイン画面の「初回登録」から、企業コードと初期パスワードを入力し、
　新しいパスワードを設定してください（有効期限: ${fmtDate(expiresAt)}）`;
}

function inviteResultModal(info) {
  const text = inviteText(info);
  const m = openModal(`
    <h3>招待コードを発行しました</h3>
    <p style="font-size:12.5px;color:var(--c-danger);margin-bottom:10px">
      ⚠ 初期パスワードは<b>この画面にしか表示されません</b>。必ずコピーして相手に送ってください。</p>
    <textarea readonly style="width:100%;height:220px;font-size:12.5px;padding:10px;border:1px solid var(--c-border);border-radius:8px">${esc(text)}</textarea>
    <div class="modal-actions">
      <button class="btn" data-act="close">閉じる</button>
      <button class="btn btn-primary" data-act="copy">招待文をコピー</button>
    </div>`);
  m.el.querySelector('[data-act="copy"]').onclick = async () => {
    try { await navigator.clipboard.writeText(text); toast('コピーしました', 'ok'); }
    catch { toast('コピーに失敗しました。手動で選択してコピーしてください', 'err'); }
  };
  m.el.querySelector('[data-act="close"]').onclick = () => m.close();
}

function issueModal(onDone) {
  const m = openModal(`
    <h3>フロント企業を招待</h3>
    <form id="issue-form">
      <div class="field"><label>会社名</label><input name="company_name" required placeholder="株式会社〇〇"></div>
      <div class="modal-actions">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn btn-primary">発行する</button>
      </div>
    </form>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('#issue-form').onsubmit = async (e) => {
    e.preventDefault();
    const name = new FormData(e.target).get('company_name');
    const btn = e.target.querySelector('.btn-primary');
    btn.disabled = true;
    try {
      const token = await authToken();
      const res = await callFn('invite-issue', { company_name: name }, { token });
      m.close();
      inviteResultModal({ companyName: name, code: res.code, tempPw: res.temp_password, expiresAt: res.expires_at });
      onDone();
    } catch (err) { toast(err.message, 'err'); btn.disabled = false; }
  };
}

async function render(el) {
  const c = sb();
  const isAdmin = S.role === 'kanoa';

  // フロント企業（admin: 全社）と、未使用の招待
  let compQ = c.from('companies').select('id,code,tier,name,contact,status,joined_at,parent_id').order('code');
  if (!isAdmin) compQ = compQ.eq('parent_id', S.company.id);
  const [{ data: comps, error: e1 }, { data: invs }] = await Promise.all([
    compQ,
    c.from('invites').select('code,company_name,status,issued_at,expires_at')
      .eq('status', 'issued').order('issued_at', { ascending: false }),
  ]);
  if (e1) throw e1;

  const compRows = (comps || [])
    .filter((x) => !isAdmin || true)
    .map((x) => `
      <tr>
        <td><b>${esc(x.code)}</b></td>
        ${isAdmin ? `<td>${esc(tierLabel(x.tier))}</td>` : ''}
        <td>${esc(x.name)}</td>
        <td>${esc(x.contact || '—')}</td>
        <td>${x.status === 'active' ? '稼働中' : x.status === 'suspended' ? '停止' : '招待中'}</td>
        <td>${fmtDate(x.joined_at)}</td>
      </tr>`).join('');

  const invRows = (invs || []).map((v) => `
    <tr>
      <td><b>${esc(v.code)}</b></td>
      <td>${esc(v.company_name)}</td>
      <td>発行 ${fmtDate(v.issued_at)} ／ 期限 ${fmtDate(v.expires_at)}</td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h2 style="margin:0">${isAdmin ? '全パートナー企業' : 'フロント企業'}</h2>
        <button class="btn btn-primary" id="btn-issue">＋ 招待コードを発行</button>
      </div>
      ${compRows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th>企業コード</th>${isAdmin ? '<th>ライン</th>' : ''}<th>会社名</th><th>担当者</th><th>状態</th><th>参加日</th></tr>
        ${compRows}</table></div>`
      : `<div class="empty">まだ${isAdmin ? 'パートナー企業' : 'フロント企業'}がいません。<br>「招待コードを発行」から招待できます。</div>`}
    </div>
    ${invRows ? `<div class="card"><h2>招待中（未登録）</h2>
      <div style="overflow-x:auto"><table class="table">
        <tr><th>企業コード</th><th>会社名</th><th>発行・期限</th></tr>${invRows}</table></div></div>` : ''}
  `;
  el.querySelector('#btn-issue').onclick = () => issueModal(() => render(el));
}

register('companies', {
  title: 'フロント企業', nav: true, icon: '🏢', render,
});
