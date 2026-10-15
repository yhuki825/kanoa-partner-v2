// RA: 求人の登録・編集（求人企業・選考フロー・エントリー時必須項目・KANOA→1次の紹介料と公開先）
import { sb } from '../../supabase.js';
import { esc } from '../../ui/format.js';
import { openModal, showError, toast, busy } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { CANDIDATE_FIELDS } from '../../ui/candidate-fields.js';

const STATUS = { open: '募集中', paused: '一時停止', closed: '終了' };
export const JOB_STATUS = STATUS;

export async function openJobEditor(job, onDone) {
  const [{ data: clients, error: e1 }, { data: tier1, error: e2 }] = await Promise.all([
    sb().from('v2_clients').select('id,name').order('name'),
    sb().from('v2_companies').select('id,code,name').eq('tier', 1).eq('status', 'active').order('code'),
  ]);
  if (e1 || e2) throw userError(e1 || e2, '求人企業・パートナーを読み込めませんでした');
  let fee = null, shares = [];
  if (job) {
    const [{ data: f }, { data: s }] = await Promise.all([
      sb().from('v2_job_kanoa_fees').select('*').eq('job_id', job.id).maybeSingle(),
      sb().from('v2_job_shares').select('*').eq('job_id', job.id),
    ]);
    fee = f; shares = s || [];
  }
  const j = job || { title: '', description: '', conditions: '', entry_requirements: ['name'], flow: ['書類選考', '一次面接', '最終面接', '内定', '入社'], checks: { spi: false, compliance: false }, status: 'open' };
  const shareOf = (cid) => shares.find((s) => s.company_id === cid);
  const req = new Set(j.entry_requirements);

  const m = openModal(`
    <h3>${job ? '求人を編集' : '求人を登録'}</h3>
    <form class="form-grid" novalidate>
      <div class="field span2"><label for="j-client">求人企業 <em>必須</em></label>
        <select id="j-client" name="client_id">
          <option value="">選択してください</option>
          ${clients.map((c) => `<option value="${c.id}" ${c.id === j.client_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}
          <option value="__new">＋ 新しい求人企業を追加</option>
        </select>
        <input name="new_client" placeholder="新しい求人企業の名前" hidden></div>
      <div class="field span2"><label for="j-title">求人名・職種 <em>必須</em></label><input id="j-title" name="title" value="${esc(j.title)}"></div>
      <div class="field span2"><label for="j-desc">業務内容</label><textarea id="j-desc" name="description" rows="5">${esc(j.description)}</textarea></div>
      <div class="field"><label for="j-loc">勤務地</label><input id="j-loc" name="location" value="${esc(j.location || '')}"></div>
      <div class="field"><label for="j-emp">雇用形態</label><input id="j-emp" name="employment" value="${esc(j.employment || '')}"></div>
      <div class="field"><label for="j-sal">給与</label><input id="j-sal" name="salary" value="${esc(j.salary || '')}"></div>
      <div class="field"><label for="j-status">状態</label><select id="j-status" name="status">
        ${Object.entries(STATUS).map(([k, v]) => `<option value="${k}" ${j.status === k ? 'selected' : ''}>${v}</option>`).join('')}</select></div>
      <div class="field span2"><label for="j-cond">その他の条件</label><textarea id="j-cond" name="conditions" rows="3">${esc(j.conditions)}</textarea></div>
      <div class="field span2"><label for="j-flow">選考フロー（1行に1段階）</label><textarea id="j-flow" name="flow" rows="5">${esc((j.flow || []).join('\n'))}</textarea></div>
      <fieldset class="field span2"><legend>エントリー時必須項目（応募時に、求職者にこの項目が入っていないと応募できません）</legend>
        <div class="check-grid">${CANDIDATE_FIELDS.map((f) => `<label class="check"><input type="checkbox" name="req" value="${f.key}" ${req.has(f.key) || f.always ? 'checked' : ''} ${f.always ? 'disabled' : ''}> ${esc(f.label)}</label>`).join('')}</div></fieldset>
      <fieldset class="field span2"><legend>選考中のチェック</legend>
        <label class="check"><input type="checkbox" name="spi" ${j.checks?.spi ? 'checked' : ''}> SPI</label>
        <label class="check"><input type="checkbox" name="compliance" ${j.checks?.compliance ? 'checked' : ''}> コンプライアンスチェック</label></fieldset>

      <h3 class="span2">紹介料と公開先（KANOA → 1次パートナー）</h3>
      <div class="field"><label for="j-fee">紹介料（基本額・円）</label><input id="j-fee" name="fee" type="number" min="0" inputmode="numeric" value="${fee?.fee ?? ''}"></div>
      <div class="field"><label>&nbsp;</label><button type="button" class="btn" data-act="all">1次パートナー全社にチェック</button></div>
      <div class="span2 share-list">
        ${tier1.length ? tier1.map((c) => { const s = shareOf(c.id); return `
          <div class="share-row">
            <label class="check"><input type="checkbox" name="share" value="${c.id}" ${s?.published ? 'checked' : ''}> ${esc(c.code)} ${esc(c.name)}</label>
            <input type="number" min="0" inputmode="numeric" name="ovr_${c.id}" value="${s?.fee_override ?? ''}" placeholder="この会社だけ別の額（空欄＝基本額）" aria-label="${esc(c.name)}への紹介料">
          </div>`; }).join('') : '<p class="hint">まだ1次パートナーがいません。</p>'}
      </div>
      <div class="modal-actions span2">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn btn-primary">保存</button>
      </div>
    </form>`, { wide: true });

  const form = m.el.querySelector('form');
  const csel = form.querySelector('[name="client_id"]');
  const cnew = form.querySelector('[name="new_client"]');
  csel.onchange = () => { cnew.hidden = csel.value !== '__new'; if (!cnew.hidden) cnew.focus(); };
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();
  form.querySelector('[data-act="all"]').onclick = () => form.querySelectorAll('[name="share"]').forEach((x) => { x.checked = true; });

  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    try {
      let clientId = f.get('client_id');
      if (clientId === '__new') {
        const name = String(f.get('new_client') || '').trim();
        if (!name) throw new Error('新しい求人企業の名前を入力してください。');
        const { data, error } = await sb().from('v2_clients').insert({ name }).select().single();
        if (error) throw userError(error, '求人企業を登録できませんでした');
        clientId = data.id;
      }
      if (!clientId) throw new Error('求人企業を選んでください。');
      const title = String(f.get('title') || '').trim();
      if (!title) throw new Error('求人名・職種を入力してください。');
      const flow = String(f.get('flow') || '').split('\n').map((x) => x.trim()).filter(Boolean);
      if (!flow.length) throw new Error('選考フローを1段階以上入力してください。');
      const values = {
        client_id: clientId, title, description: String(f.get('description') || ''),
        location: String(f.get('location') || '').trim() || null, employment: String(f.get('employment') || '').trim() || null,
        salary: String(f.get('salary') || '').trim() || null, status: f.get('status'),
        conditions: String(f.get('conditions') || ''), flow,
        entry_requirements: ['name', ...f.getAll('req').filter((k) => k !== 'name')],
        checks: { spi: f.get('spi') === 'on', compliance: f.get('compliance') === 'on' },
      };
      let saved;
      if (job) saved = await updateRow('v2_jobs', job, values);
      else {
        const { data, error } = await sb().from('v2_jobs').insert(values).select().single();
        if (error) throw userError(error, '求人を保存できませんでした');
        saved = data;
      }
      // 紹介料（基本額）
      const feeVal = String(f.get('fee') || '').trim();
      if (feeVal !== '') {
        const { error } = await sb().from('v2_job_kanoa_fees').upsert({ job_id: saved.id, fee: Number(feeVal) }, { onConflict: 'job_id' });
        if (error) throw userError(error, '紹介料を保存できませんでした');
      }
      // 公開先（チェックあり=公開、外した会社は非公開に）
      const checked = new Set(f.getAll('share'));
      const rows = tier1.filter((c) => checked.has(c.id) || shareOf(c.id)).map((c) => {
        const o = String(f.get(`ovr_${c.id}`) || '').trim();
        return { job_id: saved.id, company_id: c.id, published: checked.has(c.id), fee_override: o === '' ? null : Number(o) };
      });
      if (rows.length) {
        const { error } = await sb().from('v2_job_shares').upsert(rows, { onConflict: 'job_id,company_id' });
        if (error) throw userError(error, '公開先を保存できませんでした');
      }
      if (checked.size && feeVal === '' && !fee) toast('紹介料（基本額）が未入力です。1次パートナーには「未設定」と表示されます');
      else toast('保存しました');
      m.close(); onDone(saved);
    } catch (err) { showError(err, '求人の保存'); }
  }); };
}
