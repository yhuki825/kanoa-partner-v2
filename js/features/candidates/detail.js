// 求職者詳細: 項目・書類（追加・差し替え・削除・表示）・メモ
// 「プラットフォームに応募」（外部求人のURL登録）と選考の一覧は第3段階で有効になる
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate, fmtDateTime, ageOf, fmtMan } from '../../ui/format.js';
import { showError, confirmDialog, toast } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { FILE_KINDS, yesNo } from '../../ui/candidate-fields.js';
import { uploadCandidateFile, openFile, deleteFile, ACCEPT } from '../../ui/files.js';

function fileSize(n) { return n == null ? '' : n < 1048576 ? `${Math.max(1, Math.round(n / 1024))}KB` : `${(n / 1048576).toFixed(1)}MB`; }

async function render(el, params) {
  const { data: c, error } = await sb().from('v2_candidates')
    .select('*, assigned:v2_members!v2_candidates_assigned_member_id_fkey(name, login_id)')
    .eq('id', params.id).maybeSingle();
  if (error) throw userError(error, '求職者を読み込めませんでした');
  if (!c) { el.innerHTML = '<div class="empty">この求職者は見つからないか、見る権限がありません。</div>'; return; }
  const [{ data: note }, { data: files, error: fe }, { data: canEdit }] = await Promise.all([
    sb().from('v2_candidate_notes').select('memo').eq('candidate_id', c.id).maybeSingle(),
    sb().from('v2_candidate_files').select('*').eq('candidate_id', c.id).order('created_at'),
    sb().rpc('v2_can_edit_candidate', { p_cand: c.id }),
  ]);
  if (fe) throw userError(fe, '書類を読み込めませんでした');

  document.getElementById('view-title').textContent = c.name;
  const actions = setTopbarActions(`
    <a class="btn" href="#/candidates">戻る</a>
    ${canEdit ? `<a class="btn" href="#/candidate-edit?id=${c.id}">編集</a>` : ''}
    <button class="btn" disabled title="第3段階で使えるようになります">プラットフォームに応募（準備中）</button>`);

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
          <div class="empty">この求職者の選考（社内求人・外部求人）は、第3段階でここに並びます。</div>
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
