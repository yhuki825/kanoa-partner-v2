// 報酬（設計書14・14.1）: 入社時の成約報酬。各社は「直上の会社」から受け取る（1次＝KANOAから、2次＝1次から…）
// ・RA: KANOAが払う分（KANOA→1次）の全件。支払済み・退職・返金済みを記録する（DBの関数でだけ書ける）
// ・CA: 自社が受け取る分だけを閲覧のみ（1次も2次以降も同じ画面）。フロントへ払う分はパートナー管理に出す
// ・表示と計算は ui/reward-rows.js、操作は ui/reward-actions.js（パートナー管理と共通）
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen } from '../../ui/format.js';
import { showError } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { TAX_PERCENT } from '../../ui/money.js';
import { REWARD_TABS, rewardSums, rewardTableHtml, payeeCell } from '../../ui/reward-rows.js';
import { bindRewardActions, loadRewardRows, today } from '../../ui/reward-actions.js';

const isRA = () => S.role === 'ra';
const visible = () => isRA() || S.role === 'ca';

// 報酬の行を読む。RA＝KANOAが払う行／CA＝自社が受け取る行（それ以外の行はDBも返さない）
const loadRewards = () => loadRewardRows((q) => (isRA() ? q.is('payer_company_id', null) : q.eq('payee_company_id', S.company.id)));

// 支払元（直上の会社）。1次はKANOA。2次以降は直上の1社のコードと社名（DBの関数で自社の直上だけ読める）
async function loadPayer() {
  if (isRA() || S.company.tier === 1) return { label: 'KANOA', isKanoa: true };
  const { data, error } = await sb().rpc('v2_my_upline');
  if (error) throw userError(error, '直上の会社を読み込めませんでした');
  const up = Array.isArray(data) ? data[0] : data;
  return { label: up ? `${up.code} ${up.name}` : '直上の会社', code: up?.code || '', name: up?.name || '', isKanoa: false };
}

async function render(el, params) {
  const [rows, payer] = await Promise.all([loadRewards(), loadPayer()]);
  // 既定のタブ: RAは対応が要る「支払待ち」、CAは全体が見える「すべて」
  const tab = REWARD_TABS.find((t) => t.key === params.tab) || REWARD_TABS.find((t) => t.key === (isRA() ? 'pending' : 'all'));
  const list = rows.filter(tab.match);
  const ra = isRA();
  const { payWait, refundWait, paidMonth } = rewardSums(rows, today().slice(0, 7));
  // CAの3列目は「支払元」（受け取る相手は自社なので出さない）
  const party = ra ? { label: '支払先', cell: payeeCell }
    : { label: '支払元', cell: () => (payer.isKanoa ? 'KANOA' : `<span class="mono">${esc(payer.code)}</span><br><small class="sub">${esc(payer.name)}</small>`) };
  const about = payer.isKanoa
    ? 'KANOAからあなたの会社への紹介料（成約報酬）の記録です。支払・退職・返金の記録はKANOAが行います（この画面は閲覧のみです）。'
    : `直上の会社（${payer.label}）からあなたの会社への紹介料（成約報酬）の記録です。支払・退職・返金の記録は直上の会社が行います（この画面は閲覧のみです）。`;

  el.innerHTML = `
    ${ra ? '' : `<p class="callout">${esc(about)}</p>`}
    <div class="stat-grid">
      <div class="stat"><div class="label">支払待ち 合計（税込）</div><div class="num">${fmtYen(payWait)}</div></div>
      <div class="stat"><div class="label">返金待ち 合計（税込）</div><div class="num">${fmtYen(refundWait)}</div></div>
      <div class="stat"><div class="label">今月の支払済み（税込）</div><div class="num">${fmtYen(paidMonth)}</div></div>
    </div>
    <section class="card">
      <div class="tabs" role="tablist">${REWARD_TABS.map((t) => `
        <a role="tab" class="tab ${t.key === tab.key ? 'active' : ''}" aria-selected="${t.key === tab.key}" href="#/rewards?tab=${t.key}">
          ${esc(t.label)} <span class="tab-count">${rows.filter(t.match).length}</span></a>`).join('')}</div>
      ${list.length ? rewardTableHtml(list, { party, canAct: ra })
      : `<div class="empty">${rows.length ? 'このタブに該当する報酬はありません。'
          : ra ? 'まだ報酬はありません。社内求人の選考で最後の段階が「通過」になると、入社として報酬がここに並びます。'
            : 'まだ報酬はありません。あなたの会社経由の求職者が入社すると、ここに並びます。'}</div>`}
      <p class="hint reward-note">金額は紹介料（税抜）に消費税${TAX_PERCENT}%（1円未満切り捨て）を足して表示しています。紹介料と返金規定は、入社が確定した時点のもので固定されます。${payer.isKanoa ? ''
        : '紹介料は直上の会社がフロント向けに設定した額、返金規定はKANOAが求人ごとに決めた規定です。'}支払前に退職した場合は、返金ではなく支払額から差し引きます（全額を差し引くと「支払なし」）。</p>
    </section>`;

  if (!ra) return;
  bindRewardActions(el, rows, () => render(el, params).catch((e) => showError(e, '報酬の表示')));
}

register('rewards', { title: '報酬', icon: 'yen', order: 60, visible, render });
