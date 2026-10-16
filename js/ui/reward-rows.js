// 報酬の行の表示（報酬の画面とパートナー管理の「フロントへの支払い」で共通。設計書14・14.1）
// ・ここは計算と表示だけ（DBにも画面部品にも触れない）。操作は ui/reward-actions.js
// ・金額は税抜で保存。消費税・税込の計算は ui/money.js の1か所だけで行う
// ・支払前に退職したときは、返金ではなく支払額から差し引く（refund_mode='deduct'。0円なら「支払なし」）
import { esc, fmtDate, fmtYen } from './format.js';
import { withTax, totalOf } from './money.js';

export const REWARD_TABS = [
  { key: 'pending', label: '支払待ち', match: (r) => r.pay_status === 'pending' },
  { key: 'paid', label: '支払済み', match: (r) => r.pay_status === 'paid' },
  { key: 'refund', label: '返金あり', match: (r) => r.refund_mode === 'refund' && r.refund_status != null },
  { key: 'all', label: 'すべて', match: () => true },
];

// 差し引き（支払前の退職）か
export const isDeduct = (r) => r.refund_mode === 'deduct';
// 紹介料が0円（未設定）か
export const noFee = (r) => !Number(r.fee_amount);
// 今の支払額（税抜）= 紹介料 − 差し引き額。差し引きが無ければ紹介料のまま（DBの v2_reward_payable と同じ式）
export const payableOf = (r) => Number(r.fee_amount) - (isDeduct(r) ? Number(r.refund_amount || 0) : 0);
// 表示する支払額（税抜）: 支払済みなら実際に支払った額（paid_amount）、それ以外は今の支払額
export const payOf = (r) => (r.pay_status === 'paid' && r.paid_amount != null ? Number(r.paid_amount) : payableOf(r));
// 差し引き額（税込）= 紹介料の税込 − 支払額の税込（税込の3つの数字が必ず合うように、差で出す）
export function deductMoney(r) {
  const total = totalOf(r.fee_amount) - totalOf(payableOf(r));
  const net = Number(r.fee_amount) - payableOf(r);
  return { net, tax: total - net, total };
}

// 合計（税込）: 支払待ち（0円の行は数えない）／返金待ち（返金の扱いだけ）／今月の支払済み（実際に支払った額）
export function rewardSums(rows, month) {
  const sum = (xs, f) => xs.reduce((s, x) => s + (f(x) || 0), 0);
  return {
    payWait: sum(rows.filter((r) => r.pay_status === 'pending' && payableOf(r) > 0), (r) => totalOf(payableOf(r))),
    refundWait: sum(rows.filter((r) => r.refund_mode === 'refund' && r.refund_status === 'pending'), (r) => totalOf(r.refund_amount)),
    paidMonth: sum(rows.filter((r) => r.pay_status === 'paid' && String(r.paid_on || '').startsWith(month)), (r) => totalOf(payOf(r))),
  };
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
  if (payableOf(r) <= 0) return '<span class="tag">支払なし</span><br><small class="sub">紹介料 未設定（0円）</small>';
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

// 行に出す操作ボタン [種類, 文言, クラス]
export function actionsOf(r) {
  const a = [];
  // 支払額が0円（紹介料 未設定）の行は支払済みにしない（DBも P0400 で拒否する）
  if (r.pay_status === 'pending' && payableOf(r) > 0) a.push(['paid', '支払済みにする', 'btn-primary']);
  else if (r.pay_status === 'paid' && !r.refund_status) a.push(['unpaid', '支払済みを取り消す', '']);
  // 差し引き後の額で支払済みのものは、支払額が確定しているので退職の記録を変えない（先に支払済みを取り消す）
  const fixed = r.refund_status === 'refunded' || (isDeduct(r) && r.pay_status === 'paid');
  if (!fixed) a.push(['resign', r.resigned_on ? '退職日を直す' : '退職を記録', '']);
  if (r.resigned_on && !fixed) a.push(['unresign', '退職の記録を消す', '']);
  if (r.refund_status === 'pending' && r.pay_status === 'paid') a.push(['refunded', '返金済みにする', 'btn-primary']);
  return a;
}

// 「支払済みを取り消す」の後の知らせ: DBが返した支払の状態に合わせる（0円なら「支払なし」になるため）
export function unpaidToast(saved) {
  return saved?.pay_status === 'cancelled' ? '支払済みを取り消しました（支払はありません）' : '支払待ちに戻しました';
}

// 報酬の表。party: 3列目に出す相手 { label: 見出し, cell: (r) => HTML }。canAct: 操作の列を出すか
export function rewardTableHtml(list, { party, canAct }) {
  return `<div class="table-wrap"><table class="table reward-table">
    <thead><tr><th>求職者</th><th>求人企業・求人</th><th>${esc(party.label)}</th><th>入社日</th><th>紹介料・支払額（税込）<br><small>税抜／消費税</small></th>
      <th>支払状態</th><th>退職日</th><th>返金率</th><th>返金・差し引き（税込）</th>${canAct ? '<th>操作</th>' : ''}</tr></thead>
    <tbody>${list.map((r) => `
      <tr data-reward="${esc(r.id)}">
        <td><a href="#/selection?id=${esc(r.application_id)}"><b>${esc(r.candidate?.name || '（表示できません）')}</b></a></td>
        <td>${esc(r.job?.client?.name || '—')}<br><small class="sub">${esc(r.job?.title || '（求人を表示できません）')}</small></td>
        <td>${party.cell(r)}</td>
        <td>${fmtDate(r.joined_on)}</td>
        <td>${feeCell(r)}</td>
        <td>${payCell(r)}</td>
        <td>${r.resigned_on ? fmtDate(r.resigned_on) : '—'}</td>
        <td class="mono">${r.refund_rate == null ? '—' : `${r.refund_rate}%`}</td>
        <td>${refundCell(r)}</td>
        ${canAct ? `<td><div class="reward-acts">${actionsOf(r).map(([k, label, cls]) =>
          `<button class="btn btn-sm ${cls}" data-act="${k}">${esc(label)}</button>`).join('')}</div></td>` : ''}
      </tr>`).join('')}</tbody></table></div>`;
}

// 支払先（受け取る会社）の欄
export const payeeCell = (r) => `<span class="mono">${esc(r.company?.code || '')}</span><br><small class="sub">${esc(r.company?.name || '')}</small>`;
