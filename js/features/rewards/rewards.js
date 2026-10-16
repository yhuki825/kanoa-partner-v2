// 報酬（設計書14）: 入社時の成約報酬。支払先は1次パートナー
// ・RA: 全件。支払済み・退職・返金済みを記録する（DBの関数でだけ書ける）
// ・1次パートナー（CA）: 自社が支払先の分を閲覧のみ（2次以降はメニューにも出さない。DBも1行も返さない）
// ・金額は税抜で保存。消費税・税込の計算は ui/money.js の1か所だけで行う
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, fmtYen } from '../../ui/format.js';
import { openModal, confirmDialog, showError, toast, busy } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { withTax, totalOf, refundPolicyLines, TAX_PERCENT } from '../../ui/money.js';

const isRA = () => S.role === 'ra';
const visible = () => isRA() || (S.role === 'ca' && S.company?.tier === 1);

const TABS = [
  { key: 'pending', label: '支払待ち', match: (r) => r.pay_status === 'pending' },
  { key: 'paid', label: '支払済み', match: (r) => r.pay_status === 'paid' },
  { key: 'refund', label: '返金あり', match: (r) => r.refund_status != null },
  { key: 'all', label: 'すべて', match: () => true },
];

const pad = (n) => String(n).padStart(2, '0');
function today() { const d = new Date(); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }

// 報酬の行を全部読む（見えない行はDBが返さない）。1000件ずつ
async function loadRewards() {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb().from('v2_rewards').select('*, company:v2_companies!v2_rewards_payee_company_id_fkey(code,name), candidate:v2_candidates!v2_rewards_candidate_id_fkey(name), job:v2_jobs!v2_rewards_job_id_fkey(title, client:v2_clients!v2_jobs_client_id_fkey(name))')
      .order('joined_on', { ascending: false }).order('application_id').range(from, from + 999);
    if (error) throw userError(error, '報酬を読み込めませんでした');
    rows.push(...data);
    if (data.length < 1000) return rows;
  }
}

function moneyCell(amount) {
  const m = withTax(amount);
  if (m.net == null) return '—';
  return `<div class="money"><b class="mono">${fmtYen(m.total)}</b>
    <small class="sub">税抜 <span class="mono">${fmtYen(m.net)}</span>／消費税 <span class="mono">${fmtYen(m.tax)}</span></small></div>`;
}
function payCell(r) {
  return r.pay_status === 'paid'
    ? `<span class="tag st-done">支払済み</span><br><small class="sub">${fmtDate(r.paid_on)}</small>`
    : '<span class="tag st-wait">支払待ち</span>';
}
function refundCell(r) {
  if (r.refund_amount == null) return '—';
  if (Number(r.refund_amount) === 0) return '<span class="sub">返金なし</span>';
  return `<b class="mono">${fmtYen(totalOf(r.refund_amount))}</b><br>${r.refund_status === 'refunded'
    ? `<span class="tag st-done">返金済み</span> <small class="sub">${fmtDate(r.refunded_on)}</small>`
    : '<span class="tag st-wait">返金待ち</span>'}`;
}
function actionsOf(r) {
  const a = [];
  if (r.pay_status === 'pending') a.push(['paid', '支払済みにする', 'btn-primary']);
  else if (!r.refund_status) a.push(['unpaid', '支払済みを取り消す', '']);
  if (r.refund_status !== 'refunded') a.push(['resign', r.resigned_on ? '退職日を直す' : '退職を記録', '']);
  if (r.resigned_on && r.refund_status !== 'refunded') a.push(['unresign', '退職の記録を消す', '']);
  if (r.refund_status === 'pending' && r.pay_status === 'paid') a.push(['refunded', '返金済みにする', 'btn-primary']);
  return a;
}

// 日付を1つ入れる小さなモーダル。キャンセルなら null
function dateModal({ title, label, value, about = '', okLabel }) {
  return new Promise((resolve) => {
    let done = false;
    const m = openModal(`
      <h3>${esc(title)}</h3>
      ${about}
      <form novalidate>
        <div class="field"><label for="rw-date">${esc(label)}</label>
          <input id="rw-date" name="d" type="date" value="${esc(value || '')}" required></div>
        <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button>
          <button class="btn btn-primary">${esc(okLabel)}</button></div>
      </form>`, { onClose: () => { if (!done) resolve(null); } });
    m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
    m.el.querySelector('form').onsubmit = (e) => {
      e.preventDefault();
      const d = String(new FormData(e.target).get('d') || '');
      if (!d) { showError(new Error(`${label}を入れてください。`), title); return; }
      done = true; resolve(d); m.close();
    };
  });
}

function aboutHtml(r, extra = '') {
  return `<dl class="kv">
    <dt>求職者</dt><dd>${esc(r.candidate?.name || '—')}</dd>
    <dt>支払先</dt><dd>${esc(r.company?.code || '')} ${esc(r.company?.name || '')}</dd>
    <dt>入社日</dt><dd>${fmtDate(r.joined_on)}</dd>
    <dt>紹介料（税込）</dt><dd class="mono">${fmtYen(totalOf(r.fee_amount))}</dd>${extra}</dl>`;
}

async function rpc(fn, args, fallback) {
  const { data, error } = await sb().rpc(fn, args);
  if (error) throw userError(error, fallback);
  return data;
}

async function runAction(act, r, reload) {
  const name = r.candidate?.name || '';
  if (act === 'paid') {
    const d = await dateModal({ title: '支払済みにする', label: '支払日', value: today(), okLabel: '支払済みにする', about: aboutHtml(r) });
    if (!d) return;
    await rpc('v2_reward_mark_paid', { p_app: r.application_id, p_paid_on: d }, '支払済みにできませんでした');
    toast('支払済みにしました');
  } else if (act === 'unpaid') {
    if (!await confirmDialog(`${name}さんの報酬の「支払済み」を取り消して、支払待ちに戻しますか？`, { okLabel: '取り消す', danger: true })) return;
    await rpc('v2_reward_unmark_paid', { p_app: r.application_id }, '支払済みを取り消せませんでした');
    toast('支払待ちに戻しました');
  } else if (act === 'resign') {
    const lines = refundPolicyLines(r.refund_policy);
    const policy = `<dt>返金規定</dt><dd>${lines.length ? lines.map(esc).join('<br>') : '返金規定なし（返金は発生しません）'}
      <br><small class="sub">入社が確定した時点の規定です</small></dd>`;
    const d = await dateModal({ title: r.resigned_on ? '退職日を直す' : '退職を記録', label: '退職日', value: r.resigned_on || today(),
      okLabel: '記録する', about: aboutHtml(r, policy) });
    if (!d) return;
    const res = await rpc('v2_reward_record_resignation', { p_app: r.application_id, p_resigned_on: d }, '退職を記録できませんでした');
    const saved = Array.isArray(res) ? res[0] : res;   // 更新後の報酬の行（返金率・返金額はDBが計算）
    const amt = withTax(saved.refund_amount);
    const m = openModal(`
      <h3>退職を記録しました</h3>
      <dl class="kv">
        <dt>退職日</dt><dd>${fmtDate(saved.resigned_on)}（入社日 ${fmtDate(saved.joined_on)}）</dd>
        <dt>返金率</dt><dd class="mono">${saved.refund_rate}%</dd>
        <dt>返金額</dt><dd>${Number(saved.refund_amount) > 0
          ? `<b class="mono">${fmtYen(amt.total)}</b>（税込）<br><small class="sub">税抜 ${fmtYen(amt.net)}／消費税 ${fmtYen(amt.tax)}</small>`
          : '返金はありません（返金規定の期間外です）'}</dd>
      </dl>
      <div class="modal-actions"><button class="btn btn-primary" data-act="ok">閉じる</button></div>`);
    m.el.querySelector('[data-act="ok"]').onclick = () => m.close();
  } else if (act === 'unresign') {
    if (!await confirmDialog(`${name}さんの退職の記録を消しますか？\n返金率・返金額の記録も消えます。`, { okLabel: '消す', danger: true })) return;
    await rpc('v2_reward_record_resignation', { p_app: r.application_id, p_resigned_on: null }, '退職の記録を消せませんでした');
    toast('退職の記録を消しました');
  } else if (act === 'refunded') {
    const d = await dateModal({ title: '返金済みにする', label: '返金日', value: today(), okLabel: '返金済みにする',
      about: aboutHtml(r, `<dt>返金額（税込）</dt><dd class="mono">${fmtYen(totalOf(r.refund_amount))}</dd>`) });
    if (!d) return;
    await rpc('v2_reward_mark_refunded', { p_app: r.application_id, p_refunded_on: d }, '返金済みにできませんでした');
    toast('返金済みにしました');
  }
  reload();
}

async function render(el, params) {
  const rows = await loadRewards();
  // 既定のタブ: RAは対応が要る「支払待ち」、1次パートナーは全体が見える「すべて」
  const tab = TABS.find((t) => t.key === params.tab) || TABS.find((t) => t.key === (isRA() ? 'pending' : 'all'));
  const list = rows.filter(tab.match);
  const ra = isRA();
  const month = today().slice(0, 7);
  const sum = (xs, f) => xs.reduce((s, x) => s + (f(x) || 0), 0);
  const payWait = sum(rows.filter((r) => r.pay_status === 'pending'), (r) => totalOf(r.fee_amount));
  const refundWait = sum(rows.filter((r) => r.refund_status === 'pending'), (r) => totalOf(r.refund_amount));
  const paidMonth = sum(rows.filter((r) => r.pay_status === 'paid' && String(r.paid_on || '').startsWith(month)), (r) => totalOf(r.fee_amount));

  el.innerHTML = `
    ${ra ? '' : `<p class="callout">KANOAからあなたの会社への紹介料（成約報酬）の記録です。支払・退職・返金の記録はKANOAが行います（この画面は閲覧のみです）。</p>`}
    <div class="stat-grid">
      <div class="stat"><div class="label">支払待ち 合計（税込）</div><div class="num">${fmtYen(payWait)}</div></div>
      <div class="stat"><div class="label">返金待ち 合計（税込）</div><div class="num">${fmtYen(refundWait)}</div></div>
      <div class="stat"><div class="label">今月の支払済み（税込）</div><div class="num">${fmtYen(paidMonth)}</div></div>
    </div>
    <section class="card">
      <div class="tabs" role="tablist">${TABS.map((t) => `
        <a role="tab" class="tab ${t.key === tab.key ? 'active' : ''}" aria-selected="${t.key === tab.key}" href="#/rewards?tab=${t.key}">
          ${esc(t.label)} <span class="tab-count">${rows.filter(t.match).length}</span></a>`).join('')}</div>
      ${list.length ? `<div class="table-wrap"><table class="table reward-table">
        <thead><tr><th>求職者</th><th>求人企業・求人</th><th>支払先</th><th>入社日</th><th>紹介料（税込）<br><small>税抜／消費税</small></th>
          <th>支払状態</th><th>退職日</th><th>返金率</th><th>返金額（税込）</th>${ra ? '<th>操作</th>' : ''}</tr></thead>
        <tbody>${list.map((r) => `
          <tr data-app="${esc(r.application_id)}">
            <td><a href="#/selection?id=${esc(r.application_id)}"><b>${esc(r.candidate?.name || '（表示できません）')}</b></a></td>
            <td>${esc(r.job?.client?.name || '—')}<br><small class="sub">${esc(r.job?.title || '（求人を表示できません）')}</small></td>
            <td><span class="mono">${esc(r.company?.code || '')}</span><br><small class="sub">${esc(r.company?.name || '')}</small></td>
            <td>${fmtDate(r.joined_on)}</td>
            <td>${moneyCell(r.fee_amount)}</td>
            <td>${payCell(r)}</td>
            <td>${r.resigned_on ? fmtDate(r.resigned_on) : '—'}</td>
            <td class="mono">${r.refund_rate == null ? '—' : `${r.refund_rate}%`}</td>
            <td>${refundCell(r)}</td>
            ${ra ? `<td><div class="reward-acts">${actionsOf(r).map(([k, label, cls]) =>
              `<button class="btn btn-sm ${cls}" data-act="${k}">${esc(label)}</button>`).join('')}</div></td>` : ''}
          </tr>`).join('')}</tbody></table></div>`
      : `<div class="empty">${rows.length ? 'このタブに該当する報酬はありません。'
          : ra ? 'まだ報酬はありません。社内求人の選考で最後の段階が「通過」になると、入社として報酬がここに並びます。'
            : 'まだ報酬はありません。あなたの会社経由の求職者が入社すると、ここに並びます。'}</div>`}
      <p class="hint reward-note">金額は求人の紹介料（税抜）に消費税${TAX_PERCENT}%（1円未満切り捨て）を足して表示しています。紹介料と返金規定は、入社が確定した時点のもので固定されます。</p>
    </section>`;

  if (!ra) return;
  const reload = () => render(el, params).catch((e) => showError(e, '報酬の表示'));
  el.querySelectorAll('.reward-table [data-act]').forEach((b) => {
    b.onclick = () => {
      const r = rows.find((x) => x.application_id === b.closest('tr').dataset.app);
      busy(b, () => runAction(b.dataset.act, r, reload).catch((err) => showError(err, '報酬の記録')));
    };
  });
}

register('rewards', { title: '報酬', icon: 'yen', order: 60, visible, render });
