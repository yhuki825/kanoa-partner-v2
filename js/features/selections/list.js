// 選考: 「自社で紹介した選考」と「紹介された選考」の2タブ。判断待ちは一番上
import { register, navigate, setBadge } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { userError } from '../../ui/db.js';
import { stageTag, milestoneChips } from '../../ui/selection.js';

const PAGE = 50;
const TABS = () => S.role === 'ra'
  ? [{ key: 'received', label: '紹介された選考' }, { key: 'mine', label: 'KANOAの求職者の選考' }]
  : [{ key: 'mine', label: '自社で紹介した選考' }, { key: 'received', label: '紹介された選考' }];

// メニューのバッジ = 判断待ちの選考 + 未読の連絡がある選考（どちらも対応が必要なもの）
export async function refreshWaitingBadge() {
  const [{ data: w }, { data: u }] = await Promise.all([sb().rpc('v2_waiting_count'), sb().rpc('v2_chat_unread')]);
  setBadge('selections', Number(w || 0) + (u || []).length);
  return Number(w || 0);
}

async function render(el, params) {
  const waiting = await refreshWaitingBadge();
  const tabs = TABS();
  const tab = tabs.some((t) => t.key === params.tab) ? params.tab : (waiting ? 'received' : tabs[0].key);
  const q = params.q || '';
  const page = Math.max(0, Number(params.p || 0));
  const [{ data, error }, { data: unread }, ...counts] = await Promise.all([
    sb().rpc('v2_selection_list', { p_tab: tab, p_q: q, p_limit: PAGE, p_offset: page * PAGE }),
    sb().rpc('v2_chat_unread'),
    ...tabs.map((t) => sb().rpc('v2_selection_list', { p_tab: t.key, p_q: '', p_limit: 1, p_offset: 0 })),
  ]);
  if (error) throw userError(error, '選考を読み込めませんでした');
  const total = data[0]?.total || 0;
  const unreadOf = Object.fromEntries((unread || []).map((u) => [u.application_id, Number(u.unread)]));
  const link = (t, extra = '') => `#/selections?tab=${t}${extra}`;

  el.innerHTML = `
    <section class="card">
      <div class="tabs" role="tablist">${tabs.map((t, i) => `
        <a role="tab" class="tab ${t.key === tab ? 'active' : ''}" aria-selected="${t.key === tab}" href="${link(t.key)}">
          ${esc(t.label)} <span class="tab-count">${counts[i].data?.[0]?.total || 0}</span>
          ${t.key === 'received' && waiting ? `<span class="badge">${waiting}</span>` : ''}</a>`).join('')}</div>
      <form class="searchbar" role="search">
        <label class="sr-only" for="sq">選考を検索</label>
        <input id="sq" name="q" value="${esc(q)}" placeholder="求職者名・求人企業名・求人名で検索">
        <button class="btn">検索</button>
        ${q ? `<a class="btn" href="${link(tab)}">条件を消す</a>` : ''}
      </form>
      ${tab === 'received' && waiting ? `<p class="callout">判断待ちが <b>${waiting}件</b> あります。上から順に確認してください。</p>` : ''}
      ${data.length ? `<div class="table-wrap"><table class="table sel-table">
        <thead><tr><th class="col-name">求職者</th><th class="col-job">求人企業・求人</th><th>選考の進み具合</th>${tab === 'received' ? '<th>紹介元</th>' : ''}<th>状態</th><th>更新</th></tr></thead>
        <tbody>${data.map((a) => `
          <tr class="row-link ${a.waiting_me ? 'is-waiting' : ''}" data-id="${a.id}" tabindex="0">
            <td class="col-name"><a href="#/selection?id=${a.id}"><b>${esc(a.candidate_name)}</b></a>${unreadOf[a.id] ? ` <span class="badge" title="未読の連絡">${unreadOf[a.id]}</span>` : ''}</td>
            <td class="col-job">${esc(a.client_name || '—')}<br><small class="sub">${esc(a.job_title)}${a.kind === 'external' ? '（外部求人）' : ''}</small></td>
            <td>${a.stage === 'relay' ? '<span class="sub">選考開始前</span>' : milestoneChips(a.milestones)}</td>
            ${tab === 'received' ? `<td>${esc(a.source_label || '—')}</td>` : ''}
            <td>${stageTag(a)}</td>
            <td>${fmtDate(a.updated_at)}</td>
          </tr>`).join('')}</tbody></table></div>`
      : `<div class="empty">${q ? '該当する選考はありません。' : tab === 'mine'
          ? '紹介した選考はまだありません。求人詳細の「応募する」、または求職者詳細の「プラットフォームに応募」から始まります。'
          : 'フロントから紹介された選考はまだありません。'}</div>`}
      ${total > PAGE ? `<nav class="pager">
        ${page > 0 ? `<a class="btn" href="${link(tab, `&q=${encodeURIComponent(q)}&p=${page - 1}`)}">前へ</a>` : ''}
        <span>${page * PAGE + 1}〜${Math.min(total, (page + 1) * PAGE)}件目／${total}件</span>
        ${(page + 1) * PAGE < total ? `<a class="btn" href="${link(tab, `&q=${encodeURIComponent(q)}&p=${page + 1}`)}">次へ</a>` : ''}
      </nav>` : ''}
    </section>`;

  el.querySelector('form').onsubmit = (e) => {
    e.preventDefault();
    const v = new FormData(e.target).get('q').trim();
    navigate(`selections?tab=${tab}${v ? `&q=${encodeURIComponent(v)}` : ''}`);
  };
  el.querySelectorAll('.row-link').forEach((tr) => {
    const go = () => navigate(`selection?id=${tr.dataset.id}`);
    tr.onclick = (e) => { if (!e.target.closest('a')) go(); };
    tr.onkeydown = (e) => { if (e.key === 'Enter') go(); };
  });
}

register('selections', { title: '選考', icon: 'flow', order: 30, render });
