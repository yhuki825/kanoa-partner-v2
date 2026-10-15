// 紹介料（請求）: KANOA↔Aラインのみ
// フロー: 下書き(draft)→提出(submitted)→承認(accepted)→支払済み(paid)／差戻し(rejected)→再提出
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen, fmtDate } from '../../ui/format.js';
import { toast, openModal, confirmDialog } from '../../ui/components.js';

const STATUS = {
  draft: '下書き', submitted: '提出済み', accepted: '承認済み', rejected: '差戻し', paid: '支払済み',
};
const TAX_RATE = 0.10;

function calc(items) {
  const subtotal = items.reduce((a, x) => a + (Number(x.qty) || 0) * (Number(x.price) || 0), 0);
  const tax = Math.floor(subtotal * TAX_RATE);
  return { subtotal, tax, total: subtotal + tax };
}

/* ---------- 作成・編集（Aライン） ---------- */
function editModal(inv, onDone) {
  const items = (inv?.items?.length ? structuredClone(inv.items) : [{ desc: '', qty: 1, price: 0 }]);
  const m = openModal(`
    <h3>${inv ? '請求を編集' : '新規請求（下書き）'}</h3>
    <div id="item-rows"></div>
    <button class="btn" id="add-row" style="margin-bottom:12px">＋ 行を追加</button>
    <div id="totals" style="text-align:right;font-size:13px;margin-bottom:8px"></div>
    <div class="modal-actions">
      <button class="btn" data-act="cancel">キャンセル</button>
      <button class="btn btn-primary" data-act="save">下書き保存</button>
    </div>`);

  const rowsEl = m.el.querySelector('#item-rows');
  const totalsEl = m.el.querySelector('#totals');
  function draw() {
    rowsEl.innerHTML = items.map((x, i) => `
      <div style="display:grid;grid-template-columns:1fr 70px 110px 30px;gap:6px;margin-bottom:6px">
        <input placeholder="内容（例: ○○様 成約報酬）" value="${esc(x.desc)}" data-f="desc" data-i="${i}">
        <input type="number" min="1" value="${x.qty}" data-f="qty" data-i="${i}">
        <input type="number" min="0" value="${x.price}" data-f="price" data-i="${i}" placeholder="単価">
        <button class="btn" data-rm="${i}" ${items.length === 1 ? 'disabled' : ''}>×</button>
      </div>`).join('');
    const t = calc(items);
    totalsEl.innerHTML = `小計 ${fmtYen(t.subtotal)} ／ 消費税 ${fmtYen(t.tax)} ／ <b>合計 ${fmtYen(t.total)}</b>`;
    rowsEl.querySelectorAll('input').forEach((inp) => {
      inp.onchange = () => { items[inp.dataset.i][inp.dataset.f] = inp.dataset.f === 'desc' ? inp.value : Number(inp.value); draw(); };
    });
    rowsEl.querySelectorAll('[data-rm]').forEach((b) => {
      b.onclick = () => { items.splice(Number(b.dataset.rm), 1); draw(); };
    });
  }
  draw();
  m.el.querySelector('#add-row').onclick = () => { items.push({ desc: '', qty: 1, price: 0 }); draw(); };
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('[data-act="save"]').onclick = async () => {
    const valid = items.filter((x) => x.desc.trim());
    if (!valid.length) { toast('内容を入力してください', 'err'); return; }
    const t = calc(valid);
    const row = { items: valid, ...t, company_id: S.company.id, status: 'draft' };
    const q = inv
      ? sb().from('invoices_v2').update({ items: valid, ...t }).eq('id', inv.id)
      : sb().from('invoices_v2').insert(row);
    const { error } = await q;
    if (error) { toast(`保存に失敗しました（${error.message}）`, 'err'); return; }
    toast('保存しました', 'ok'); m.close(); onDone();
  };
}

/* ---------- 状態遷移 ---------- */
async function transition(inv, to, onDone, extra = {}) {
  const now = new Date().toISOString().slice(0, 10);
  const patch = { status: to, ...extra };
  if (to === 'submitted') patch.submitted_on = now;
  if (to === 'accepted' || to === 'rejected') patch.decided_on = now;
  if (to === 'paid') patch.paid_on = now;
  patch.history = [...(inv.history || []), { at: new Date().toISOString(), to, by: S.role, reason: extra.reject_reason || null }];
  const { error } = await sb().from('invoices_v2').update(patch).eq('id', inv.id);
  if (error) { toast(`更新に失敗しました（${error.message}）`, 'err'); return; }
  toast({ submitted: '提出しました', accepted: '承認しました', rejected: '差し戻しました', paid: '支払済みにしました' }[to], 'ok');
  onDone();
}

/* ---------- 詳細 ---------- */
function detailModal(inv, nameMap, onDone) {
  const isAdmin = S.role === 'kanoa';
  const itemRows = (inv.items || []).map((x) => `
    <tr><td>${esc(x.desc)}</td><td style="text-align:right">${x.qty}</td>
    <td style="text-align:right">${fmtYen(x.price)}</td><td style="text-align:right">${fmtYen(x.qty * x.price)}</td></tr>`).join('');

  const actions = [];
  if (!isAdmin && (inv.status === 'draft' || inv.status === 'rejected')) {
    actions.push('<button class="btn" data-act="edit">編集</button>');
    actions.push('<button class="btn btn-primary" data-act="submit">提出する</button>');
    if (inv.status === 'draft') actions.push('<button class="btn btn-danger" data-act="delete">削除</button>');
  }
  if (isAdmin && inv.status === 'submitted') {
    actions.push('<button class="btn btn-danger" data-act="reject">差し戻す</button>');
    actions.push('<button class="btn btn-primary" data-act="accept">承認する</button>');
  }
  if (isAdmin && inv.status === 'accepted') {
    actions.push('<button class="btn btn-primary" data-act="paid">支払済みにする</button>');
  }

  const m = openModal(`
    <h3>請求 ${esc(inv.no || '')} <small style="color:var(--c-text-sub)">${esc(STATUS[inv.status])}</small></h3>
    ${isAdmin ? `<p style="font-size:12.5px;margin-bottom:8px">請求元: ${esc(nameMap[inv.company_id] || '—')}</p>` : ''}
    ${inv.status === 'rejected' && inv.reject_reason ? `<p style="color:var(--c-danger);font-size:12.5px;margin-bottom:8px">差戻し理由: ${esc(inv.reject_reason)}</p>` : ''}
    <div style="overflow-x:auto"><table class="table" style="margin-bottom:10px">
      <tr><th>内容</th><th style="text-align:right">数量</th><th style="text-align:right">単価</th><th style="text-align:right">金額</th></tr>
      ${itemRows}
      <tr><td colspan="3" style="text-align:right">小計</td><td style="text-align:right">${fmtYen(inv.subtotal)}</td></tr>
      <tr><td colspan="3" style="text-align:right">消費税</td><td style="text-align:right">${fmtYen(inv.tax)}</td></tr>
      <tr><td colspan="3" style="text-align:right"><b>合計</b></td><td style="text-align:right"><b>${fmtYen(inv.total)}</b></td></tr>
    </table></div>
    <p style="font-size:11.5px;color:var(--c-text-sub)">提出 ${fmtDate(inv.submitted_on)} ／ 判定 ${fmtDate(inv.decided_on)} ／ 支払 ${fmtDate(inv.paid_on)}</p>
    <div class="modal-actions"><button class="btn" data-act="close">閉じる</button>${actions.join('')}</div>`);

  m.el.querySelector('[data-act="close"]').onclick = () => m.close();
  const bind = (act, fn) => { const b = m.el.querySelector(`[data-act="${act}"]`); if (b) b.onclick = fn; };
  bind('edit', () => { m.close(); editModal(inv, onDone); });
  bind('submit', async () => {
    if (!await confirmDialog('この内容でKANOAへ提出しますか？', { okLabel: '提出する' })) return;
    m.close(); transition(inv, 'submitted', onDone);
  });
  bind('delete', async () => {
    if (!await confirmDialog('この下書きを削除しますか？', { okLabel: '削除', danger: true })) return;
    await sb().from('invoices_v2').delete().eq('id', inv.id);
    toast('削除しました', 'ok'); m.close(); onDone();
  });
  bind('accept', async () => {
    if (!await confirmDialog('この請求を承認しますか？', { okLabel: '承認する' })) return;
    m.close(); transition(inv, 'accepted', onDone);
  });
  bind('reject', () => {
    const reason = prompt('差戻し理由を入力してください');
    if (reason == null) return;
    m.close(); transition(inv, 'rejected', onDone, { reject_reason: reason });
  });
  bind('paid', () => { m.close(); transition(inv, 'paid', onDone); });
}

async function render(el) {
  const c = sb();
  const isAdmin = S.role === 'kanoa';

  if (!isAdmin && S.company.tier !== 1) {
    el.innerHTML = '<div class="card"><div class="empty">紹介料の請求は、KANOAと直接契約しているAライン企業のみが行えます。<br>あなたの紹介料はアップライン企業との取り決めに従ってください。</div></div>';
    return;
  }

  let q = c.from('invoices_v2').select('*').order('created_at', { ascending: false });
  if (!isAdmin) q = q.eq('company_id', S.company.id);
  const { data: invs, error } = await q;
  if (error) throw error;

  let nameMap = {};
  if (isAdmin) {
    const ids = [...new Set((invs || []).map((x) => x.company_id))];
    if (ids.length) {
      const { data: comps } = await c.from('companies').select('id,name,code').in('id', ids);
      nameMap = Object.fromEntries((comps || []).map((x) => [x.id, `${x.name}（${x.code}）`]));
    }
  }

  const rows = (invs || []).map((x) => `
    <tr>
      ${isAdmin ? `<td>${esc(nameMap[x.company_id] || '—')}</td>` : ''}
      <td>${fmtYen(x.total)}</td>
      <td>${esc(STATUS[x.status] || x.status)}</td>
      <td>${fmtDate(x.submitted_on || x.created_at)}</td>
      <td><button class="btn" data-open="${x.id}">詳細</button></td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h2 style="margin:0">紹介料（請求）</h2>
        ${!isAdmin ? '<button class="btn btn-primary" id="btn-new">＋ 新規請求</button>' : ''}
      </div>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr>${isAdmin ? '<th>請求元</th>' : ''}<th>合計</th><th>状態</th><th>日付</th><th></th></tr>${rows}</table></div>`
      : '<div class="empty">請求はまだありません。</div>'}
    </div>`;

  const newBtn = el.querySelector('#btn-new');
  if (newBtn) newBtn.onclick = () => editModal(null, () => render(el));
  el.querySelectorAll('[data-open]').forEach((b) => {
    b.onclick = () => {
      const inv = (invs || []).find((x) => x.id === b.dataset.open);
      if (inv) detailModal(inv, nameMap, () => render(el));
    };
  });
}

register('invoices', {
  title: '紹介料', nav: true, icon: '💴', render,
  when: () => S.role === 'kanoa' || S.company?.tier === 1,
});
