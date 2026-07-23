// 紹介された求職者: フロントから来た求職者の「送客/見送り」判断（V2の中心画面）
// パートナー: holder = 自社 の求職者
// KANOA:     holder = null（到着済み）かつリレー中の求職者 → 受入判断
import { register, renderView } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, fmtDateTime } from '../../ui/format.js';
import { toast, openModal, confirmDialog } from '../../ui/components.js';

const ACTION_LABEL = { registered: '登録', forwarded: '送客', rejected: '見送り', accepted: 'KANOA受入' };

// 判断履歴の企業名: RLSで見える範囲だけ実名、それ以外は相対表現
function stepCompanyLabel(step, nameMap) {
  if (!step.company_id) return 'KANOA';
  if (step.company_id === S.company?.id) return '自社';
  return nameMap[step.company_id] || '上位パートナー';
}

async function decide(candId, action, onDone) {
  const labels = { forward: 'アップラインへ送客', reject: '見送り', accept: '受け入れて選考へ' };
  const m = openModal(`
    <h3>${esc(labels[action])}</h3>
    <form id="decide-form">
      <div class="field"><label>コメント（任意・履歴に残ります）</label><textarea name="note" rows="3"></textarea></div>
      <div class="modal-actions">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn ${action === 'reject' ? 'btn-danger' : 'btn-primary'}">${esc(labels[action])}</button>
      </div>
    </form>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('#decide-form').onsubmit = async (e) => {
    e.preventDefault();
    const note = new FormData(e.target).get('note') || null;
    const btn = e.target.querySelector('button:not([data-act])');
    btn.disabled = true;
    const { error } = await sb().rpc('v2_relay_decide', { p_candidate: candId, p_action: action, p_note: note });
    if (error) { toast(`処理に失敗しました（${error.message}）`, 'err'); btn.disabled = false; return; }
    toast({ forward: '送客しました', reject: '見送りました', accept: '受け入れました。選考管理へ移ります' }[action], 'ok');
    m.close(); onDone();
  };
}

async function detailModal(cand, nameMap, onDone) {
  const { data: steps } = await sb().from('candidate_steps')
    .select('company_id,action,note,created_at')
    .eq('candidate_id', cand.id).order('created_at');

  // 経路上の企業名を追加解決（RLSで見える範囲だけ返る。見えない企業は相対表現のまま）
  const unknown = [...new Set((steps || []).map((s) => s.company_id)
    .filter((id) => id && id !== S.company?.id && !nameMap[id]))];
  if (unknown.length) {
    const { data: comps } = await sb().from('companies').select('id,name,code').in('id', unknown);
    (comps || []).forEach((x) => { nameMap[x.id] = `${x.name}（${x.code}）`; });
  }

  const isAdmin = S.role === 'kanoa';
  const stepsHtml = (steps || []).map((s) => `
    <li style="margin-bottom:6px">
      <b>${esc(stepCompanyLabel(s, nameMap))}</b> が ${esc(ACTION_LABEL[s.action] || s.action)}
      <small style="color:var(--c-text-sub)">（${fmtDateTime(s.created_at)}）</small>
      ${s.note ? `<br><small>💬 ${esc(s.note)}</small>` : ''}
    </li>`).join('');

  const m = openModal(`
    <h3>${esc(cand.name)}${cand.kana ? ` <small style="color:var(--c-text-sub)">${esc(cand.kana)}</small>` : ''}</h3>
    <table class="table" style="margin-bottom:14px">
      <tr><th style="width:100px">電話</th><td>${esc(cand.phone || '—')}</td></tr>
      <tr><th>メール</th><td>${esc(cand.email || '—')}</td></tr>
      <tr><th>住所</th><td>${esc(cand.address || '—')}</td></tr>
      <tr><th>希望エリア</th><td>${esc(cand.area || '—')}</td></tr>
      <tr><th>申し送り</th><td>${esc(cand.note || '—')}</td></tr>
    </table>
    <h3 style="font-size:13px">これまでの経路</h3>
    <ul style="list-style:none;margin-bottom:4px">${stepsHtml || '<li>—</li>'}</ul>
    <div class="modal-actions">
      <button class="btn" data-act="close">閉じる</button>
      <button class="btn btn-danger" data-act="reject">見送る</button>
      <button class="btn btn-primary" data-act="go">${isAdmin ? '受け入れて選考へ' : 'アップラインへ送客'}</button>
    </div>`);
  m.el.querySelector('[data-act="close"]').onclick = () => m.close();
  m.el.querySelector('[data-act="reject"]').onclick = () => { m.close(); decide(cand.id, 'reject', onDone); };
  m.el.querySelector('[data-act="go"]').onclick = () => { m.close(); decide(cand.id, isAdmin ? 'accept' : 'forward', onDone); };
}

async function render(el) {
  const c = sb();
  const isAdmin = S.role === 'kanoa';

  let q = c.from('candidates')
    .select('id,name,kana,phone,email,address,area,note,stage,registered_by,created_at')
    .eq('stage', 'relay').order('created_at');
  q = isAdmin ? q.is('holder_id', null) : q.eq('holder_id', S.company.id);
  const { data: cands, error } = await q;
  if (error) throw error;

  // 紹介元（自分のフロント）の名前を解決（RLSで見える範囲）
  const ids = [...new Set((cands || []).map((x) => x.registered_by))];
  let nameMap = {};
  if (ids.length) {
    const { data: comps } = await c.from('companies').select('id,name,code').in('id', ids);
    nameMap = Object.fromEntries((comps || []).map((x) => [x.id, `${x.name}（${x.code}）`]));
  }

  const rows = (cands || []).map((x) => `
    <tr data-id="${x.id}" style="cursor:pointer">
      <td><b>${esc(x.name)}</b>${x.kana ? `<br><small style="color:var(--c-text-sub)">${esc(x.kana)}</small>` : ''}</td>
      <td>${esc(nameMap[x.registered_by] || '—')}</td>
      <td>${esc(x.area || '—')}</td>
      <td>${fmtDate(x.created_at)}</td>
      <td><button class="btn" data-open="${x.id}">確認する</button></td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <h2>${isAdmin ? '紹介された求職者（受入待ち）' : '紹介された求職者（判断待ち）'}</h2>
      <p style="font-size:12.5px;color:var(--c-text-sub);margin-bottom:12px">
        ${isAdmin ? 'Aラインから送客された求職者です。内容を確認して受入（選考へ）または見送りを判断してください。'
                  : 'フロント企業から紹介された求職者です。内容を確認して、アップラインへ「送客」するか「見送る」かを判断してください。'}</p>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th>氏名</th><th>紹介元</th><th>希望エリア</th><th>受信日</th><th></th></tr>${rows}</table></div>`
      : `<div class="empty">いま判断待ちの求職者はいません。</div>`}
    </div>`;

  el.querySelectorAll('[data-open]').forEach((b) => {
    b.onclick = () => {
      const cand = (cands || []).find((x) => x.id === b.dataset.open);
      if (cand) detailModal(cand, nameMap, () => render(el));
    };
  });
}

register('relay', {
  title: '紹介された求職者', nav: true, icon: '📥', render,
});
