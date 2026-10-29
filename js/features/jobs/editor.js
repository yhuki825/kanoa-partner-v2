// RA: 求人の登録・編集（求人企業・選考フロー・エントリー時必須項目・KANOA→1次の紹介料と公開先・返金規定）
import { sb } from '../../supabase.js';
import { esc } from '../../ui/format.js';
import { openModal, showError, toast, busy } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { CANDIDATE_FIELDS } from '../../ui/candidate-fields.js';
import { parseYen } from '../../ui/money.js';

const STATUS = { open: '募集中', paused: '一時停止', closed: '終了' };
export const JOB_STATUS = STATUS;

export async function openJobEditor(job, onDone) {
  const [{ data: clients, error: e1 }, { data: tier1, error: e2 }] = await Promise.all([
    sb().from('v2_clients').select('id,name').order('name'),
    sb().from('v2_companies').select('id,code,name').eq('tier', 1).eq('status', 'active').order('code'),
  ]);
  if (e1 || e2) throw userError(e1 || e2, '求人企業・パートナーを読み込めませんでした');
  let fee = null, shares = [], refund = null, clientFee = null;
  if (job) {
    const [{ data: f }, { data: s }, { data: rp, error: e3 }, { data: cf }] = await Promise.all([
      sb().from('v2_job_kanoa_fees').select('*').eq('job_id', job.id).maybeSingle(),
      sb().from('v2_job_shares').select('*').eq('job_id', job.id),
      sb().from('v2_job_refund_policies').select('policy,version').eq('job_id', job.id).maybeSingle(),
      sb().from('v2_job_client_fees').select('fee').eq('job_id', job.id).maybeSingle(),
    ]);
    if (e3) throw userError(e3, '返金規定を読み込めませんでした');
    fee = f; shares = s || []; refund = rp; clientFee = cf;
  }
  const refundRow = (p = {}) => `
    <div class="refund-row">
      <input type="number" name="rf_months" min="1" max="120" step="1" inputmode="numeric" value="${esc(p.months ?? '')}" aria-label="入社日から何か月以内か">
      <span>か月以内の退職は</span>
      <input type="number" name="rf_rate" min="0" max="100" step="1" inputmode="numeric" value="${esc(p.rate ?? '')}" aria-label="返金率（%）">
      <span>%返金</span>
      <button type="button" class="btn btn-sm" data-act="rm-refund">削除</button>
    </div>`;
  const policyRows = [...(refund?.policy || [])].sort((a, b) => a.months - b.months);
  const j = job || { title: '', description: '', conditions: '', entry_requirements: ['name'], flow: ['書類選考', '一次面接', '二次面接', '最終面接', '内定', '入社'], checks: { spi: false, compliance: false }, status: 'open' };
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

      <h3 class="span2">求人企業からの紹介料（KANOAの受取額）</h3>
      <div class="field"><label for="j-cfee">紹介料（税抜・円）</label><input id="j-cfee" name="client_fee" type="number" min="0" step="1" inputmode="numeric" value="${clientFee?.fee ?? ''}"></div>
      <p class="hint field">KANOAだけが見られる欄です。パートナーには表示されません。</p>

      <h3 class="span2">紹介料と公開先（KANOA → 1次パートナー）</h3>
      <div class="field"><label for="j-fee">紹介料（基本額・円）</label><input id="j-fee" name="fee" type="number" min="0" step="1" inputmode="numeric" value="${fee?.fee ?? ''}"></div>
      <div class="field"><label>&nbsp;</label><button type="button" class="btn" data-act="all">1次パートナー全社にチェック</button></div>
      <div class="span2 share-list">
        ${tier1.length ? tier1.map((c) => { const s = shareOf(c.id); return `
          <div class="share-row">
            <label class="check"><input type="checkbox" name="share" value="${c.id}" ${s?.published ? 'checked' : ''}> ${esc(c.code)} ${esc(c.name)}</label>
            <input type="number" min="0" step="1" inputmode="numeric" name="ovr_${c.id}" value="${s?.fee_override ?? ''}" placeholder="この会社だけ別の額（空欄＝基本額）" aria-label="${esc(c.name)}への紹介料">
          </div>`; }).join('') : '<p class="hint">まだ1次パートナーがいません。</p>'}
      </div>

      <h3 class="span2">返金規定（KANOA ⇔ 1次パートナー）</h3>
      <div class="span2">
        <p class="hint">入社日から数えて、その期間内に退職したときに1次パートナーから返金を受ける割合です。期間の短い順に判定します（例：「1か月以内 100%」「3か月以内 50%」）。入社が確定した選考には、その時点の規定が固定されます（あとで変えても過去分は変わりません）。</p>
        <div class="refund-rows">${policyRows.map(refundRow).join('')}</div>
        <button type="button" class="btn btn-sm" data-act="add-refund">＋ 行を追加</button>
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
  const refundBox = form.querySelector('.refund-rows');
  form.querySelector('[data-act="add-refund"]').onclick = () => {
    refundBox.insertAdjacentHTML('beforeend', refundRow());
    refundBox.lastElementChild.querySelector('input').focus();
  };
  refundBox.onclick = (e) => { const b = e.target.closest('[data-act="rm-refund"]'); if (b) b.closest('.refund-row').remove(); };
  // 返金規定を読み取って確かめる（求人を保存する前に。サーバー側でも同じ確認をする）
  const readPolicy = () => {
    const out = [];
    for (const row of refundBox.querySelectorAll('.refund-row')) {
      const mIn = row.querySelector('[name="rf_months"]'), rIn = row.querySelector('[name="rf_rate"]');
      // 全角数字などの読めない入力は、欄の値が空になるため validity.badInput で見分ける
      if (mIn.validity.badInput || rIn.validity.badInput) throw new Error('返金規定は半角数字で入れてください（全角数字・小数は使えません）。');
      const ms = mIn.value.trim(), rs = rIn.value.trim();
      if (ms === '' && rs === '') continue;
      if ((ms !== '' && !/^\d+$/.test(ms)) || (rs !== '' && !/^\d+$/.test(rs))) throw new Error('返金規定は半角数字の整数で入れてください（小数・記号は使えません）。');
      const months = Number(ms), rate = Number(rs);
      if (ms === '' || rs === '') throw new Error('返金規定は「◯か月以内」と「◯%」の両方を入れてください（使わない行は削除してください）。');
      if (!Number.isInteger(months) || months < 1 || months > 120) throw new Error('返金規定の月数は1〜120の整数で入れてください。');
      if (!Number.isInteger(rate) || rate < 0 || rate > 100) throw new Error('返金規定の返金率は0〜100の整数（%）で入れてください。');
      if (out.some((p) => p.months === months)) throw new Error(`返金規定に「${months}か月以内」の行が2つあります。`);
      out.push({ months, rate });
    }
    return out.sort((a, b) => a.months - b.months);
  };

  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    try {
      // 入力の確認は、何かを保存する前にまとめて行う（途中まで保存されて残らないように）
      const policy = readPolicy();
      const feeNum = parseYen(form.querySelector('[name="fee"]'), '紹介料（基本額）');
      const clientFeeNum = parseYen(form.querySelector('[name="client_fee"]'), '求人企業からの紹介料');
      const ovrOf = Object.fromEntries(tier1.map((c) => [c.id, parseYen(form.querySelector(`[name="ovr_${c.id}"]`), `${c.name}への紹介料`)]));
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
      if (feeNum != null) {
        const { error } = await sb().from('v2_job_kanoa_fees').upsert({ job_id: saved.id, fee: feeNum }, { onConflict: 'job_id' });
        if (error) throw userError(error, '紹介料を保存できませんでした');
      }
      // 求人企業からの紹介料（KANOAだけが見られる表。空欄にしたら消す）
      if (clientFeeNum != null) {
        const { error } = await sb().from('v2_job_client_fees').upsert({ job_id: saved.id, fee: clientFeeNum }, { onConflict: 'job_id' });
        if (error) throw userError(error, '求人企業からの紹介料を保存できませんでした');
      } else if (clientFee) {
        const { error } = await sb().from('v2_job_client_fees').delete().eq('job_id', saved.id);
        if (error) throw userError(error, '求人企業からの紹介料を消せませんでした');
      }
      // 公開先（チェックあり=公開、外した会社は非公開に）
      const checked = new Set(f.getAll('share'));
      const rows = tier1.filter((c) => checked.has(c.id) || shareOf(c.id)).map((c) => {
        return { job_id: saved.id, company_id: c.id, published: checked.has(c.id), fee_override: ovrOf[c.id] };
      });
      if (rows.length) {
        const { error } = await sb().from('v2_job_shares').upsert(rows, { onConflict: 'job_id,company_id' });
        if (error) throw userError(error, '公開先を保存できませんでした');
      }
      // 返金規定（RAだけが保存できる関数。変わったときだけ送る）
      if (JSON.stringify(policy) !== JSON.stringify(policyRows.map(({ months, rate }) => ({ months, rate })))) {
        // 読んだときの version を送る（他の人の変更を古い内容で上書きしない。新規は null）
        const { error } = await sb().rpc('v2_job_refund_policy_save', { p_job: saved.id, p_policy: policy, p_version: refund?.version ?? null });
        if (error) throw userError(error, '返金規定を保存できませんでした');
      }
      if (checked.size && feeNum == null && !fee) toast('紹介料（基本額）が未入力です。1次パートナーには「未設定」と表示されます');
      else toast('保存しました');
      m.close(); onDone(saved);
    } catch (err) { showError(err, '求人の保存'); }
  }); };
}
