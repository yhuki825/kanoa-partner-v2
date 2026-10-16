// 報酬（設計書14）: 入社時の成約報酬。支払先は1次パートナー
// ・RA: 全件。支払済み・退職・返金済みを記録する（DBの関数でだけ書ける）
// ・1次パートナー（CA）: 自社が支払先の分を閲覧のみ（2次以降はメニューにも出さない。DBも1行も返さない）
// ・金額は税抜で保存。消費税・税込の計算は ui/money.js の1か所だけで行う
// ・支払前に退職したときは、返金ではなく支払額から差し引く（refund_mode='deduct'。0円なら「支払なし」）
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
  { key: 'refund', label: '返金あり', match: (r) => r.refund_mode === 'refund' && r.refund_status != null },
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

// 差し引き（支払前の退職）か
const isDeduct = (r) => r.refund_mode === 'deduct';
// 紹介料が0円（未設定）か
const noFee = (r) => !Number(r.fee_amount);
// 今の支払額（税抜）= 紹介料 − 差し引き額。差し引きが無ければ紹介料のまま（DBの v2_reward_payable と同じ式）
const payableOf = (r) => Number(r.fee_amount) - (isDeduct(r) ? Number(r.refund_amount || 0) : 0);
// 表示する支払額（税抜）: 支払済みなら実際に支払った額（paid_amount）、それ以外は今の支払額
const payOf = (r) => (r.pay_status === 'paid' && r.paid_amount != null ? Number(r.paid_amount) : payableOf(r));
// 差し引き額（税込）= 紹介料の税込 − 支払額の税込（税込の3つの数字が必ず合うように、差で出す）
function deductMoney(r) {
  const total = totalOf(r.fee_amount) - totalOf(payableOf(r));
  const net = Number(r.fee_amount) - payableOf(r);
  return { net, tax: total - net, total };
}

function moneyCell(amount) {
  const m = withTax(amount);
  if (m.net == null) return '—';
  return `<div class="money"><b class="mono">${fmtYen(m.total)}</b>
    <small class="sub">税抜 <span class="mono">${fmtYen(m.net)}</span>／消費税 <span class="mono">${fmtYen(m.tax)}</span></small></div>`;
}
// 紹介料の欄: 差し引きがあれば、その下に支払額（税抜／消費税／税込）を出す
function feeCell(r) {
  if (noFee(r)) return '<span class="sub">紹介料 未設定（0円）</span>';
  const pay = payOf(r);
  if (pay === Number(r.fee_amount)) return moneyCell(r.fee_amount);
  return `${moneyCell(r.fee_amount)}
    <div class="deduct"><small class="sub">${r.pay_status === 'paid' ? '支払額（支払済み）' : '支払額'}</small>${moneyCell(pay)}
      ${isDeduct(r) ? '<small class="sub">支払前の退職のため差し引き</small>' : ''}</div>`;
}
function payCell(r) {
  if (r.pay_status === 'paid') return `<span class="tag st-done">支払済み</span><br><small class="sub">${fmtDate(r.paid_on)}</small>`;
  if (r.pay_status === 'cancelled') return `<span class="tag">支払なし</span><br><small class="sub">${noFee(r) ? '紹介料 未設定（0円）' : '全額差し引き'}</small>`;
  return '<span class="tag st-wait">支払待ち</span>';
}
function refundCell(r) {
  if (r.refund_amount == null) return '—';
  if (isDeduct(r)) {
    if (noFee(r)) return '<span class="sub">紹介料 未設定（0円）</span>';
    return Number(r.refund_amount) === 0 ? '<span class="sub">差し引きなし</span>'
      : `<b class="mono">${fmtYen(deductMoney(r).total)}</b><br><span class="tag">支払から差し引き</span>`;
  }
  if (Number(r.refund_amount) === 0) return '<span class="sub">返金なし</span>';
  return `<b class="mono">${fmtYen(totalOf(r.refund_amount))}</b><br>${r.refund_status === 'refunded'
    ? `<span class="tag st-done">返金済み</span> <small class="sub">${fmtDate(r.refunded_on)}</small>`
    : '<span class="tag st-wait">返金待ち</span>'}`;
}
function actionsOf(r) {
  const a = [];
  if (r.pay_status === 'pending') a.push(['paid', '支払済みにする', 'btn-primary']);
  else if (r.pay_status === 'paid' && !r.refund_status) a.push(['unpaid', '支払済みを取り消す', '']);
  // 差し引き後の額で支払済みのものは、支払額が確定しているので退職の記録を変えない（先に支払済みを取り消す）
  const fixed = r.refund_status === 'refunded' || (isDeduct(r) && r.pay_status === 'paid');
  if (!fixed) a.push(['resign', r.resigned_on ? '退職日を直す' : '退職を記録', '']);
  if (r.resigned_on && !fixed) a.push(['unresign', '退職の記録を消す', '']);
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
    <dt>紹介料（税込）</dt><dd class="mono">${noFee(r) ? '紹介料 未設定（0円）' : fmtYen(totalOf(r.fee_amount))}</dd>
    ${payOf(r) !== Number(r.fee_amount) ? `<dt>支払額（税込）</dt><dd><b class="mono">${fmtYen(totalOf(payOf(r)))}</b>
      ${isDeduct(r) ? '<small class="sub">（支払前の退職のため差し引き）</small>' : ''}</dd>` : ''}${extra}</dl>`;
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
    // 表示していた支払額を送る（その間に差し引きが変わっていたら、DBが止める）
    await rpc('v2_reward_mark_paid', { p_app: r.application_id, p_paid_on: d, p_expected_payable: payableOf(r) }, '支払済みにできませんでした');
    toast('支払済みにしました');
  } else if (act === 'unpaid') {
    const extraMsg = r.refund_mode === 'refund' ? '\n退職は「支払前の退職」として扱われ、支払額からの差し引きに変わります。' : '';
    if (!await confirmDialog(`${name}さんの報酬の「支払済み」を取り消して、支払待ちに戻しますか？\n支払日・支払額の記録も消えます（操作の記録には残ります）。${extraMsg}`, { okLabel: '取り消す', danger: true })) return;
    await rpc('v2_reward_unmark_paid', { p_app: r.application_id }, '支払済みを取り消せませんでした');
    toast('支払待ちに戻しました');
  } else if (act === 'resign') {
    const lines = refundPolicyLines(r.refund_policy);
    const policy = `<dt>返金規定</dt><dd>${lines.length ? lines.map(esc).join('<br>') : '返金規定なし（返金は発生しません）'}
      <br><small class="sub">入社が確定した時点の規定です。${r.pay_status === 'paid'
        ? '支払済みのため、返金を受ける扱いになります。' : 'まだ支払っていないため、支払額から差し引く扱いになります。'}</small></dd>`;
    const d = await dateModal({ title: r.resigned_on ? '退職日を直す' : '退職を記録', label: '退職日', value: r.resigned_on || today(),
      okLabel: '記録する', about: aboutHtml(r, policy) });
    if (!d) return;
    const res = await rpc('v2_reward_record_resignation', { p_app: r.application_id, p_resigned_on: d }, '退職を記録できませんでした');
    const saved = Array.isArray(res) ? res[0] : res;   // 更新後の報酬の行（返金率・返金額はDBが計算）
    const deduct = isDeduct(saved);
    const amt = deduct ? deductMoney(saved) : withTax(saved.refund_amount);
    const pay = withTax(payableOf(saved));
    const m = openModal(`
      <h3>退職を記録しました</h3>
      <dl class="kv">
        <dt>退職日</dt><dd>${fmtDate(saved.resigned_on)}（入社日 ${fmtDate(saved.joined_on)}）</dd>
        <dt>返金率</dt><dd class="mono">${saved.refund_rate}%</dd>
        <dt>${deduct ? '差し引き額' : '返金額'}</dt><dd>${Number(saved.refund_amount) > 0
          ? `<b class="mono">${fmtYen(amt.total)}</b>（税込）<br><small class="sub">税抜 ${fmtYen(amt.net)}／消費税 ${fmtYen(amt.tax)}</small>`
          : `${deduct ? '差し引き' : '返金'}はありません（返金規定の期間外です）`}</dd>
        ${deduct ? `<dt>支払額</dt><dd>${saved.pay_status === 'cancelled'
          ? `<b>支払なし</b>（${noFee(saved) ? '紹介料 未設定（0円）のため' : '全額を差し引いたため'}、支払はありません）`
          : `<b class="mono">${fmtYen(pay.total)}</b>（税込）<br><small class="sub">税抜 ${fmtYen(pay.net)}／消費税 ${fmtYen(pay.tax)}・支払前の退職のため差し引き</small>`}</dd>` : ''}
      </dl>
      <div class="modal-actions"><button class="btn btn-primary" data-act="ok">閉じる</button></div>`);
    m.el.querySelector('[data-act="ok"]').onclick = () => m.close();
  } else if (act === 'unresign') {
    const effect = r.refund_mode === 'refund'
      ? (r.refund_status === 'pending' ? '返金待ちの返金は取り消されます（返金率・返金額の記録も消えます）。支払済みの記録はそのままです。'
        : '返金率・返金額の記録も消えます。支払済みの記録はそのままです。')
      : '差し引きの記録が消え、支払額は紹介料の全額に戻ります。';
    if (!await confirmDialog(`${name}さんの退職の記録を消しますか？\n${effect}`, { okLabel: '消す', danger: true })) return;
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
  // 支払の合計は「支払額」（差し引き後）で数える。返金待ちは返金の扱い（支払済みのあとの退職）だけ
  const payWait = sum(rows.filter((r) => r.pay_status === 'pending' && payableOf(r) > 0), (r) => totalOf(payableOf(r)));   // 0円の行は数えない
  const refundWait = sum(rows.filter((r) => r.refund_mode === 'refund' && r.refund_status === 'pending'), (r) => totalOf(r.refund_amount));
  const paidMonth = sum(rows.filter((r) => r.pay_status === 'paid' && String(r.paid_on || '').startsWith(month)), (r) => totalOf(payOf(r)));   // 実際に支払った額

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
        <thead><tr><th>求職者</th><th>求人企業・求人</th><th>支払先</th><th>入社日</th><th>紹介料・支払額（税込）<br><small>税抜／消費税</small></th>
          <th>支払状態</th><th>退職日</th><th>返金率</th><th>返金・差し引き（税込）</th>${ra ? '<th>操作</th>' : ''}</tr></thead>
        <tbody>${list.map((r) => `
          <tr data-app="${esc(r.application_id)}">
            <td><a href="#/selection?id=${esc(r.application_id)}"><b>${esc(r.candidate?.name || '（表示できません）')}</b></a></td>
            <td>${esc(r.job?.client?.name || '—')}<br><small class="sub">${esc(r.job?.title || '（求人を表示できません）')}</small></td>
            <td><span class="mono">${esc(r.company?.code || '')}</span><br><small class="sub">${esc(r.company?.name || '')}</small></td>
            <td>${fmtDate(r.joined_on)}</td>
            <td>${feeCell(r)}</td>
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
      <p class="hint reward-note">金額は求人の紹介料（税抜）に消費税${TAX_PERCENT}%（1円未満切り捨て）を足して表示しています。紹介料と返金規定は、入社が確定した時点のもので固定されます。支払前に退職した場合は、返金ではなく支払額から差し引きます（全額を差し引くと「支払なし」）。</p>
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
