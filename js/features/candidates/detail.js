// 求職者詳細: 項目・書類（追加・差し替え・削除・表示）・メモ
// 「プラットフォームに応募」（外部求人のURL登録）と選考の一覧は第3段階で有効になる
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, fmtDateTime, ageOf, fmtMan } from '../../ui/format.js';
import { showError, confirmDialog, toast, openModal, busy } from '../../ui/components.js';
import { navigate } from '../../router.js';
import { stageTag, milestoneChips } from '../../ui/selection.js';
import { userError } from '../../ui/db.js';
import { FILE_KINDS, yesNo } from '../../ui/candidate-fields.js';
import { uploadCandidateFile, openFile, deleteFile, ACCEPT } from '../../ui/files.js';

function fileSize(n) { return n == null ? '' : n < 1048576 ? `${Math.max(1, Math.round(n / 1024))}KB` : `${(n / 1048576).toFixed(1)}MB`; }


// 外部求人（ポータルに無い求人）への応募をURLで登録 → すぐ「選考」になる
function externalModal(c, existing) {
  const today = new Date().toISOString().slice(0, 10);
  const m = openModal(`
    <h3>プラットフォームに応募（外部求人の登録）</h3>
    <p class="hint">${esc(c.name)}さんが、このポータルに無い求人に応募した場合に登録します。登録した時点で「選考」になり、あなたの会社の中だけに見えます（紹介料の対象外）。</p>
    <form novalidate>
      <div class="field"><label for="ex-url">応募先のURL <em>必須</em></label><input id="ex-url" name="url" type="url" required placeholder="https://"></div>
      <div class="field"><label for="ex-co">求人企業名</label><input id="ex-co" name="company"></div>
      <div class="field"><label for="ex-title">求人名・職種</label><input id="ex-title" name="title"></div>
      <div class="field"><label for="ex-date">応募日</label><input id="ex-date" name="applied_on" type="date" value="${today}"></div>
      <div class="field"><label for="ex-flow">選考フロー（1行に1段階）</label><textarea id="ex-flow" name="flow" rows="4">書類選考\n面接\n内定</textarea></div>
      <div class="field"><label for="ex-memo">メモ（自社の中だけ）</label><textarea id="ex-memo" name="memo" rows="2"></textarea></div>
      <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary">登録して選考を始める</button></div>
    </form>`);
  const form = m.el.querySelector('form');
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();
  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    const url = String(f.get('url') || '').trim();
    try {
      if (!/^https?:\/\//i.test(url)) throw new Error('URLは http:// または https:// から始まる形で入力してください。');
      if (existing.some((x) => x.external_url === url) &&
          !await confirmDialog('この求職者は、同じURLの求人にすでに登録されています。もう1件登録しますか？', { okLabel: '登録する' })) return;
      const flow = String(f.get('flow') || '').split('\n').map((x) => x.trim()).filter(Boolean);
      const { data: id, error } = await sb().rpc('v2_register_external', {
        p_candidate: c.id, p_url: url, p_company: f.get('company'), p_title: f.get('title'),
        p_applied_on: f.get('applied_on') || null, p_flow: flow, p_memo: String(f.get('memo') || '').trim() || null });
      if (error) throw userError(error, '登録できませんでした');
      m.close(); toast('外部求人への応募を登録しました'); navigate(`selection?id=${id}`);
    } catch (err) { showError(err, '外部求人の登録'); }
  }); };
}

async function render(el, params) {
  const { data: c, error } = await sb().from('v2_candidates')
    .select('*, assigned:v2_members!v2_candidates_assigned_member_id_fkey(name, login_id)')
    .eq('id', params.id).maybeSingle();
  if (error) throw userError(error, '求職者を読み込めませんでした');
  if (!c) { el.innerHTML = '<div class="empty">この求職者は見つからないか、見る権限がありません。</div>'; return; }
  const [{ data: note }, { data: files, error: fe }, { data: canEdit }, { data: apps, error: ae }] = await Promise.all([
    sb().from('v2_candidate_notes').select('memo').eq('candidate_id', c.id).maybeSingle(),
    sb().from('v2_candidate_files').select('*').eq('candidate_id', c.id).order('created_at'),
    sb().rpc('v2_can_edit_candidate', { p_cand: c.id }),
    sb().from('v2_applications').select('id,kind,stage,result,external_url,external_company,external_title,updated_at,holder_company_id,kanoa_visible,job:v2_jobs!v2_applications_job_id_fkey(title,client:v2_clients!v2_jobs_client_id_fkey(name)),milestones:v2_milestones!v2_milestones_application_id_fkey(name,result,scheduled_on,done_on,seq)')
      .eq('candidate_id', c.id).order('updated_at', { ascending: false }),
  ]);
  if (ae) throw userError(ae, '選考を読み込めませんでした');
  apps.forEach((x) => { x.milestones.sort((p, q) => p.seq - q.seq); x.holder_is_kanoa = !x.holder_company_id;
    x.waiting_me = x.stage === 'relay' && ((S.role === 'ra' && !x.holder_company_id && x.kanoa_visible) || (x.holder_company_id && x.holder_company_id === S.company?.id)); });
  const openApps = apps.filter((x) => ['relay', 'active'].includes(x.stage));
  if (fe) throw userError(fe, '書類を読み込めませんでした');

  document.getElementById('view-title').textContent = c.name;
  const actions = setTopbarActions(`
    <a class="btn" href="#/candidates">戻る</a>
    ${canEdit ? `<a class="btn" href="#/candidate-edit?id=${c.id}">編集</a>` : ''}
    ${openApps.length === 1 ? `<a class="btn" href="#/selection?id=${openApps[0].id}">選考詳細へ</a>` : ''}
    ${canEdit ? '<button class="btn btn-primary" id="c-ext">プラットフォームに応募</button>' : ''}`);
  actions.querySelector('#c-ext')?.addEventListener('click', () => externalModal(c, apps.filter((x) => x.kind === 'external')));

  const age = ageOf(c.birth_date);
  const row = (k, v) => `<dt>${k}</dt><dd>${v}</dd>`;
  el.innerHTML = `
    <div class="detail-grid">
      <section class="card">
        <h2>${esc(c.name)} ${c.kana ? `<small class="sub">${esc(c.kana)}</small>` : ''}</h2>
        <dl class="kv">
          ${row('生年月日', c.birth_date ? `${fmtDate(c.birth_date)}（${age}歳）` : '—')}
          ${row('性別', esc(c.gender || '—'))}
          ${row('最終学歴', esc(c.education || '—'))}
          ${row('就業経験社数', c.job_changes != null ? `${c.job_changes}社` : '—')}
          ${row('現在の雇用形態', esc(c.employment_type || '—'))}
          ${row('直近の年収', fmtMan(c.current_income))}
          ${row('現住所', esc(c.prefecture || '—'))}
          ${row('メールアドレス', c.email ? `<a href="mailto:${esc(c.email)}">${esc(c.email)}</a>` : '—')}
          ${row('電話番号', c.phone ? `<a href="tel:${esc(c.phone)}">${esc(c.phone)}</a>` : '—')}
          ${row('希望勤務地', esc(c.desired_location || '—'))}
          ${row('出張・転勤', `出張：${yesNo(c.travel_ok)} ／ 転勤：${yesNo(c.relocation_ok)}`)}
          ${row('希望年収', fmtMan(c.desired_income))}
          ${row('担当', esc(c.assigned?.name || '—'))}
          ${row('登録日', fmtDateTime(c.created_at))}
        </dl>
        <h3>推薦文</h3>
        <div class="pre box">${esc(c.recommendation || '—')}</div>
        <h3>メモ <small class="sub">（${S.role === 'ra' ? 'KANOAの中だけ' : '自社の中だけ'}）</small></h3>
        <div class="pre box">${esc(note?.memo || '—')}</div>
      </section>
      <div>
        <section class="card">
          <h2>書類</h2>
          ${FILE_KINDS.map((k) => {
            const list = files.filter((f) => f.kind === k.kind);
            return `<div class="file-slot">
              <div class="file-slot-head"><b>${esc(k.label)}</b>
                ${canEdit ? `<label class="btn btn-sm">${list.length && k.kind !== 'other' ? '差し替え' : '追加'}
                  <input type="file" accept="${ACCEPT}" data-kind="${k.kind}" hidden></label>` : ''}</div>
              ${list.length ? list.map((f) => `<div class="file-row">
                  <a href="#" data-open="${f.id}">${esc(f.name)}</a>
                  <small class="sub">${fileSize(f.size)}・${fmtDate(f.created_at)}</small>
                  ${canEdit ? `<button class="btn btn-sm" data-del="${f.id}">削除</button>` : ''}
                </div>`).join('') : '<div class="sub">未提出</div>'}
            </div>`;
          }).join('')}
        </section>
        <section class="card">
          <h2>選考</h2>
          ${apps.length ? `<ul class="cand-apps">${apps.map((x) => `<li>
            <a href="#/selection?id=${x.id}"><b>${esc(x.kind === 'internal' ? (x.job?.client?.name || '') : (x.external_company || '外部求人'))}</b>
              <span class="sub">${esc(x.kind === 'internal' ? (x.job?.title || '') : (x.external_title || ''))}${x.kind === 'external' ? '（外部）' : ''}</span></a>
            ${stageTag(x)}
            ${x.stage === 'relay' ? '' : milestoneChips(x.milestones)}
          </li>`).join('')}</ul>`
          : `<div class="empty">まだ選考はありません。求人詳細の「応募する」${canEdit ? '、または右上の「プラットフォームに応募」' : ''}から始まります。</div>`}
        </section>
      </div>
    </div>`;

  const reload = () => render(el, params);
  el.querySelectorAll('[data-open]').forEach((a) => {
    a.onclick = (e) => { e.preventDefault(); openFile(files.find((f) => f.id === a.dataset.open)).catch((err) => showError(err, '書類を開く')); };
  });
  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      const f = files.find((x) => x.id === b.dataset.del);
      if (!await confirmDialog(`「${f.name}」を削除しますか？`, { okLabel: '削除する', danger: true })) return;
      try { await deleteFile(f); toast('削除しました'); reload(); } catch (err) { showError(err, '書類の削除'); }
    };
  });
  el.querySelectorAll('input[type="file"][data-kind]').forEach((inp) => {
    inp.onchange = async () => {
      const file = inp.files[0];
      if (!file) return;
      const kind = inp.dataset.kind;
      const old = kind === 'other' ? [] : files.filter((f) => f.kind === kind);
      try {
        await uploadCandidateFile(c.id, kind, file);
        for (const o of old) await deleteFile(o);    // 差し替え: 新しい方が入ってから古い方を消す
        toast('アップロードしました');
        reload();
      } catch (err) { showError(err, '書類のアップロード'); }
    };
  });
}

register('candidate', { title: '求職者詳細', nav: false, navParent: 'candidates', render });
