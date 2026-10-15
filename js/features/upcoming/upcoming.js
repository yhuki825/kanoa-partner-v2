// まだ作っていない画面の置き場所（メニューの形を先に確定させるため）
// 各段階で本物の画面ができたら、ここから外して features/<名前>/ に置き換える
import { register } from '../../router.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';

const ra = () => S.role === 'ra';
const PAGES = [
  { path: 'candidates', icon: 'user', order: 10, title: '求職者', phase: 2,
    what: () => ra() ? 'KANOAが持つ求職者と、届いた選考の求職者の一覧・検索・詳細' : '自社の求職者の一覧・検索・登録・詳細・書類' },
  { path: 'jobs', icon: 'search', order: 20, title: () => (ra() ? '求人' : '求人検索'), phase: 2,
    what: () => ra() ? '求人の登録・編集・公開、求人企業、KANOA→1次の紹介料' : '提示された求人の検索・詳細（別タブ）・紹介料・応募' },
  { path: 'selections', icon: 'flow', order: 30, title: '選考', phase: 3,
    what: () => '「自社で紹介した選考」「紹介された選考」、送客・見送り・受入、外部求人のURL登録、選考の進み具合' },
  { path: 'resources', icon: 'folder', order: 40, title: '各種資料', phase: 5,
    what: () => ra() ? '資料の登録・並べ替え・公開' : '履歴書の雛形・記入見本などの閲覧とダウンロード' },
  { path: 'partners', icon: 'network', order: 50, title: 'パートナー管理', phase: 5, roles: ['ca'],
    what: () => '自社のCAの追加、フロントの招待、フロント向けの紹介料の設定（代表者のみ）' },
  { path: 'ca-list', icon: 'network', order: 50, title: 'CA一覧', phase: 5, roles: ['ra'],
    what: () => '全パートナーのツリー（A→B→C…）と各社のCA、1次パートナーの招待' },
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
