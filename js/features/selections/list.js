// 選考: 「自社で紹介した選考」と「紹介された選考」の2タブ。判断待ちは一番上
import { register, navigate, setBadge } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { userError } from '../../ui/db.js';
import { showError } from '../../ui/components.js';
import { stageTag, milestoneChips } from '../../ui/selection.js';

const PAGE = 50;
// 絞り込み（2026-10-19 ユーザー指定）。判定はDB（v2_selection_category）
const FILTERS = [
  { key: 'all', label: '全て' }, { key: 'before', label: '選考応募前' }, { key: 'active', label: '選考中' },
  { key: 'offer', label: '内定獲得' }, { key: 'lost', label: '落選/辞退' },
];
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
  const tabs = TABS();
  // タブの指定があれば、判断待ちの件数は一覧と並べて取る（無いときだけ、件数で初期タブを決めるため先に取る）
  const tabGiven = tabs.some((t) => t.key === params.tab);
  const waitingP = refreshWaitingBadge();
  const waiting0 = tabGiven ? null : await waitingP;
  const tab = tabGiven ? params.tab : (waiting0 ? 'received' : tabs[0].key);
  const q = params.q || '';
  let page = Math.max(0, Number(params.p || 0));
  let f = FILTERS.some((x) => x.key === params.f) ? params.f : 'all';
  const [listRes, { data: unread }, { data: fc, error: fe }, waiting, ...counts] = await Promise.all([
    sb().rpc('v2_selection_list', { p_tab: tab, p_q: q, p_limit: PAGE, p_offset: page * PAGE, p_filter: f }),
    sb().rpc('v2_chat_unread'),
    sb().rpc('v2_selection_counts', { p_tab: tab, p_q: q }),
    waitingP,
    ...tabs.map((t) => sb().rpc('v2_selection_list', { p_tab: t.key, p_q: '', p_limit: 1, p_offset: 0 })),
  ]);
  if (listRes.error) throw userError(listRes.error, '選考を読み込めませんでした');
  // 件数が取れなくても一覧は出す（件数は「–」）
  if (fe) console.warn('v2_selection_counts', fe);
  const nOf = Object.fromEntries((fc || []).map((r) => [r.category, Number(r.n)]));
  nOf.all = Object.values(nOf).reduce((s, n) => s + n, 0);
  const chipCount = (k) => (fe ? '–' : nOf[k] || 0);
  // 絞り込み・検索・ページを保ったリンク
  const qs = (o = {}) => { const v = { q, f, p: page, ...o }; return `${v.q ? `&q=${encodeURIComponent(v.q)}` : ''}${v.f && v.f !== 'all' ? `&f=${v.f}` : ''}${v.p ? `&p=${v.p}` : ''}`; };
  const unreadOf = Object.fromEntries((unread || []).map((u) => [u.application_id, Number(u.unread)]));
  const link = (t, extra = '') => `#/selections?tab=${t}${extra}`;

  // 一覧の部分（表・空の表示・ページ送り）。絞り込み・ページ送りではここだけ描き直す
  const resultsHtml = (data) => {
    const total = data[0]?.total || 0;
    return `${data.length ? `<div class="table-wrap"><table class="table sel-table">
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
      : `<div class="empty">${q || f !== 'all' ? '該当する選考はありません。' : tab === 'mine'
          ? '紹介した選考はまだありません。求人詳細の「応募する」、または求職者詳細の「プラットフォームに応募」から始まります。'
          : 'フロントから紹介された選考はまだありません。'}</div>`}
      ${total > PAGE ? `<nav class="pager">
        ${page > 0 ? `<a class="btn" data-page="${page - 1}" href="${link(tab, qs({ p: page - 1 }))}">前へ</a>` : ''}
        <span>${page * PAGE + 1}〜${Math.min(total, (page + 1) * PAGE)}件目／${total}件</span>
        ${(page + 1) * PAGE < total ? `<a class="btn" data-page="${page + 1}" href="${link(tab, qs({ p: page + 1 }))}">次へ</a>` : ''}
      </nav>` : ''}`;
  };

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
        ${q ? `<a class="btn" href="${link(tab, qs({ q: '', p: 0 }))}">条件を消す</a>` : ''}
      </form>
      <div class="filter-chips" role="group" aria-label="選考の状態で絞り込む">${FILTERS.map((x) => `
        <a class="chip ${x.key === f ? 'active' : ''}" data-f="${x.key}" aria-pressed="${x.key === f}" href="${link(tab, qs({ f: x.key, p: 0 }))}">${esc(x.label)} <span class="tab-count">${chipCount(x.key)}</span></a>`).join('')}</div>
      ${tab === 'received' && waiting ? `<p class="callout">判断待ちが <b>${waiting}件</b> あります。上から順に確認してください。</p>` : ''}
      <div class="sel-results">${resultsHtml(listRes.data)}</div>
    </section>`;

  const box = el.querySelector('.sel-results');
  const bindRows = () => {
    box.querySelectorAll('.row-link').forEach((tr) => {
      const go = () => navigate(`selection?id=${tr.dataset.id}`);
      tr.onclick = (e) => { if (!e.target.closest('a')) go(); };
      tr.onkeydown = (e) => { if (e.key === 'Enter') go(); };
    });
    box.querySelectorAll('[data-page]').forEach((a) => { a.onclick = (e) => { e.preventDefault(); show(f, Number(a.dataset.page)); }; });
  };
  // 絞り込み・ページ送り: 画面全体は作り直さず、一覧の部分だけ取り直す（前の表は薄くして残す）
  let seq = 0;
  async function show(nf, np) {
    const my = ++seq;
    box.classList.add('is-loading');
    const { data, error } = await sb().rpc('v2_selection_list', { p_tab: tab, p_q: q, p_limit: PAGE, p_offset: np * PAGE, p_filter: nf });
    if (my !== seq || !box.isConnected) return;   // 後から押した方を優先・画面を離れていたら捨てる
    box.classList.remove('is-loading');
    if (error) { showError(userError(error, '選考を読み込めませんでした'), '選考'); return; }
    f = nf; page = np;
    el.querySelectorAll('.filter-chips .chip').forEach((c) => { const on = c.dataset.f === f; c.classList.toggle('active', on); c.setAttribute('aria-pressed', on); c.href = link(tab, qs({ f: c.dataset.f, p: 0 })); });
    box.innerHTML = resultsHtml(data);
    bindRows();
    history.replaceState(null, '', link(tab, qs()));   // URL も合わせる（再読み込み・共有で同じ表示になる。描き直しは起こさない）
  }
  el.querySelectorAll('.filter-chips .chip').forEach((c) => { c.onclick = (e) => { e.preventDefault(); if (c.dataset.f !== f) show(c.dataset.f, 0); }; });
  bindRows();

  el.querySelector('form').onsubmit = (e) => {
    e.preventDefault();
    const v = new FormData(e.target).get('q').trim();
    navigate(`selections?tab=${tab}${qs({ q: v, p: 0 })}`);
  };
}

register('selections', { title: '選考', icon: 'flow', order: 30, render });
