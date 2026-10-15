// 求人詳細（別タブ）: 社名・業務内容・エントリー時必須項目・紹介料（自分に提示された額）
// 代表CAは、ここからフロント向けの提示（公開・表示額）を設定する
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen } from '../../ui/format.js';
import { showError, toast, busy } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { fieldLabel } from '../../ui/candidate-fields.js';
import { JOB_STATUS, openJobEditor } from './editor.js';

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
          <input id="of-fee" name="fee" type="number" min="0" inputmode="numeric" value="${offer?.fee_display ?? ''}"></div>
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
        const feeStr = String(f.get('fee') || '').trim();
        try {
          if (published && feeStr === '') throw new Error('公開するには、フロントに表示する紹介料を入力してください。');
          const fee = feeStr === '' ? (offer?.fee_display ?? 0) : Number(feeStr);
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

async function render(el, params) {
  const { data: job, error } = await sb().from('v2_jobs')
    .select('*, client:v2_clients(name, industry), v2_my_fee').eq('id', params.id).maybeSingle();
  if (error) throw userError(error, '求人を読み込めませんでした');
  if (!job) { el.innerHTML = '<div class="empty">この求人は見つからないか、あなたの会社には提示されていません。</div>'; return; }
  document.title = `${job.title}｜KANOA Partner Portal`;
  document.getElementById('view-title').textContent = '求人詳細';

  const a = setTopbarActions(`
    ${S.role === 'ra' ? '<button class="btn" id="j-edit">編集</button>' : ''}
    <button class="btn btn-primary" disabled title="第3段階で使えるようになります">応募する（準備中）</button>`);
  const reload = () => render(el, params);
  a.querySelector('#j-edit')?.addEventListener('click', () => openJobEditor(job, reload).catch((e) => showError(e, '求人の編集')));

  const offer = S.role === 'ca' ? await frontOfferSection(job) : null;
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
        ${offer ? offer.html : ''}
      </div>
    </div>`;
  offer?.bind(el, reload);
}

register('job', { title: '求人詳細', nav: false, navParent: 'jobs', render });
