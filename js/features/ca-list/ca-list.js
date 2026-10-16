// CA一覧（RA）: 全パートナーのツリー（A→B→C…）と各社のCA、1次パートナーの招待、会社・CAの停止/再開
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { esc, fmtDate } from '../../ui/format.js';
import { showError, toast, confirmDialog } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { tierLabel } from '../../config.js';
import { issueInviteModal, inviteRows, bindInviteRows, resetMemberPassword, setMemberStatus } from '../../ui/invites.js';

async function render(el, params) {
  const a = setTopbarActions('<button class="btn btn-primary" id="inv1">1次パートナーを招待</button>');
  const reload = () => render(el, params);
  a.querySelector('#inv1').onclick = () => issueInviteModal({ title: '1次パートナーを招待', hint: '招待した会社はAライン（KANOAの直下）として登録されます。', onDone: reload });

  const [{ data: comps, error: e1 }, { data: members, error: e2 }, { data: invs, error: e3 }] = await Promise.all([
    sb().from('v2_companies').select('*').order('code'),
    sb().from('v2_members').select('*').eq('role', 'ca').order('login_id'),
    sb().from('v2_invites').select('*').in('status', ['issued', 'expired']).order('created_at', { ascending: false }),
  ]);
  if (e1 || e2 || e3) throw userError(e1 || e2 || e3, 'CA一覧を読み込めませんでした');
  const q = (params.q || '').trim();
  const childrenOf = (pid) => comps.filter((c) => c.parent_id === pid);
  const memOf = (cid) => members.filter((m) => m.company_id === cid);
  const hit = (c) => !q || [c.code, c.name, ...memOf(c.id).map((m) => `${m.name} ${m.login_id}`)].some((v) => (v || '').includes(q));
  // 検索に当たった会社と、その祖先は表示する
  const show = new Set();
  comps.filter(hit).forEach((c) => { let x = c; while (x) { show.add(x.id); x = comps.find((p) => p.id === x.parent_id); } });

  const node = (c) => {
    if (!show.has(c.id)) return '';
    const ms = memOf(c.id);
    const kids = childrenOf(c.id);
    return `<li class="tree-node">
      <details ${q || c.tier === 1 ? 'open' : ''}>
        <summary>
          <span class="tag tier">${esc(tierLabel(c.tier))}</span>
          <b class="mono">${esc(c.code)}</b> ${esc(c.name)}
          <span class="sub">CA ${ms.filter((m) => m.status === 'active').length}人${kids.length ? `・フロント ${kids.length}社` : ''}</span>
          ${c.status === 'suspended' ? '<span class="tag st-closed">停止中</span>' : ''}
          <span class="grow"></span>
          <button class="btn btn-sm" data-company="${esc(c.id)}">${c.status === 'active' ? '会社を停止' : '会社を再開'}</button>
        </summary>
        <table class="table tree-members"><tbody>${ms.map((m) => `<tr>
          <td class="mono">${esc(m.login_id)}</td>
          <td>${esc(m.name)}${m.is_owner ? ' <span class="tag">代表者</span>' : ''}</td>
          <td>${esc(m.email || '—')}</td>
          <td>${m.status === 'active' ? (m.must_change_pw ? '<span class="tag st-relay">初回ログイン待ち</span>' : '利用中') : '<span class="tag st-closed">停止中</span>'}</td>
          <td class="row-actions"><button class="btn btn-sm" data-reset="${esc(m.id)}">パスワード再設定</button>
            <button class="btn btn-sm" data-status="${esc(m.id)}">${m.status === 'active' ? '停止' : '再開'}</button></td>
        </tr>`).join('') || '<tr><td class="sub">CAがいません</td></tr>'}</tbody></table>
        ${kids.length ? `<ul class="tree">${kids.map(node).join('')}</ul>` : ''}
      </details></li>`;
  };
  const roots = childrenOf(null);
  const kanoaInvs = invs.filter((v) => !v.issued_by);
  el.innerHTML = `
    <section class="card">
      <form class="searchbar" role="search"><label class="sr-only" for="cq">検索</label>
        <input id="cq" name="q" value="${esc(q)}" placeholder="企業コード・会社名・CAの名前・ログインIDで検索"><button class="btn">検索</button>
        ${q ? '<a class="btn" href="#/ca-list">条件を消す</a>' : ''}</form>
      <p class="count">パートナー ${comps.length}社（${[...new Set(comps.map((c) => c.tier))].sort().map((t) => `${tierLabel(t)} ${comps.filter((c) => c.tier === t).length}社`).join('・') || '—'}）・CA ${members.length}人</p>
      ${roots.length ? `<ul class="tree root">${roots.map(node).join('')}</ul>` : '<div class="empty">まだパートナーがいません。右上の「1次パートナーを招待」から始めます。</div>'}
    </section>
    ${invs.length ? `<section class="card"><h2>招待中（まだ登録していない会社）</h2>
      <div class="table-wrap"><table class="table"><thead><tr><th>企業コード</th><th>会社名</th><th>状態</th><th>期限</th><th>発行</th><th></th></tr></thead>
      <tbody>${inviteRows(invs, (v) => !v.issued_by, (v) => (v.issued_by ? comps.find((c) => c.id === v.issued_by)?.code || '' : 'KANOA'))}</tbody></table></div>
      <p class="hint">2次以降の招待は、発行した会社が再発行・取消できます。</p></section>` : ''}`;

  el.querySelector('form').onsubmit = (e) => { e.preventDefault(); const v = new FormData(e.target).get('q').trim(); location.hash = v ? `#/ca-list?q=${encodeURIComponent(v)}` : '#/ca-list'; };
  bindInviteRows(el, kanoaInvs, reload);
  el.querySelectorAll('[data-reset]').forEach((b) => { b.onclick = (e) => { e.preventDefault(); resetMemberPassword(members.find((m) => m.id === b.dataset.reset)); }; });
  el.querySelectorAll('[data-status]').forEach((b) => {
    const m = members.find((x) => x.id === b.dataset.status);
    b.onclick = (e) => { e.preventDefault(); setMemberStatus(m, m.status === 'active' ? 'suspended' : 'active', reload); };
  });
  el.querySelectorAll('[data-company]').forEach((b) => {
    b.onclick = async (e) => {
      e.preventDefault(); e.stopPropagation();
      const c = comps.find((x) => x.id === b.dataset.company);
      const to = c.status === 'active' ? 'suspended' : 'active';
      const verb = to === 'suspended' ? '停止' : '再開';
      if (!await confirmDialog(`${c.name}（${c.code}）を${verb}しますか？${to === 'suspended' ? '\n停止すると、この会社のCAは全員ログインできなくなります。下の階層の会社は止まりません。' : ''}`, { okLabel: `${verb}する`, danger: to === 'suspended' })) return;
      try { await updateRow('v2_companies', c, { status: to }); toast(`${verb}しました`); reload(); }
      catch (err) { showError(err, `会社の${verb}`); }
    };
  });
}

register('ca-list', { title: 'CA一覧', icon: 'network', order: 50, roles: ['ra'], render });
