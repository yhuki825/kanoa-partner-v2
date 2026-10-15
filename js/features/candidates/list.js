// 求職者: 検索（名前・ふりがな・メモ・推薦文・電話番号）と一覧。ページングとDB側の件数
import { register, navigate, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, ageOf } from '../../ui/format.js';
import { userError } from '../../ui/db.js';

const PAGE = 50;

async function render(el, params) {
  const q = params.q || '';
  const page = Math.max(0, Number(params.p || 0));
  const a = setTopbarActions('<a class="btn btn-primary" href="#/candidate-edit">求職者を登録</a>');

  const { data, error } = await sb().rpc('v2_candidate_list', { p_q: q, p_limit: PAGE, p_offset: page * PAGE });
  if (error) throw userError(error, '求職者を読み込めませんでした');
  const total = data[0]?.total || 0;

  el.innerHTML = `
    <section class="card">
      <form class="searchbar" role="search">
        <label class="sr-only" for="cq">求職者を検索</label>
        <input id="cq" name="q" value="${esc(q)}" placeholder="名前・ふりがな・メモ・推薦文・電話番号で検索">
        <button class="btn">検索</button>
        ${q ? '<a class="btn" href="#/candidates">条件を消す</a>' : ''}
      </form>
      <p class="count">${q ? `「${esc(q)}」の検索結果 ` : ''}${total.toLocaleString()}人</p>
      ${data.length ? `<div class="table-wrap"><table class="table">
        <thead><tr><th>名前</th><th>${S.role === 'ra' ? '担当' : '担当パートナー'}</th><th>年齢</th><th>都道府県</th><th>メモ</th><th>登録日</th></tr></thead>
        <tbody>${data.map((c) => `
          <tr class="row-link" data-id="${c.id}" tabindex="0">
            <td><a href="#/candidate?id=${c.id}"><b>${esc(c.name)}</b></a>${c.kana ? `<br><small class="sub">${esc(c.kana)}</small>` : ''}</td>
            <td>${esc(c.assigned_name || '—')}</td>
            <td>${ageOf(c.birth_date) ?? '—'}</td>
            <td>${esc(c.prefecture || '—')}</td>
            <td class="memo-cell">${esc((c.memo || '').slice(0, 60)) || '—'}</td>
            <td>${fmtDate(c.created_at)}</td>
          </tr>`).join('')}</tbody></table></div>`
      : `<div class="empty">${q ? '該当する求職者はいません。' : 'まだ求職者がいません。右上の「求職者を登録」から登録できます。'}</div>`}
      ${total > PAGE ? `<nav class="pager">
        ${page > 0 ? `<a class="btn" href="#/candidates?q=${encodeURIComponent(q)}&p=${page - 1}">前へ</a>` : ''}
        <span>${page * PAGE + 1}〜${Math.min(total, (page + 1) * PAGE)}人目</span>
        ${(page + 1) * PAGE < total ? `<a class="btn" href="#/candidates?q=${encodeURIComponent(q)}&p=${page + 1}">次へ</a>` : ''}
      </nav>` : ''}
    </section>`;

  el.querySelector('form').onsubmit = (e) => {
    e.preventDefault();
    const v = new FormData(e.target).get('q').trim();
    navigate(v ? `candidates?q=${encodeURIComponent(v)}` : 'candidates');
  };
  el.querySelectorAll('.row-link').forEach((tr) => {
    const go = () => navigate(`candidate?id=${tr.dataset.id}`);
    tr.onclick = (e) => { if (!e.target.closest('a')) go(); };
    tr.onkeydown = (e) => { if (e.key === 'Enter') go(); };
  });
}

register('candidates', { title: '求職者', icon: 'user', order: 10, render });
