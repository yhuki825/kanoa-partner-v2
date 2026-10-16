// まだ作っていない画面の置き場所（メニューの形を先に確定させるため）
// 各段階で本物の画面ができたら、ここから外して features/<名前>/ に置き換える
import { register } from '../../router.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';

const ra = () => S.role === 'ra';
const PAGES = [
  { path: 'rewards', icon: 'yen', order: 60, title: '報酬', phase: 5, roles: ['ra'],
    what: () => '1次パートナーの請求の承認・支払、支払ステータス、早期退職・返金' },
];

for (const p of PAGES) {
  register(p.path, {
    title: p.title, icon: p.icon, order: p.order, roles: p.roles,
    render: (el) => {
      el.innerHTML = `<section class="card upcoming">
        <h2>この画面は準備中です（第${p.phase}段階で作ります）</h2>
        <p>${esc(p.what())}</p></section>`;
    },
  });
}
