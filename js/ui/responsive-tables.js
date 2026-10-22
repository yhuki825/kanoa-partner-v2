// スマホ幅では一覧の表をカード型で見せる（見た目は css/base.css のスマホ向けの指定）
// そのために、各セルへ見出しの文言を data-label として付ける。画面がどこで表を描いても拾えるよう、画面全体の変化を見張る
export function labelTables(root = document.body) {
  root.querySelectorAll('table.table').forEach((t) => {
    const heads = [...t.querySelectorAll('thead th')].map((th) => th.textContent.replace(/\s+/g, ' ').trim());
    t.querySelectorAll('tbody tr').forEach((tr) => {
      [...tr.children].forEach((td, i) => {
        if (td.hasAttribute('data-label')) return;
        td.setAttribute('data-label', td.colSpan > 1 ? '' : (heads[i] || ''));
      });
    });
  });
}

export function watchTables() {
  let queued = false;
  const run = () => { queued = false; labelTables(); };
  new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(run); } })
    .observe(document.body, { childList: true, subtree: true });
  labelTables();
}
