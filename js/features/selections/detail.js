// 選考詳細: 求職者・求人・紹介料・書類（履歴書・職務経歴書）・選考の進み具合・経路／右側に連絡（第4段階）
// 操作: 送客・見送り（判断待ちの会社）、受入・見送り（KANOAに届いたときのRA）、辞退（紹介した側）
//       進み具合の更新（社内求人=RA、外部求人=登録した会社）
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDateTime, fmtYen } from '../../ui/format.js';
import { openModal, showError, toast, busy, confirmDialog } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { stageTag, RESULT_LABEL, EVENT_LABEL } from '../../ui/selection.js';
import { openFile } from '../../ui/files.js';
import { mountChat } from './chat.js';

const owns = (companyId) => (companyId ? companyId === S.company?.id : S.role === 'ra');

function noteModal({ title, okLabel, danger = false, placeholder = '' }) {
  return new Promise((resolve) => {
    let done = false;
    const m = openModal(`
      <h3>${esc(title)}</h3>
      <form novalidate>
        <div class="field"><label for="nm-note">コメント（任意・相手に届きます）</label>
          <textarea id="nm-note" name="note" rows="4" placeholder="${esc(placeholder)}"></textarea></div>
        <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button>
          <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}">${esc(okLabel)}</button></div>
      </form>`, { onClose: () => { if (!done) resolve(null); } });
    m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
    m.el.querySelector('form').onsubmit = (e) => {
      e.preventDefault(); done = true;
      resolve({ note: String(new FormData(e.target).get('note') || '').trim() || null }); m.close();
    };
  });
}

async function render(el, params) {
  const { data: a, error } = await sb().from('v2_applications')
    .select('*, candidate:v2_candidates!v2_applications_candidate_id_fkey(id, name, kana), job:v2_jobs!v2_applications_job_id_fkey(id, title, client:v2_clients!v2_jobs_client_id_fkey(name), v2_my_fee), parties:v2_application_parties!v2_application_parties_application_id_fkey(company:v2_companies!v2_application_parties_company_id_fkey(id, code, name, parent_id, tier))')
    .eq('id', params.id).maybeSingle();
  if (error) throw userError(error, '選考を読み込めませんでした');
  if (!a) { el.innerHTML = '<div class="empty">この選考は見つからないか、見る権限がありません。</div>'; return; }
  const [{ data: ms, error: e2 }, { data: events, error: e3 }, { data: files, error: e4 }] = await Promise.all([
    sb().from('v2_milestones').select('*').eq('application_id', a.id).order('seq'),
    sb().rpc('v2_application_events_for', { p_app: a.id }),
    // 履歴書・職務経歴書（この選考に関わる会社は、選考を通して求職者の書類を見られる。DBの権限で判定）
    sb().from('v2_candidate_files').select('id, kind, name, storage_path, created_at').eq('candidate_id', a.candidate_id).in('kind', ['resume', 'cv']).order('created_at'),
  ]);
  if (e2 || e3) throw userError(e2 || e3, '選考の詳細を読み込めませんでした');
  if (e4) console.warn('v2_candidate_files', e4);   // 書類が読めなくても選考の詳細は出す

  const isRA = S.role === 'ra';
  const waitingMe = a.stage === 'relay' && ((isRA && !a.holder_company_id && a.kanoa_visible) || (a.holder_company_id && a.holder_company_id === S.company?.id));
  const view = { ...a, milestones: ms, waiting_me: waitingMe, holder_is_kanoa: !a.holder_company_id };
  const canWithdraw = owns(a.applied_by_company) && ['relay', 'active'].includes(a.stage);
  const canEditMs = ['active', 'closed'].includes(a.stage) && (a.kind === 'internal' ? isRA && a.kanoa_visible : owns(a.applied_by_company));
  const source = (a.parties || []).map((p) => p.company).filter(Boolean)
    .find((c) => (isRA ? c.tier === 1 : c.parent_id === S.company?.id));
  const isMine = owns(a.applied_by_company);
  const clientName = a.kind === 'internal' ? (a.job?.client?.name || '（求人を表示できません）') : (a.external_company || '（会社名なし）');
  const jobTitle = a.kind === 'internal' ? (a.job?.title || '') : (a.external_title || '');

  document.getElementById('view-title').textContent = `選考詳細：${a.candidate?.name || ''}`;
  const actions = setTopbarActions(`
    <a class="btn" href="#/selections${isMine ? '?tab=mine' : '?tab=received'}">戻る</a>
    ${canWithdraw ? '<button class="btn btn-danger" id="act-withdraw">選考を辞退</button>' : ''}
    ${waitingMe ? `<button class="btn btn-danger" id="act-reject">見送る</button>
      <button class="btn btn-primary" id="act-go">${isRA ? '受け入れて選考を始める' : 'アップラインへ送客'}</button>` : ''}`);

  el.innerHTML = `
    <div class="sel-layout">
      <div class="sel-main">
        <button type="button" class="btn mobile-only jump-chat" id="jump-chat">💬 連絡へ移動</button>
        ${waitingMe ? `<p class="callout">${isRA ? 'この選考はKANOAの受入待ちです。内容を確認して「受け入れて選考を始める」か「見送る」を選んでください。'
          : 'この選考はあなたの会社の判断待ちです。内容を確認して「アップラインへ送客」か「見送る」を選んでください。'}</p>` : ''}
        <section class="card">
          <div class="sel-head">
            <div>
              <p class="sub">求職者</p>
              <h2><a href="#/candidate?id=${a.candidate_id}">${esc(a.candidate?.name || '')}</a> ${a.candidate?.kana ? `<small class="sub">${esc(a.candidate.kana)}</small>` : ''}</h2>
            </div>
            <div>${stageTag(view)}</div>
          </div>
          <dl class="kv">
            <dt>求人企業</dt><dd>${a.kind === 'internal'
              ? (a.job ? `<a href="#" id="open-job">${esc(clientName)}</a>` : esc(clientName))
              : `<a href="${esc(a.external_url)}" target="_blank" rel="noopener noreferrer">${esc(clientName)}</a> <span class="tag">外部求人</span>`}</dd>
            <dt>求人</dt><dd>${esc(jobTitle || '—')}</dd>
            ${a.kind === 'external' ? `<dt>応募先URL</dt><dd class="url"><a href="${esc(a.external_url)}" target="_blank" rel="noopener noreferrer">${esc(a.external_url)}</a></dd><dt>応募日</dt><dd>${esc(a.applied_on || '—')}</dd>` : ''}
            <dt>紹介料</dt><dd>${a.kind === 'internal' ? (a.job?.v2_my_fee == null ? '未設定' : `<span class="mono">${fmtYen(a.job.v2_my_fee)}</span>`) : '対象外（外部求人）'}</dd>
            ${source ? `<dt>紹介元</dt><dd>${esc(source.name)}（${esc(source.code)}）</dd>` : ''}
            ${a.memo && isMine ? `<dt>メモ</dt><dd class="pre">${esc(a.memo)}</dd>` : ''}
          </dl>
        </section>
        <section class="card">
          <h2>書類</h2>
          ${e4 ? '<p class="sub">書類を読み込めませんでした。画面を読み込み直してください。</p>' : `<dl class="kv sel-docs">${[['resume', '履歴書'], ['cv', '職務経歴書']].map(([k, label]) => {
            const list = (files || []).filter((x) => x.kind === k);
            return `<dt>${label}</dt><dd>${list.length ? list.map((x) => `<a href="#" class="doc-link" data-file="${x.id}">📄 ${esc(x.name)}</a>`).join('<br>')
              : '<span class="sub">未登録</span>'}</dd>`;
          }).join('')}</dl>`}
        </section>
        <section class="card">
          <h2>選考の進み具合</h2>
          ${a.stage === 'relay' ? '<p class="sub">KANOAが受け入れると、選考フローの各段階がここに並びます。</p>'
          : ms.length ? `<div class="table-wrap"><table class="table ms-table">
            <thead><tr><th>段階</th><th>予定日</th><th>実施日</th><th>結果</th>${canEditMs ? '<th></th>' : ''}</tr></thead>
            <tbody>${ms.map((m) => canEditMs ? `
              <tr data-ms="${m.id}">
                <td>${esc(m.name)}</td>
                <td><input type="date" name="scheduled" value="${m.scheduled_on || ''}" aria-label="${esc(m.name)}の予定日"></td>
                <td><input type="date" name="done" value="${m.done_on || ''}" aria-label="${esc(m.name)}の実施日"></td>
                <td><select name="result" aria-label="${esc(m.name)}の結果">${Object.entries(RESULT_LABEL).map(([k, v]) => `<option value="${k}" ${m.result === k ? 'selected' : ''}>${v}</option>`).join('')}</select></td>
                <td><button class="btn btn-sm" data-save="${m.id}">保存</button></td>
              </tr>` : `
              <tr><td>${esc(m.name)}</td><td>${m.scheduled_on || '—'}</td><td>${m.done_on || '—'}</td>
                <td><span class="tag ms-tag-${m.result}">${RESULT_LABEL[m.result]}</span></td></tr>`).join('')}</tbody></table></div>
            ${!canEditMs && a.kind === 'internal' ? '<p class="hint">社内求人の選考の進み具合は、KANOAが更新します。</p>' : ''}`
          : '<p class="sub">選考フローがありません。</p>'}
        </section>
        <section class="card">
          <h2>経路と記録</h2>
          <ol class="timeline">${events.map((e) => `
            <li><b>${esc(e.company_label)}</b> が ${esc(EVENT_LABEL[e.action] || e.action)}
              <small class="sub">${fmtDateTime(e.created_at)}</small>
              ${e.note ? `<div class="pre tl-note">${esc(e.note)}</div>` : ''}</li>`).join('')}</ol>
        </section>
      </div>
      <aside class="card sel-chat" id="sel-chat"><div class="empty">連絡を読み込み中…</div></aside>
    </div>`;

  const reload = () => { el.__cleanup?.(); render(el, params); };
  el.__cleanup = mountChat(el.querySelector('#sel-chat'), a,
    { onUnreadChange: () => document.dispatchEvent(new CustomEvent('v2:selection-changed')) });
  // スマホでは連絡が画面のいちばん下になるので、そこへ移動するボタン
  el.querySelector('#jump-chat')?.addEventListener('click', () => el.querySelector('#sel-chat')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  el.querySelectorAll('[data-file]').forEach((x) => {
    x.onclick = (e) => { e.preventDefault(); openFile(files.find((f) => f.id === x.dataset.file)).catch((err) => showError(err, '書類を開く')); };
  });
  el.querySelector('#open-job')?.addEventListener('click', (e) => { e.preventDefault(); window.open(`${location.pathname}#/job?id=${a.job_id}`, '_blank'); });

  const call = async (fn, args, msg) => {
    const { error: err } = await sb().rpc(fn, args);
    if (err) throw userError(err, '操作できませんでした');
    toast(msg); reload();
    document.dispatchEvent(new CustomEvent('v2:selection-changed'));
  };
  actions.querySelector('#act-go')?.addEventListener('click', async (e) => {
    const r = await noteModal(isRA ? { title: '受け入れて選考を始める', okLabel: '受け入れる', placeholder: '紹介元（1次パートナー）へのコメント' }
      : { title: 'アップラインへ送客', okLabel: '送客する', placeholder: 'アップラインへの申し送り' });
    if (!r) return;
    busy(e.target, () => call('v2_relay_decide', { p_app: a.id, p_action: isRA ? 'accept' : 'forward', p_note: r.note },
      isRA ? '受け入れました。選考を始めます' : '送客しました').catch((err) => showError(err, '送客・受入')));
  });
  actions.querySelector('#act-reject')?.addEventListener('click', async (e) => {
    const r = await noteModal({ title: '見送る', okLabel: '見送る', danger: true, placeholder: '紹介元へ伝える理由' });
    if (!r) return;
    busy(e.target, () => call('v2_relay_decide', { p_app: a.id, p_action: 'reject', p_note: r.note }, '見送りました')
      .catch((err) => showError(err, '見送り')));
  });
  actions.querySelector('#act-withdraw')?.addEventListener('click', async (e) => {
    if (!await confirmDialog(`${a.candidate?.name || ''}さんのこの選考を辞退しますか？\n辞退すると元に戻せません。`, { okLabel: '辞退の手続きへ', danger: true })) return;
    const r = await noteModal({ title: '選考を辞退', okLabel: '辞退する', danger: true, placeholder: '辞退の理由（アップラインに届きます）' });
    if (!r) return;
    busy(e.target, () => call('v2_withdraw', { p_app: a.id, p_note: r.note }, '辞退しました').catch((err) => showError(err, '辞退')));
  });
  el.querySelectorAll('[data-save]').forEach((b) => {
    b.onclick = () => busy(b, async () => {
      const tr = b.closest('tr');
      const m = ms.find((x) => x.id === b.dataset.save);
      const v = (n) => tr.querySelector(`[name="${n}"]`).value || null;
      try {
        await call('v2_milestone_save', { p_id: m.id, p_version: m.version, p_scheduled: v('scheduled'), p_done: v('done'), p_result: v('result') }, `「${m.name}」を保存しました`);
      } catch (err) { showError(err, '進み具合の保存'); }
    });
  });
}

register('selection', { title: '選考詳細', nav: false, navParent: 'selections', render });
