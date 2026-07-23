// 案件: KANOA=作成・編集・Aラインへの公開／パートナー=閲覧・フロントへの共有
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen, fmtDate } from '../../ui/format.js';
import { toast, openModal, confirmDialog } from '../../ui/components.js';

const STATUS_LABEL = { open: '募集中', paused: '一時停止', closed: '終了' };

/* ---------- KANOA: 案件の作成・編集 ---------- */
function editModal(pj, onDone) {
  const v = pj || {};
  const m = openModal(`
    <h3>${pj ? '案件を編集' : '新規案件'}</h3>
    <form id="pj-form">
      <div class="field"><label>案件名 *</label><input name="name" required value="${esc(v.name || '')}"></div>
      <div class="field"><label>クライアント企業</label><input name="client" value="${esc(v.client || '')}"></div>
      <div class="field"><label>職種</label><input name="position" value="${esc(v.position || '')}"></div>
      <div class="field"><label>雇用形態</label><input name="employment" value="${esc(v.employment || '')}"></div>
      <div class="field"><label>給与</label><input name="salary" value="${esc(v.salary || '')}"></div>
      <div class="field"><label>勤務地</label><input name="location" value="${esc(v.location || '')}"></div>
      <div class="field"><label>概要</label><textarea name="summary" rows="3">${esc(v.summary || '')}</textarea></div>
      <div class="field"><label>条件・備考</label><textarea name="conditions" rows="3">${esc(v.conditions || '')}</textarea></div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
        <div class="field"><label>送客報酬（円）</label><input name="referral_reward" type="number" min="0" value="${v.referral_reward ?? 0}"></div>
        <div class="field"><label>成約報酬（円）</label><input name="success_reward" type="number" min="0" value="${v.success_reward ?? 0}"></div>
      </div>
      <div class="field"><label>状態</label><select name="status">
        ${Object.entries(STATUS_LABEL).map(([k, l]) => `<option value="${k}" ${v.status === k ? 'selected' : ''}>${l}</option>`).join('')}
      </select></div>
      <div class="modal-actions">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn btn-primary">保存</button>
      </div>
    </form>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('#pj-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const row = Object.fromEntries(['name','client','position','employment','salary','location','summary','conditions','status'].map((k) => [k, f.get(k) || null]));
    row.referral_reward = Number(f.get('referral_reward') || 0);
    row.success_reward = Number(f.get('success_reward') || 0);
    const q = pj
      ? sb().from('projects_v2').update(row).eq('id', pj.id)
      : sb().from('projects_v2').insert(row);
    const { error } = await q;
    if (error) { toast(`保存に失敗しました（${error.message}）`, 'err'); return; }
    toast('保存しました', 'ok'); m.close(); onDone();
  };
}

/* ---------- 共有管理（KANOA→Aライン / パートナー→フロント） ---------- */
async function shareModal(pj, onDone) {
  const c = sb();
  const isAdmin = S.role === 'kanoa';
  // 共有先候補: KANOA=Aライン全社 / パートナー=自分のフロント
  let compQ = c.from('companies').select('id,code,name').eq('status', 'active').order('code');
  compQ = isAdmin ? compQ.eq('tier', 1) : compQ.eq('parent_id', S.company.id);
  const [{ data: comps }, { data: shares }] = await Promise.all([
    compQ,
    c.from('project_shares').select('company_id,published').eq('project_id', pj.id),
  ]);
  const shared = new Set((shares || []).filter((s) => s.published).map((s) => s.company_id));
  const rows = (comps || []).map((x) => `
    <label style="display:flex;align-items:center;gap:8px;padding:7px 4px;border-bottom:1px solid var(--c-border)">
      <input type="checkbox" data-share="${x.id}" ${shared.has(x.id) ? 'checked' : ''}>
      <b>${esc(x.code)}</b> ${esc(x.name)}
    </label>`).join('');

  const m = openModal(`
    <h3>「${esc(pj.name)}」の共有先</h3>
    <p style="font-size:12.5px;color:var(--c-text-sub);margin-bottom:8px">
      ${isAdmin ? 'チェックしたAライン企業がこの案件を見られます。' : 'チェックしたフロント企業がこの案件を見られます。'}</p>
    ${rows || '<div class="empty">共有できる相手がいません</div>'}
    <div class="modal-actions"><button class="btn btn-primary" data-act="done">完了</button></div>`);

  m.el.querySelectorAll('[data-share]').forEach((cb) => {
    cb.onchange = async () => {
      const companyId = cb.dataset.share;
      if (cb.checked) {
        const { error } = await c.from('project_shares').upsert({
          project_id: pj.id, company_id: companyId,
          shared_by: isAdmin ? null : S.company.id, published: true,
        });
        if (error) { toast(`共有に失敗しました（${error.message}）`, 'err'); cb.checked = false; }
      } else {
        const { error } = await c.from('project_shares').delete()
          .eq('project_id', pj.id).eq('company_id', companyId);
        if (error) { toast(`解除に失敗しました（${error.message}）`, 'err'); cb.checked = true; }
      }
    };
  });
  m.el.querySelector('[data-act="done"]').onclick = () => { m.close(); onDone(); };
}

/* ---------- 詳細 ---------- */
function detailModal(pj, onDone) {
  const isAdmin = S.role === 'kanoa';
  const m = openModal(`
    <h3>${esc(pj.name)} <small style="color:var(--c-text-sub)">${esc(STATUS_LABEL[pj.status] || '')}</small></h3>
    <table class="table" style="margin-bottom:12px">
      <tr><th style="width:110px">クライアント</th><td>${esc(pj.client || '—')}</td></tr>
      <tr><th>職種</th><td>${esc(pj.position || '—')}</td></tr>
      <tr><th>雇用形態</th><td>${esc(pj.employment || '—')}</td></tr>
      <tr><th>給与</th><td>${esc(pj.salary || '—')}</td></tr>
      <tr><th>勤務地</th><td>${esc(pj.location || '—')}</td></tr>
      <tr><th>概要</th><td>${esc(pj.summary || '—')}</td></tr>
      <tr><th>条件・備考</th><td>${esc(pj.conditions || '—')}</td></tr>
      ${isAdmin ? `<tr><th>送客/成約報酬</th><td>${fmtYen(pj.referral_reward)} ／ ${fmtYen(pj.success_reward)}</td></tr>` : ''}
    </table>
    <div class="modal-actions">
      <button class="btn" data-act="close">閉じる</button>
      <button class="btn" data-act="share">共有先を管理</button>
      ${isAdmin ? '<button class="btn btn-primary" data-act="edit">編集</button>' : ''}
    </div>`);
  m.el.querySelector('[data-act="close"]').onclick = () => m.close();
  m.el.querySelector('[data-act="share"]').onclick = () => { m.close(); shareModal(pj, onDone); };
  const editBtn = m.el.querySelector('[data-act="edit"]');
  if (editBtn) editBtn.onclick = () => { m.close(); editModal(pj, onDone); };
}

async function render(el) {
  const isAdmin = S.role === 'kanoa';
  const { data: pjs, error } = await sb().from('projects_v2')
    .select('*').order('created_at', { ascending: false });
  if (error) throw error;

  const rows = (pjs || []).map((x) => `
    <tr>
      <td><b>${esc(x.name)}</b>${x.client ? `<br><small style="color:var(--c-text-sub)">${esc(x.client)}</small>` : ''}</td>
      <td>${esc(x.position || '—')}</td>
      <td>${esc(x.location || '—')}</td>
      <td>${esc(STATUS_LABEL[x.status] || '—')}</td>
      <td><button class="btn" data-open="${x.id}">詳細</button></td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h2 style="margin:0">案件</h2>
        ${isAdmin ? '<button class="btn btn-primary" id="btn-new">＋ 新規案件</button>' : ''}
      </div>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th>案件名</th><th>職種</th><th>勤務地</th><th>状態</th><th></th></tr>${rows}</table></div>`
      : `<div class="empty">${isAdmin ? 'まだ案件がありません。「新規案件」から作成できます。' : '共有されている案件はまだありません。'}</div>`}
    </div>`;

  const newBtn = el.querySelector('#btn-new');
  if (newBtn) newBtn.onclick = () => editModal(null, () => render(el));
  el.querySelectorAll('[data-open]').forEach((b) => {
    b.onclick = () => {
      const pj = (pjs || []).find((x) => x.id === b.dataset.open);
      if (pj) detailModal(pj, () => render(el));
    };
  });
}

register('projects', { title: '案件', nav: true, icon: '📋', render });
