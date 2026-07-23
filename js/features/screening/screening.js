// 選考管理（KANOA）: 受け入れた求職者の選考ステータスを管理（V1の中核機能の移植）
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { esc, fmtDate, fmtDateTime } from '../../ui/format.js';
import { toast, openModal } from '../../ui/components.js';
import { docsModal } from '../../ui/docs.js';

export const SELECTION_STATUS = {
  entry: '送客済', screening: '書類選考', interview: '選考会',
  offer: '内定', joined: '入社', rejected: '見送り', declined: '辞退',
};
const TABS = [
  { key: 'active', label: '選考中', match: (s) => ['entry', 'screening', 'interview'].includes(s) },
  { key: 'offer', label: '内定', match: (s) => s === 'offer' },
  { key: 'joined', label: '入社', match: (s) => s === 'joined' },
  { key: 'out', label: '見送り・辞退', match: (s) => ['rejected', 'declined'].includes(s) },
  { key: 'all', label: 'すべて', match: () => true },
];
let activeTab = 'active';

async function detailModal(cand, nameMap, onDone) {
  const { data: steps } = await sb().from('candidate_steps')
    .select('company_id,action,note,created_at').eq('candidate_id', cand.id).order('created_at');
  const stepLabel = { registered: '登録', forwarded: '送客', rejected: '見送り', accepted: 'KANOA受入' };
  const stepsHtml = (steps || []).map((s) => `
    <li style="font-size:12px;margin-bottom:4px">
      ${esc(s.company_id ? (nameMap[s.company_id] || '—') : 'KANOA')} が ${esc(stepLabel[s.action] || s.action)}
      <small style="color:var(--c-text-sub)">（${fmtDateTime(s.created_at)}）</small>
      ${s.note ? `<br><small>💬 ${esc(s.note)}</small>` : ''}
    </li>`).join('');

  const m = openModal(`
    <h3>${esc(cand.name)}${cand.kana ? ` <small style="color:var(--c-text-sub)">${esc(cand.kana)}</small>` : ''}</h3>
    <table class="table" style="margin-bottom:12px">
      <tr><th style="width:100px">電話</th><td>${esc(cand.phone || '—')}</td></tr>
      <tr><th>メール</th><td>${esc(cand.email || '—')}</td></tr>
      <tr><th>希望エリア</th><td>${esc(cand.area || '—')}</td></tr>
      <tr><th>紹介元</th><td>${esc(nameMap[cand.registered_by] || '—')}</td></tr>
    </table>
    <form id="scr-form">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
        <div class="field"><label>選考ステータス</label><select name="status">
          ${Object.entries(SELECTION_STATUS).map(([k, l]) => `<option value="${k}" ${cand.status === k ? 'selected' : ''}>${l}</option>`).join('')}
        </select></div>
        <div class="field"><label>入社日</label><input name="joined_on" type="date" value="${cand.joined_on || ''}"></div>
      </div>
      <div class="field"><label>選考会・面談メモ</label><input name="session" value="${esc(cand.session || '')}" placeholder="例: 7/30 14:00 選考会"></div>
      <div class="field"><label>社内メモ</label><textarea name="note" rows="2">${esc(cand.note || '')}</textarea></div>
      <div class="modal-actions">
        <button type="button" class="btn" data-act="close">閉じる</button>
        <button type="button" class="btn" data-act="docs">📎 書類</button>
        <button class="btn btn-primary">保存</button>
      </div>
    </form>
    <h3 style="font-size:13px;margin-top:6px">経路</h3>
    <ul style="list-style:none">${stepsHtml || '<li>—</li>'}</ul>`);

  m.el.querySelector('[data-act="close"]').onclick = () => m.close();
  m.el.querySelector('[data-act="docs"]').onclick = () => docsModal(cand);
  m.el.querySelector('#scr-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const { error } = await sb().from('candidates').update({
      status: f.get('status'), joined_on: f.get('joined_on') || null,
      session: f.get('session') || null, note: f.get('note') || null,
    }).eq('id', cand.id);
    if (error) { toast(`保存に失敗しました（${error.message}）`, 'err'); return; }
    toast('保存しました', 'ok'); m.close(); onDone();
  };
}

async function render(el) {
  const c = sb();
  const { data: cands, error } = await c.from('candidates')
    .select('*').eq('stage', 'screening').order('created_at', { ascending: false });
  if (error) throw error;

  const ids = [...new Set((cands || []).map((x) => x.registered_by))];
  let nameMap = {};
  if (ids.length) {
    const { data: comps } = await c.from('companies').select('id,name,code').in('id', ids);
    nameMap = Object.fromEntries((comps || []).map((x) => [x.id, `${x.name}（${x.code}）`]));
  }

  const tab = TABS.find((t) => t.key === activeTab) || TABS[0];
  const list = (cands || []).filter((x) => tab.match(x.status));
  const counts = Object.fromEntries(TABS.map((t) => [t.key, (cands || []).filter((x) => t.match(x.status)).length]));

  const rows = list.map((x) => `
    <tr>
      <td><b>${esc(x.name)}</b></td>
      <td>${esc(SELECTION_STATUS[x.status] || x.status || '—')}</td>
      <td>${esc(nameMap[x.registered_by] || '—')}</td>
      <td>${esc(x.session || '—')}</td>
      <td>${fmtDate(x.joined_on)}</td>
      <td><button class="btn" data-open="${x.id}">開く</button></td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <h2>選考管理</h2>
      <div style="display:flex;gap:6px;margin:10px 0;flex-wrap:wrap">
        ${TABS.map((t) => `<button class="btn ${t.key === activeTab ? 'btn-primary' : ''}" data-tab="${t.key}">
          ${t.label}（${counts[t.key]}）</button>`).join('')}
      </div>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th>氏名</th><th>ステータス</th><th>紹介元</th><th>選考会</th><th>入社日</th><th></th></tr>${rows}</table></div>`
      : '<div class="empty">該当する求職者はいません。</div>'}
    </div>`;

  el.querySelectorAll('[data-tab]').forEach((b) => {
    b.onclick = () => { activeTab = b.dataset.tab; render(el); };
  });
  el.querySelectorAll('[data-open]').forEach((b) => {
    b.onclick = () => {
      const cand = list.find((x) => x.id === b.dataset.open);
      if (cand) detailModal(cand, nameMap, () => render(el));
    };
  });
}

register('screening', { title: '選考管理', nav: true, icon: '📊', roles: ['kanoa'], render });
