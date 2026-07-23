// ホーム: 「今日やること」が3秒で分かる画面
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';

async function countQ(q) {
  const { count, error } = await q;
  return error ? '—' : (count ?? 0);
}

async function render(el) {
  const c = sb();
  let stats = [];

  if (S.role === 'partner') {
    const me = S.company.id;
    const [waiting, mine, fronts] = await Promise.all([
      countQ(c.from('candidates').select('id', { count: 'exact', head: true }).eq('holder_id', me).eq('stage', 'relay')),
      countQ(c.from('candidates').select('id', { count: 'exact', head: true }).eq('registered_by', me)),
      countQ(c.from('companies').select('id', { count: 'exact', head: true }).eq('parent_id', me)),
    ]);
    stats = [
      { num: waiting, label: '紹介された求職者（判断待ち）', accent: waiting > 0 },
      { num: mine, label: '自社の求職者' },
      { num: fronts, label: 'フロント企業' },
    ];
  } else {
    const [arrived, screening, companies] = await Promise.all([
      countQ(c.from('candidates').select('id', { count: 'exact', head: true }).is('holder_id', null).eq('stage', 'relay')),
      countQ(c.from('candidates').select('id', { count: 'exact', head: true }).eq('stage', 'screening')),
      countQ(c.from('companies').select('id', { count: 'exact', head: true }).eq('status', 'active')),
    ]);
    stats = [
      { num: arrived, label: '紹介された求職者（受入待ち）', accent: arrived > 0 },
      { num: screening, label: '選考中' },
      { num: companies, label: '稼働パートナー' },
    ];
  }

  el.innerHTML = `
    <div class="stat-grid">
      ${stats.map((s) => `
        <div class="stat">
          <div class="num" ${s.accent ? 'style="color:var(--c-danger)"' : ''}>${esc(String(s.num))}</div>
          <div class="label">${esc(s.label)}</div>
        </div>`).join('')}
    </div>
    <div class="card">
      <h2>ようこそ</h2>
      <p style="color:var(--c-text-sub)">左のメニューから操作を選んでください。判断待ちの求職者がいる場合は「紹介された求職者」から確認できます。</p>
    </div>`;
}

register('home', { title: 'ホーム', nav: true, icon: '🏠', render });
