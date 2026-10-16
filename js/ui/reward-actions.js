// 報酬の記録の操作（支払済み・退職・返金済みと、その取り消し）。報酬の画面（RA）とパートナー管理（フロントへの支払い）で共通
// ・書き込みはDBの関数だけ。誰が書けるかはDBが判定する（KANOAが払う行＝RA／会社が払う行＝その会社の代表者）
// ・関数には報酬の行ID（p_reward）と、読んだときの version（p_version）を渡す（1つの選考に段ごとの行があるため／古い画面で上書きしないため）
import { sb } from '../supabase.js';
import { esc, fmtDate, fmtYen } from './format.js';
import { openModal, confirmDialog, showError, toast, busy } from './components.js';
import { userError } from './db.js';
import { withTax, totalOf, refundPolicyLines } from './money.js';
import { isDeduct, noFee, payableOf, payOf, deductMoney, unpaidToast } from './reward-rows.js';

// 報酬の行を全部読む（見えない行はDBが返さない）。filter で絞る（例: q => q.eq('payee_company_id', id)）。1000件ずつ
export async function loadRewardRows(filter) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    const q = filter(sb().from('v2_rewards').select('*, company:v2_companies!v2_rewards_payee_company_id_fkey(code,name), candidate:v2_candidates!v2_rewards_candidate_id_fkey(name), job:v2_jobs!v2_rewards_job_id_fkey(title, client:v2_clients!v2_jobs_client_id_fkey(name))'));
    const { data, error } = await q.order('joined_on', { ascending: false }).order('id').range(from, from + 999);
    if (error) throw userError(error, '報酬を読み込めませんでした');
    rows.push(...data);
    if (data.length < 1000) return rows;
  }
}

const pad = (n) => String(n).padStart(2, '0');
export function today() { const d = new Date(); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }

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

// 関数の戻り値（更新後の報酬の行）。1行を配列で返すこともあるのでそろえる
async function rpc(fn, args, fallback) {
  const { data, error } = await sb().rpc(fn, args);
  if (error) throw userError(error, fallback);
  return Array.isArray(data) ? data[0] : data;
}

async function runAction(act, r, reload) {
  const name = r.candidate?.name || '';
  if (act === 'paid') {
    const d = await dateModal({ title: '支払済みにする', label: '支払日', value: today(), okLabel: '支払済みにする', about: aboutHtml(r) });
    if (!d) return;
    // 表示していた支払額を送る（その間に差し引きが変わっていたら、DBが止める）
    await rpc('v2_reward_mark_paid', { p_reward: r.id, p_version: r.version, p_paid_on: d, p_expected_payable: payableOf(r) }, '支払済みにできませんでした');
    toast('支払済みにしました');
  } else if (act === 'unpaid') {
    const extraMsg = r.refund_mode === 'refund' ? '\n退職は「支払前の退職」として扱われ、支払額からの差し引きに変わります（差し引き額は0円）。あとで本来の支払日で「支払済みにする」と、元の形に戻ります。' : '';
    if (!await confirmDialog(`${name}さんの報酬の「支払済み」を取り消して、支払待ちに戻しますか？\n支払日・支払額の記録も消えます（操作の記録には残ります）。${extraMsg}`, { okLabel: '取り消す', danger: true })) return;
    const saved = await rpc('v2_reward_unmark_paid', { p_reward: r.id, p_version: r.version }, '支払済みを取り消せませんでした');
    toast(unpaidToast(saved));
  } else if (act === 'resign') {
    const lines = refundPolicyLines(r.refund_policy);
    const policy = `<dt>返金規定</dt><dd>${lines.length ? lines.map(esc).join('<br>') : '返金規定なし（返金は発生しません）'}
      <br><small class="sub">入社が確定した時点の規定です。${r.pay_status === 'paid'
        ? '支払済みのため、返金を受ける扱いになります。' : 'まだ支払っていないため、支払額から差し引く扱いになります。'}</small></dd>`;
    const d = await dateModal({ title: r.resigned_on ? '退職日を直す' : '退職を記録', label: '退職日', value: r.resigned_on || today(),
      okLabel: '記録する', about: aboutHtml(r, policy) });
    if (!d) return;
    // 更新後の報酬の行（返金率・返金額はDBが計算）
    const saved = await rpc('v2_reward_record_resignation', { p_reward: r.id, p_version: r.version, p_resigned_on: d }, '退職を記録できませんでした');
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
    await rpc('v2_reward_record_resignation', { p_reward: r.id, p_version: r.version, p_resigned_on: null }, '退職の記録を消せませんでした');
    toast('退職の記録を消しました');
  } else if (act === 'refunded') {
    const d = await dateModal({ title: '返金済みにする', label: '返金日', value: today(), okLabel: '返金済みにする',
      about: aboutHtml(r, `<dt>返金額（税込）</dt><dd class="mono">${fmtYen(totalOf(r.refund_amount))}</dd>`) });
    if (!d) return;
    await rpc('v2_reward_mark_refunded', { p_reward: r.id, p_version: r.version, p_refunded_on: d }, '返金済みにできませんでした');
    toast('返金済みにしました');
  }
  reload();
}

// 表の操作ボタンをつなぐ（rewardTableHtml で描いた表）
export function bindRewardActions(root, rows, reload) {
  root.querySelectorAll('.reward-table [data-act]').forEach((b) => {
    b.onclick = () => {
      const r = rows.find((x) => x.id === b.closest('tr').dataset.reward);
      busy(b, () => runAction(b.dataset.act, r, reload).catch((err) => {
        showError(err, '報酬の記録');
        // 状態が合わない・他の人が先に更新した（P0409）／行が取り消されて権限の判定になった（P0403）:
        // 表を読み直して、古い行とボタンを今の状態にする
        if (['P0409', 'P0403'].includes(err?.detail?.code)) reload();
      }));
    };
  });
}
