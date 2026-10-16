// 招待（フロント会社の招待コード）の発行・再発行・取消と、招待文のコピー
// パートナー管理（代表CA）とCA一覧（RA）で共通に使う
import { callFn, sb } from '../supabase.js';
import { esc, fmtDate } from './format.js';
import { openModal, showError, toast, busy, confirmDialog } from './components.js';
import { userError } from './db.js';

function inviteText({ companyName, code, tempPw, expiresAt }) {
  const url = location.origin + location.pathname;
  return `【KANOA Partner Portal ご招待】
${companyName} 様

パートナーポータルへご招待します。下記のURLを開き、ログイン画面の「初回登録」から登録してください。

ログインURL：${url}
企業コード：${code}
初期パスワード：${tempPw}
有効期限：${fmtDate(expiresAt)}

登録すると、ご担当者さまのログインID（${code}-01）が発行されます。`;
}

// 初期パスワードは、この画面にしか表示されない（DBには保存しない）
export function showInviteResult({ companyName, code, tempPw, expiresAt }) {
  const text = inviteText({ companyName, code, tempPw, expiresAt });
  const m = openModal(`
    <h3>招待コードを発行しました</h3>
    <p class="callout warn">初期パスワードは<b>この画面にしか表示されません</b>。閉じる前に招待文をコピーして、相手に送ってください。</p>
    <label class="sr-only" for="inv-text">招待文</label>
    <textarea id="inv-text" class="invite-text" readonly rows="12">${esc(text)}</textarea>
    <div class="modal-actions"><button class="btn" data-act="close">閉じる</button><button class="btn btn-primary" data-act="copy">招待文をコピー</button></div>`, { wide: true });
  m.el.querySelector('[data-act="copy"]').onclick = async () => {
    try { await navigator.clipboard.writeText(text); toast('コピーしました'); }
    catch { m.el.querySelector('textarea').select(); toast('選択しました。⌘+C（Ctrl+C）でコピーしてください'); }
  };
  m.el.querySelector('[data-act="close"]').onclick = async () => {
    if (await confirmDialog('招待文はコピーしましたか？\n閉じると、初期パスワードはもう表示できません（必要なら「再発行」できます）。', { okLabel: '閉じる' })) m.close();
  };
}

export function issueInviteModal({ title, hint, onDone }) {
  const m = openModal(`
    <h3>${esc(title)}</h3>
    <p class="hint">${esc(hint)}</p>
    <form novalidate>
      <div class="field"><label for="iv-name">招待する会社名</label><input id="iv-name" name="name" required placeholder="株式会社〇〇"></div>
      <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary">招待コードを発行</button></div>
    </form>`);
  const form = m.el.querySelector('form');
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();
  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const name = String(new FormData(form).get('name') || '').trim();
    if (!name) { showError(new Error('会社名を入力してください。'), '招待'); return; }
    try {
      const r = await callFn('v2-invite-issue', { company_name: name });
      m.close();
      showInviteResult({ companyName: name, code: r.code, tempPw: r.temp_password, expiresAt: r.expires_at });
      onDone?.();
    } catch (err) { showError(err, '招待コードの発行'); }
  }); };
}

export async function reissueInvite(inv, onDone) {
  if (!await confirmDialog(`「${inv.company_name}」（${inv.code}）の招待を再発行しますか？\n新しい初期パスワードを発行し、期限を14日延ばします。前の初期パスワードは使えなくなります。`, { okLabel: '再発行する' })) return;
  try {
    const r = await callFn('v2-invite-issue', { reissue_code: inv.code });
    showInviteResult({ companyName: inv.company_name, code: r.code, tempPw: r.temp_password, expiresAt: r.expires_at });
    onDone?.();
  } catch (err) { showError(err, '招待の再発行'); }
}

export async function revokeInvite(inv, onDone) {
  if (!await confirmDialog(`「${inv.company_name}」（${inv.code}）の招待を取り消しますか？\nこの企業コードでは登録できなくなります。`, { okLabel: '取り消す', danger: true })) return;
  const { error } = await sb().from('v2_invites').update({ status: 'revoked' }).eq('id', inv.id);
  if (error) { showError(userError(error, '取り消せませんでした'), '招待の取消'); return; }
  toast('招待を取り消しました'); onDone?.();
}

// 未使用の招待の一覧（表の行）
// issuerOf を渡すと「発行」列を足す（CA一覧用）。canManage は真偽値か、招待ごとに判定する関数
export function inviteRows(invs, canManage, issuerOf = null) {
  const st = (v) => v.status === 'issued' && new Date(v.expires_at) < new Date() ? '期限切れ' : ({ issued: '招待中', expired: '期限切れ', revoked: '取消済み', accepted: '登録済み' }[v.status]);
  return invs.map((v) => `
    <tr>
      <td class="mono">${esc(v.code)}</td><td>${esc(v.company_name)}</td>
      <td>${esc(st(v))}</td><td>${fmtDate(v.expires_at)}</td>
      ${issuerOf ? `<td>${esc(issuerOf(v))}</td>` : ''}
      <td class="row-actions">${(typeof canManage === 'function' ? canManage(v) : canManage) && ['issued', 'expired'].includes(v.status) ? `
        <button class="btn btn-sm" data-reissue="${esc(v.id)}">再発行</button>
        <button class="btn btn-sm" data-revoke="${esc(v.id)}">取消</button>` : ''}</td>
    </tr>`).join('');
}

export function bindInviteRows(root, invs, onDone) {
  root.querySelectorAll('[data-reissue]').forEach((b) => { b.onclick = () => reissueInvite(invs.find((v) => v.id === b.dataset.reissue), onDone); });
  root.querySelectorAll('[data-revoke]').forEach((b) => { b.onclick = () => revokeInvite(invs.find((v) => v.id === b.dataset.revoke), onDone); });
}

// CAのパスワード再設定（新しい初期パスワードを一度だけ表示）
export async function resetMemberPassword(member) {
  if (!await confirmDialog(`${member.name}（${member.login_id}）のパスワードを再設定しますか？\n新しい初期パスワードを発行します。本人は次のログインでパスワードを変更します。`, { okLabel: '再設定する' })) return;
  try {
    const r = await callFn('v2-member-reset', { member_id: member.id });
    const text = `ログインID：${r.login_id}\n初期パスワード：${r.temp_password}\n（ログイン後にパスワードの変更を求められます）`;
    const m = openModal(`<h3>パスワードを再設定しました</h3>
      <p class="callout warn">初期パスワードは<b>この画面にしか表示されません</b>。本人に伝えてください。</p>
      <textarea class="invite-text" readonly rows="4" aria-label="ログイン情報">${esc(text)}</textarea>
      <div class="modal-actions"><button class="btn" data-act="close">閉じる</button><button class="btn btn-primary" data-act="copy">コピー</button></div>`);
    m.el.querySelector('[data-act="copy"]').onclick = async () => { try { await navigator.clipboard.writeText(text); toast('コピーしました'); } catch { m.el.querySelector('textarea').select(); } };
    m.el.querySelector('[data-act="close"]').onclick = () => m.close();
  } catch (err) { showError(err, 'パスワードの再設定'); }
}

export async function setMemberStatus(member, status, onDone) {
  const verb = status === 'suspended' ? '停止' : '再開';
  if (!await confirmDialog(`${member.name}（${member.login_id || member.email || ''}）を${verb}しますか？${status === 'suspended' ? '\n停止すると、この人はログインできなくなります。' : ''}`, { okLabel: `${verb}する`, danger: status === 'suspended' })) return;
  const { error } = await sb().rpc('v2_set_member_status', { p_member: member.id, p_status: status });
  if (error) { showError(userError(error, `${verb}できませんでした`), `CAの${verb}`); return; }
  toast(`${verb}しました`); onDone?.();
}
