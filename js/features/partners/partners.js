// パートナー管理（CA）: 自社のCA／フロント企業と招待／フロントへの求人の提示／フロントへの支払い（設計書14.1）
// 変更できるのは会社の代表者だけ（それ以外のCAは見るだけ。フロントへの支払いの記録はDBも代表者だけに許す）
import { register } from '../../router.js';
import { sb, callFn } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, fmtYen } from '../../ui/format.js';
import { openModal, showError, toast, busy } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { tierLabel } from '../../config.js';
import { parseYen } from '../../ui/money.js';
import { rewardSums, rewardTableHtml, payeeCell } from '../../ui/reward-rows.js';
import { bindRewardActions, loadRewardRows, today } from '../../ui/reward-actions.js';
import { issueInviteModal, inviteRows, bindInviteRows, resetMemberPassword, setMemberStatus } from '../../ui/invites.js';

function addMemberModal(onDone) {
  const m = openModal(`
    <h3>CAを追加</h3>
    <p class="hint">新しいCAのログインIDと初期パスワードを発行します。初期パスワードは次の画面に一度だけ表示されます。</p>
    <form novalidate>
      <div class="field"><label for="am-name">名前</label><input id="am-name" name="name" required></div>
      <div class="field"><label for="am-mail">連絡用メールアドレス（任意）</label><input id="am-mail" name="email" type="email"></div>
      <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary">追加する</button></div>
    </form>`);
  const form = m.el.querySelector('form');
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();
  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    try {
      const r = await callFn('v2-member-create', { name: String(f.get('name') || '').trim(), email: String(f.get('email') || '').trim() });
      m.close();
      const text = `ログインURL：${location.origin + location.pathname}\nログインID：${r.login_id}\n初期パスワード：${r.temp_password}\n（はじめてのログインでパスワードの変更を求められます）`;
      const rm = openModal(`<h3>CAを追加しました</h3>
        <p class="callout warn">初期パスワードは<b>この画面にしか表示されません</b>。本人に伝えてください。</p>
        <textarea class="invite-text" readonly rows="5" aria-label="ログイン情報">${esc(text)}</textarea>
        <div class="modal-actions"><button class="btn" data-act="close">閉じる</button><button class="btn btn-primary" data-act="copy">コピー</button></div>`);
      rm.el.querySelector('[data-act="copy"]').onclick = async () => { try { await navigator.clipboard.writeText(text); toast('コピーしました'); } catch { rm.el.querySelector('textarea').select(); } };
      rm.el.querySelector('[data-act="close"]').onclick = () => rm.close();
      onDone();
    } catch (err) { showError(err, 'CAの追加'); }
  }); };
}

async function render(el) {
  const owner = S.member.is_owner;
  const me = S.company.id;
  const [{ data: members, error: e1 }, { data: fronts, error: e2 }, { data: invs, error: e3 }, { data: jobs, error: e4 }, { data: offers, error: e5 }] = await Promise.all([
    sb().from('v2_members').select('*,v2_v1_locked').eq('company_id', me).order('login_id'),   // v2_v1_locked: V1 から移した切替前のアカウント
    sb().from('v2_companies').select('id,code,name,status,created_at,tier').eq('parent_id', me).order('code'),
    sb().from('v2_invites').select('*').eq('issued_by', me).in('status', ['issued', 'expired']).order('created_at', { ascending: false }),
    sb().from('v2_jobs').select('id,title,status,client:v2_clients!v2_jobs_client_id_fkey(name),v2_my_fee').order('updated_at', { ascending: false }).limit(200),
    sb().from('v2_job_offers').select('*').eq('company_id', me),
  ]);
  const err = e1 || e2 || e3 || e4 || e5;
  if (err) throw userError(err, 'パートナー管理を読み込めませんでした');
  // フロントへの支払い（自社が支払う報酬の行。1000件ずつ全部）
  const pays = await loadRewardRows((q) => q.eq('payer_company_id', me));
  // フロントの代表者（連絡先）
  let reps = {};
  if (fronts.length) {
    const { data: r, error: e6 } = await sb().from('v2_members').select('company_id,name,email,login_id').eq('is_owner', true).in('company_id', fronts.map((f) => f.id));
    if (e6) throw userError(e6, 'フロントの代表者を読み込めませんでした');
    reps = Object.fromEntries(r.map((x) => [x.company_id, x]));
  }
  const offerOf = (jid) => offers.find((o) => o.job_id === jid);
  const paySum = rewardSums(pays, today().slice(0, 7));
  // 紹介料が未設定（0円）のまま入社が確定した行（支払う側が額を入れるまで、フロントには「紹介料 未設定」と見える）
  const noFeeCount = pays.filter((r) => !Number(r.fee_amount) && r.pay_status !== 'paid' && !r.refund_status).length;

  el.innerHTML = `
    ${owner ? '' : '<p class="callout">変更できるのは会社の代表者だけです。ここでは内容を確認できます。</p>'}
    <section class="card">
      <div class="card-head"><h2>自社のCA <small class="sub">${esc(S.company.name)}（${esc(S.company.code)}・${esc(tierLabel(S.company.tier))}）</small></h2>
        ${owner ? '<button class="btn btn-primary" id="add-member">CAを追加</button>' : ''}</div>
      <div class="table-wrap"><table class="table">
        <thead><tr><th>ログインID</th><th>名前</th><th>連絡用メール</th><th>状態</th>${owner ? '<th></th>' : ''}</tr></thead>
        <tbody>${members.map((m) => `<tr>
          <td class="mono">${esc(m.login_id)}</td>
          <td>${esc(m.name)}${m.is_owner ? ' <span class="tag">代表者</span>' : ''}${m.id === S.member.id ? ' <span class="tag">あなた</span>' : ''}</td>
          <td>${esc(m.email || '—')}</td>
          <td>${m.v2_v1_locked ? '<span class="tag">V1から移行（切替日に有効化）</span>' : m.status === 'active' ? (m.must_change_pw ? '<span class="tag st-relay">初回ログイン待ち</span>' : '利用中') : '<span class="tag st-closed">停止中</span>'}</td>
          ${owner ? `<td class="row-actions">${m.is_owner || m.v2_v1_locked ? '' : `
            <button class="btn btn-sm" data-reset="${esc(m.id)}">パスワード再設定</button>
            <button class="btn btn-sm" data-status="${esc(m.id)}">${m.status === 'active' ? '停止' : '再開'}</button>`}</td>` : ''}
        </tr>`).join('')}</tbody></table></div>
    </section>

    <section class="card">
      <div class="card-head"><h2>フロント企業 <small class="sub">あなたの会社が招待した、1つ下の階層の会社</small></h2>
        ${owner ? '<button class="btn btn-primary" id="invite">フロントを招待</button>' : ''}</div>
      ${fronts.length ? `<div class="table-wrap"><table class="table">
        <thead><tr><th>企業コード</th><th>会社名</th><th>代表者</th><th>状態</th><th>登録日</th></tr></thead>
        <tbody>${fronts.map((f) => `<tr>
          <td class="mono">${esc(f.code)}</td><td>${esc(f.name)}</td>
          <td>${esc(reps[f.id]?.name || '—')}${reps[f.id]?.email ? `<br><small class="sub">${esc(reps[f.id].email)}</small>` : ''}</td>
          <td>${f.status === 'active' ? '利用中' : '<span class="tag st-closed">停止中</span>'}</td><td>${fmtDate(f.created_at)}</td>
        </tr>`).join('')}</tbody></table></div>` : '<div class="empty">まだフロント企業はありません。</div>'}
      ${invs.length ? `<h3>招待中（まだ登録していない会社）</h3><div class="table-wrap"><table class="table">
        <thead><tr><th>企業コード</th><th>会社名</th><th>状態</th><th>期限</th><th></th></tr></thead>
        <tbody>${inviteRows(invs, owner)}</tbody></table></div>` : ''}
    </section>

    <section class="card">
      <h2>フロントへの求人の提示</h2>
      <p class="hint">あなたの会社に提示されている求人を、フロント企業にも見せるかどうかと、フロントに表示する紹介料を決めます。フロントには、ここで入力した額だけが表示されます。フロントの求職者が入社すると、その時点の額が下の「フロントへの支払い」に記録されます（額が未入力の求人は「紹介料 未設定」で記録され、あとから入れられます）。</p>
      ${jobs.length ? `<div class="table-wrap"><table class="table offer-table">
        <thead><tr><th>求人</th><th>あなたへの紹介料</th><th>フロントに公開</th><th>フロントに表示する紹介料（円）</th>${owner ? '<th></th>' : ''}</tr></thead>
        <tbody>${jobs.map((j) => { const o = offerOf(j.id); return `<tr data-job="${esc(j.id)}">
          <td><a href="#" data-open="${esc(j.id)}">${esc(j.client?.name || '')}<br><small class="sub">${esc(j.title)}</small></a></td>
          <td class="mono">${j.v2_my_fee == null ? '未設定' : fmtYen(j.v2_my_fee)}</td>
          <td>${owner ? `<input type="checkbox" name="pub" ${o?.published ? 'checked' : ''} aria-label="${esc(j.title)}をフロントに公開">` : (o?.published ? '公開中' : '—')}</td>
          <td>${owner ? `<input type="number" name="fee" min="0" step="1" inputmode="numeric" value="${o?.fee_display ?? ''}" aria-label="${esc(j.title)}のフロント向け紹介料">` : (o?.published ? fmtYen(o.fee_display) : '—')}</td>
          ${owner ? '<td><button class="btn btn-sm" data-save-offer>保存</button></td>' : ''}
        </tr>`; }).join('')}</tbody></table></div>` : '<div class="empty">あなたの会社に提示されている求人はまだありません。</div>'}
    </section>

    <section class="card">
      <h2>フロントへの支払い <small class="sub">あなたの会社からフロント企業への紹介料（成約報酬）</small></h2>
      <p class="hint">フロントの求職者が入社すると、ここに並びます。額は入社が確定した時点の「フロントに表示する紹介料」、返金規定はKANOAが求人ごとに決めた規定で固定されます。支払済み・退職・返金済みは${owner ? 'ここで記録してください（フロントの報酬の画面に表示されます）' : '代表者が記録します'}。支払前に退職した場合は、返金ではなく支払額から差し引きます（全額を差し引くと「支払なし」）。</p>
      ${noFeeCount ? `<p class="callout warn">紹介料が未設定のフロントへの支払いが<b>${noFeeCount}件</b>あります。${owner
        ? '表の「紹介料を入れる」から額（税抜）を入れてください。フロントの報酬の画面にも反映されます。' : '代表者が額を入れます。'}</p>` : ''}
      ${pays.length ? `<div class="stat-grid">
        <div class="stat"><div class="label">支払待ち 合計（税込）</div><div class="num">${fmtYen(paySum.payWait)}</div></div>
        <div class="stat"><div class="label">返金待ち 合計（税込）</div><div class="num">${fmtYen(paySum.refundWait)}</div></div>
        <div class="stat"><div class="label">今月の支払済み（税込）</div><div class="num">${fmtYen(paySum.paidMonth)}</div></div>
      </div>${rewardTableHtml(pays, { party: { label: '支払先', cell: payeeCell }, canAct: owner })}`
      : '<div class="empty">フロントへの支払いはまだありません。</div>'}
    </section>`;

  const reload = () => render(el);
  el.querySelector('#add-member')?.addEventListener('click', () => addMemberModal(reload));
  el.querySelector('#invite')?.addEventListener('click', () => issueInviteModal({
    title: 'フロント企業を招待', hint: `招待した会社は${tierLabel(S.company.tier + 1)}（あなたの会社の1つ下）として登録されます。`, onDone: reload }));
  bindInviteRows(el, invs, reload);
  if (owner) bindRewardActions(el, pays, () => reload().catch((e) => showError(e, 'パートナー管理の表示')));
  el.querySelectorAll('[data-reset]').forEach((b) => { b.onclick = () => resetMemberPassword(members.find((m) => m.id === b.dataset.reset)); });
  el.querySelectorAll('[data-status]').forEach((b) => {
    const m = members.find((x) => x.id === b.dataset.status);
    b.onclick = () => setMemberStatus(m, m.status === 'active' ? 'suspended' : 'active', reload);
  });
  el.querySelectorAll('[data-open]').forEach((a) => { a.onclick = (e) => { e.preventDefault(); window.open(`${location.pathname}#/job?id=${a.dataset.open}`, '_blank'); }; });
  el.querySelectorAll('[data-save-offer]').forEach((b) => {
    b.onclick = () => busy(b, async () => {
      const tr = b.closest('tr'); const jid = tr.dataset.job; const o = offerOf(jid);
      const published = tr.querySelector('[name="pub"]').checked;
      try {
        // 入力欄そのものを渡す（全角数字・カンマ入りを「未入力」と取り違えない）
        const feeIn = parseYen(tr.querySelector('[name="fee"]'), 'フロントに表示する紹介料');
        if (published && feeIn == null) throw new Error('公開するには、フロントに表示する紹介料を入力してください。');
        const fee = feeIn ?? (o?.fee_display ?? 0);
        if (o) await updateRow('v2_job_offers', o, { published, fee_display: fee });
        else if (published) {
          const { error } = await sb().from('v2_job_offers').insert({ job_id: jid, company_id: me, fee_display: fee, published });
          if (error) throw userError(error, '保存できませんでした');
        } else { toast('変更はありません'); return; }
        toast(published ? 'フロントに公開しました' : 'フロントへの公開を止めました'); reload();
      } catch (err) { showError(err, 'フロントへの提示'); }
    });
  });
}

register('partners', { title: 'パートナー管理', icon: 'network', order: 50, roles: ['ca'], render });
