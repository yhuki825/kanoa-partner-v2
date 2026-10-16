// まだ作っていない画面の置き場所（メニューの形を先に確定させるため）
// 各段階で本物の画面ができたら、ここから外して features/<名前>/ に置き換える
import { register } from '../../router.js';
import { esc } from '../../ui/format.js';

// 2026-10-16: 報酬は features/rewards/ に置き換えた。いま準備中の画面は無い
const PAGES = [];

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
