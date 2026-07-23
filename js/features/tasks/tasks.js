// タスク: KANOA=全社向け・特定企業向けの依頼を管理／パートナー=自社のタスク
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { toast, openModal } from '../../ui/components.js';

async function addModal(onDone) {
  const isAdmin = S.role === 'kanoa';
  let compOptions = '';
  if (isAdmin) {
    const { data: comps } = await sb().from('companies').select('id,code,name').eq('status', 'active').order('code');
    compOptions = (comps || []).map((x) => `<option value="${x.id}">${esc(x.code)} ${esc(x.name)}</option>`).join('');
  }
  const m = openModal(`
    <h3>タスクを追加</h3>
    <form id="task-form">
      <div class="field"><label>内容 *</label><input name="body" required></div>
      <div class="field"><label>期日</label><input name="due" type="date"></div>
      ${isAdmin ? `<div class="field"><label>依頼先</label><select name="company_id">
        <option value="">KANOA社内</option>${compOptions}</select></div>` : ''}
      <div class="modal-actions">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn btn-primary">追加</button>
      </div>
    </form>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('#task-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const row = {
      body: f.get('body'), due: f.get('due') || null,
      owner: isAdmin ? 'kanoa' : S.company.id,
      from_owner: isAdmin ? 'kanoa' : S.company.id,
      company_id: isAdmin ? (f.get('company_id') || null) : S.company.id,
    };
    const { error } = await sb().from('tasks_v2').insert(row);
    if (error) { toast(`追加に失敗しました（${error.message}）`, 'err'); return; }
    toast('追加しました', 'ok'); m.close(); onDone();
  };
}

async function render(el) {
  const c = sb();
  const isAdmin = S.role === 'kanoa';
  let q = c.from('tasks_v2').select('*').order('done').order('due', { ascending: true, nullsFirst: false }).order('created_at');
  if (!isAdmin) q = q.eq('company_id', S.company.id);
  const { data: tasks, error } = await q;
  if (error) throw error;

  let nameMap = {};
  if (isAdmin) {
    const ids = [...new Set((tasks || []).map((x) => x.company_id).filter(Boolean))];
    if (ids.length) {
      const { data: comps } = await c.from('companies').select('id,code').in('id', ids);
      nameMap = Object.fromEntries((comps || []).map((x) => [x.id, x.code]));
    }
  }

  const overdue = (t) => !t.done && t.due && t.due < new Date().toISOString().slice(0, 10);
  const rows = (tasks || []).map((t) => `
    <tr style="${t.done ? 'opacity:.5' : ''}">
      <td><input type="checkbox" data-done="${t.id}" ${t.done ? 'checked' : ''}></td>
      <td style="${t.done ? 'text-decoration:line-through' : ''}">${esc(t.body)}</td>
      ${isAdmin ? `<td>${esc(nameMap[t.company_id] || 'KANOA')}</td>` : ''}
      <td style="${overdue(t) ? 'color:var(--c-danger);font-weight:700' : ''}">${fmtDate(t.due)}</td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h2 style="margin:0">タスク</h2>
        <button class="btn btn-primary" id="btn-add">＋ タスクを追加</button>
      </div>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th style="width:36px"></th><th>内容</th>${isAdmin ? '<th>依頼先</th>' : ''}<th>期日</th></tr>${rows}</table></div>`
      : '<div class="empty">タスクはありません。</div>'}
    </div>`;

  el.querySelector('#btn-add').onclick = () => addModal(() => render(el));
  el.querySelectorAll('[data-done]').forEach((cb) => {
    cb.onchange = async () => {
      const { error: e2 } = await c.from('tasks_v2').update({ done: cb.checked }).eq('id', cb.dataset.done);
      if (e2) { toast('更新に失敗しました', 'err'); cb.checked = !cb.checked; return; }
      render(el);
    };
  });
}

register('tasks', { title: 'タスク', nav: true, icon: '✅', render });
