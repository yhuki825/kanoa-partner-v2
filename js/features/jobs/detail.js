// 求人詳細（別タブ）: 社名・業務内容・エントリー時必須項目・紹介料（自分に提示された額）
// 代表CAは、ここからフロント向けの提示（公開・表示額）を設定する
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen } from '../../ui/format.js';
import { showError, toast, busy, openModal } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { fieldLabel } from '../../ui/candidate-fields.js';
import { ageOf } from '../../ui/format.js';
import { JOB_STATUS, openJobEditor } from './editor.js';
import { refundPolicyLines, parseYen } from '../../ui/money.js';

// 返金規定（KANOA⇔1次の契約条件）: RAと、この求人を提示された1次パートナーだけ。
// それ以外にはDBが行を返さないので、何も表示しない
async function refundSection(job) {
  if (!(S.role === 'ra' || S.company?.tier === 1)) return '';
  const { data, error } = await sb().from('v2_job_refund_policies').select('policy').eq('job_id', job.id).maybeSingle();
  if (error) throw userError(error, '返金規定を読み込めませんでした');
  if (!data && S.role !== 'ra') return '';
  const lines = refundPolicyLines(data?.policy);
  return `<section class="card">
    <h2>返金規定</h2>
    ${lines.length ? `<ul class="req-list">${lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>` : '<p>返金規定はありません（早期退職でも返金は発生しません）。</p>'}
    <p class="hint">${S.role === 'ra' ? 'KANOAと1次パートナーの間の条件です。2次以降のパートナーには表示されません。「編集」から変更できます。'
      : 'KANOAとあなたの会社の間の条件です。入社が確定した時点の規定が適用されます。'}</p>
  </section>`;
}

async function frontOfferSection(job) {
  const [{ data: offer, error }, { count: fronts }] = await Promise.all([
    sb().from('v2_job_offers').select('*').eq('job_id', job.id).eq('company_id', S.company.id).maybeSingle(),
    sb().from('v2_companies').select('id', { count: 'exact', head: true }).eq('parent_id', S.company.id),
  ]);
  if (error) throw userError(error, 'フロントへの提示を読み込めませんでした');
  const owner = S.member.is_owner;
  return {
    html: `<section class="card">
      <h2>フロントへの提示</h2>
      <p class="hint">あなたの会社のフロント（${fronts ?? 0}社）にこの求人を見せるかどうかと、フロントに表示する紹介料を決めます。フロントには、ここで入力した額だけが表示されます。実際の支払いはアプリの外での取り決めです。</p>
      ${owner ? `<form class="offer-form" novalidate>
        <label class="check"><input type="checkbox" name="published" ${offer?.published ? 'checked' : ''}> フロントに公開する</label>
        <div class="field"><label for="of-fee">フロントに表示する紹介料（円）</label>
          <input id="of-fee" name="fee" type="number" min="0" step="1" inputmode="numeric" value="${offer?.fee_display ?? ''}"></div>
        <button class="btn btn-primary">保存</button>
      </form>`
      : `<p>${offer?.published ? `公開中（表示額 ${fmtYen(offer.fee_display)}）` : '公開していません'}</p>
         <p class="hint">変更できるのは会社の代表者だけです。</p>`}
    </section>`,
    bind(el, reload) {
      const form = el.querySelector('.offer-form');
      if (!form) return;
      form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('button'), async () => {
        const f = new FormData(form);
        const published = f.get('published') === 'on';
        try {
          // 入力欄そのものを渡す（全角数字・カンマ入りを「未入力」と取り違えない）
          const feeIn = parseYen(form.querySelector('[name="fee"]'), 'フロントに表示する紹介料');
          if (published && feeIn == null) throw new Error('公開するには、フロントに表示する紹介料を入力してください。');
          const fee = feeIn ?? (offer?.fee_display ?? 0);
          if (offer) await updateRow('v2_job_offers', offer, { published, fee_display: fee });
          else if (published) {
            const { error: e2 } = await sb().from('v2_job_offers').insert({ job_id: job.id, company_id: S.company.id, fee_display: fee, published });
            if (e2) throw userError(e2, '保存できませんでした');
          }
          toast(published ? 'フロントに公開しました' : 'フロントへの公開を止めました');
          reload();
        } catch (err) { showError(err, 'フロントへの提示'); }
      }); };
    },
  };
}


// 応募: 自社の求職者を選ぶ → 確認ポップアップ → 応募したら求人詳細に戻る
// エントリー時必須項目は定義の見直し中のため、不足は表示するだけで止めない（設計書13）
async function applyFlow(job) {
  let cq = sb().from('v2_candidates').select('*').order('created_at', { ascending: false }).limit(200);
  cq = S.role === 'ra' ? cq.is('owner_company_id', null) : cq.eq('owner_company_id', S.company.id);
  const { data: cands, error } = await cq;
  if (error) throw userError(error, '求職者を読み込めませんでした');
  if (!cands.length) { showError(new Error('応募できる求職者がいません。先に「求職者」から登録してください。'), '応募'); return; }
  const ids = cands.map((c) => c.id);
  const [{ data: files }, { data: apps }] = await Promise.all([
    sb().from('v2_candidate_files').select('candidate_id,kind').in('candidate_id', ids),
    sb().from('v2_applications').select('candidate_id,stage').eq('job_id', job.id).in('candidate_id', ids),
  ]);
  const applied = new Set((apps || []).filter((x) => !['withdrawn', 'rejected'].includes(x.stage)).map((x) => x.candidate_id));
  const missingOf = (c) => (job.entry_requirements || []).filter((k) =>
    (k === 'resume' || k === 'cv') ? !(files || []).some((f) => f.candidate_id === c.id && f.kind === k)
      : c[k] == null || c[k] === '').map(fieldLabel);

  const m = openModal(`
    <h3>応募する求職者を選ぶ</h3>
    <p class="hint">${esc(job.client?.name || '')}「${esc(job.title)}」</p>
    <input class="pick-search" placeholder="名前で絞り込み" aria-label="名前で絞り込み">
    <div class="pick-list">${cands.map((c) => `
      <button class="pick-row" data-id="${c.id}" ${applied.has(c.id) ? 'disabled' : ''}>
        <span class="pick-name">${esc(c.name)}</span>
        <span class="sub">${ageOf(c.birth_date) ?? '—'}歳・${esc(c.gender || '性別未登録')}</span>
        ${applied.has(c.id) ? '<span class="tag">応募済み</span>' : ''}
      </button>`).join('')}</div>
    <div class="modal-actions"><button class="btn" data-act="cancel">キャンセル</button></div>`, { wide: true });
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('.pick-search').oninput = (e) => {
    const v = e.target.value.trim();
    m.el.querySelectorAll('.pick-row').forEach((b) => { b.hidden = v && !b.querySelector('.pick-name').textContent.includes(v); });
  };
  m.el.querySelectorAll('.pick-row').forEach((b) => {
    b.onclick = () => {
      const c = cands.find((x) => x.id === b.dataset.id);
      const missing = missingOf(c);
      const where = S.role === 'ra' ? 'そのまま選考を始めます。' : S.company.tier === 1 ? 'KANOAに届きます。' : 'まずアップライン企業の確認に回ります。';
      m.close();
      const cm = openModal(`
        <h3>この内容で応募しますか？</h3>
        <dl class="kv"><dt>求職者</dt><dd>${esc(c.name)}</dd><dt>求人</dt><dd>${esc(job.client?.name || '')}「${esc(job.title)}」</dd></dl>
        ${missing.length ? `<p class="callout warn">エントリー時必須項目のうち、未入力の項目があります：${missing.map(esc).join('、')}</p>` : ''}
        <p class="hint">応募すると${where}</p>
        <div class="field"><label for="ap-note">申し送り（任意・アップラインに届きます）</label><textarea id="ap-note" rows="3"></textarea></div>
        <div class="modal-actions"><button class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary" data-act="ok">応募する</button></div>`);
      cm.el.querySelector('[data-act="cancel"]').onclick = () => cm.close();
      const ok = cm.el.querySelector('[data-act="ok"]');
      ok.onclick = () => busy(ok, async () => {
        const { error: e2 } = await sb().rpc('v2_apply', { p_candidate: c.id, p_job: job.id, p_note: cm.el.querySelector('#ap-note').value.trim() || null });
        if (e2) { showError(userError(e2, '応募できませんでした'), '応募'); return; }
        cm.close();
        toast(`${c.name}さんを応募しました。${where}`);
      });
    };
  });
}

async function render(el, params) {
  const { data: job, error } = await sb().from('v2_jobs')
    .select('*, client:v2_clients!v2_jobs_client_id_fkey(name, industry), v2_my_fee').eq('id', params.id).maybeSingle();
  if (error) throw userError(error, '求人を読み込めませんでした');
  if (!job) { el.innerHTML = '<div class="empty">この求人は見つからないか、あなたの会社には提示されていません。</div>'; return; }
  document.title = `${job.title}｜KANOA Partner Portal`;
  document.getElementById('view-title').textContent = '求人詳細';

  const a = setTopbarActions(`
    ${S.role === 'ra' ? '<button class="btn" id="j-edit">編集</button>' : ''}
    ${job.status === 'open' ? '<button class="btn btn-primary" id="j-apply">応募する</button>' : `<button class="btn" disabled>${JOB_STATUS[job.status]}のため応募できません</button>`}`);
  const reload = () => render(el, params);
  a.querySelector('#j-edit')?.addEventListener('click', () => openJobEditor(job, reload).catch((e) => showError(e, '求人の編集')));
  a.querySelector('#j-apply')?.addEventListener('click', () => applyFlow(job).catch((e) => showError(e, '応募')));

  const [offer, refundHtml] = await Promise.all([S.role === 'ca' ? frontOfferSection(job) : null, refundSection(job)]);
  el.innerHTML = `
    <div class="detail-grid">
      <section class="card">
        <p class="sub">${esc(job.client?.name || '')}${job.client?.industry ? `・${esc(job.client.industry)}` : ''}</p>
        <h2 class="job-h">${esc(job.title)} <span class="tag st-${job.status}">${JOB_STATUS[job.status]}</span></h2>
        <dl class="kv">
          <dt>勤務地</dt><dd>${esc(job.location || '—')}</dd>
          <dt>雇用形態</dt><dd>${esc(job.employment || '—')}</dd>
          <dt>給与</dt><dd>${esc(job.salary || '—')}</dd>
        </dl>
        <h3>業務内容</h3><div class="pre box">${esc(job.description || '—')}</div>
        ${job.conditions ? `<h3>その他の条件</h3><div class="pre box">${esc(job.conditions)}</div>` : ''}
        <h3>選考フロー</h3>
        <ol class="flow">${(job.flow || []).map((s) => `<li>${esc(s)}</li>`).join('')}</ol>
      </section>
      <div>
        <section class="card fee-card">
          <h2>紹介料</h2>
          <p class="fee-big">${job.v2_my_fee == null ? '未設定' : fmtYen(job.v2_my_fee)}</p>
          <p class="hint">${S.role === 'ra' ? 'KANOA→1次パートナーの基本額。会社ごとの額は「編集」から設定できます。'
            : S.company.tier === 1 ? 'KANOAからあなたの会社への紹介料です。' : 'アップライン企業があなたの会社向けに設定した表示額です。'}</p>
        </section>
        <section class="card">
          <h2>エントリー時必須項目</h2>
          <ul class="req-list">${(job.entry_requirements || []).map((k) => `<li>${esc(fieldLabel(k))}</li>`).join('')}</ul>
          ${job.checks?.spi || job.checks?.compliance ? `<p class="hint">選考中に ${[job.checks.spi && 'SPI', job.checks.compliance && 'コンプライアンスチェック'].filter(Boolean).join('・')} があります。</p>` : ''}
        </section>
        ${refundHtml}
        ${offer ? offer.html : ''}
      </div>
    </div>`;
  offer?.bind(el, reload);
}

register('job', { title: '求人詳細', nav: false, navParent: 'jobs', render });
