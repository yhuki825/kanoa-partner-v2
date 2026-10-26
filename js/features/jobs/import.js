// 求人のCSV一括登録（RA）: ひな形のダウンロード → ファイルを選ぶ → 登録前の確認（全行）→ まとめて登録
// CSVの読み取りは import-rules.js、登録してよいかの最終確認と登録は DB の v2_jobs_import（1件でもエラーなら何も登録しない）
import { sb } from '../../supabase.js';
import { esc, fmtYen } from '../../ui/format.js';
import { openModal, showError, toast, busy } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { IMPORT_COLUMNS, decodeCsvBytes, parseCsv, rowsToJobs, templateCsv } from './import-rules.js';

const RESULT = {
  ok: { label: '登録します', cls: 'st-done' },
  skip: { label: 'スキップ（登録済み）', cls: '' },
  error: { label: 'エラー', cls: 'st-closed' },
};

function downloadTemplate() {
  const url = URL.createObjectURL(new Blob([templateCsv()], { type: 'text/csv;charset=utf-8' }));
  const a = Object.assign(document.createElement('a'), { href: url, download: '求人一括登録_ひな形.csv' });
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function openJobImport(onDone) {
  let rows = null;   // 確認済みの行（登録ボタンで送る）
  const m = openModal(`
    <h3>CSVで求人を一括登録</h3>
    <ol class="import-steps">
      <li><button type="button" class="btn btn-sm" data-act="template">ひな形をダウンロード</button>
        <small class="sub">1行目の見出しはそのまま、2行目の見本（求人企業が「（例）」の行）は消してから使ってください</small></li>
      <li>Excelなどで1行に1求人ずつ記入して、CSV形式で保存します（Excelの「CSV（コンマ区切り）」のままで読めます）</li>
      <li><label class="btn btn-sm btn-primary file-pick">CSVファイルを選ぶ<input type="file" accept=".csv,text/csv" hidden></label>
        <span class="sub file-name"></span></li>
    </ol>
    <details class="import-guide"><summary>各列の書き方</summary>
      <table class="table guide-table"><thead><tr><th>見出し</th><th>書き方</th></tr></thead><tbody>
        ${IMPORT_COLUMNS.map((c) => `<tr><td><b>${esc(c.label)}</b>${c.required ? ' <span class="tag st-closed">必須</span>' : ''}</td>
          <td>${esc(c.note || '自由に記入')}${c.example ? `<br><small class="sub">例：${esc(c.example)}</small>` : ''}</td></tr>`).join('')}
      </tbody></table></details>
    <div class="import-result"></div>
    <div class="modal-actions">
      <button type="button" class="btn" data-act="close">閉じる</button>
      <button type="button" class="btn btn-primary" data-act="commit" disabled>登録する</button>
    </div>`, { wide: true });

  const box = m.el.querySelector('.import-result');
  const commitBtn = m.el.querySelector('[data-act="commit"]');
  m.el.querySelector('[data-act="template"]').onclick = downloadTemplate;
  m.el.querySelector('[data-act="close"]').onclick = () => m.close();

  const input = m.el.querySelector('input[type="file"]');
  input.onchange = async () => {
    const file = input.files[0];
    input.value = '';   // 同じファイルを直して選び直しても読み込めるように
    if (!file) return;
    m.el.querySelector('.file-name').textContent = file.name;
    rows = null; commitBtn.disabled = true; commitBtn.textContent = '登録する';
    box.innerHTML = '<p class="sub">確認しています…</p>';
    try {
      if (file.size > 5 * 1024 * 1024) throw new Error('ファイルが大きすぎます（5MBまで）。');
      const { fileErrors, rows: parsed } = rowsToJobs(parseCsv(decodeCsvBytes(await file.arrayBuffer())));
      if (fileErrors.length) {
        box.innerHTML = `<p class="callout warn">${fileErrors.map(esc).join('<br>')}</p>`; return;
      }
      // 登録前の確認（DBで全行を確かめる。ここでは何も登録しない）
      const { data, error } = await sb().rpc('v2_jobs_import', { p_rows: parsed, p_commit: false });
      if (error) throw userError(error, 'CSVを確認できませんでした');
      renderCheck(data);
      if (!data.error && data.ok) { rows = parsed; commitBtn.disabled = false; commitBtn.textContent = `${data.ok}件を登録する`; }
    } catch (err) { box.innerHTML = ''; showError(err, 'CSVの読み込み'); }
  };

  function renderCheck(d) {
    box.innerHTML = `
      <p class="import-summary">
        <span class="tag st-done">登録します ${d.ok}件</span>
        <span class="tag">スキップ（登録済み） ${d.skip}件</span>
        <span class="tag ${d.error ? 'st-closed' : ''}">エラー ${d.error}件</span>
      </p>
      ${d.error ? '<p class="callout warn">エラーの行があるため、このままでは登録できません。下の理由のとおりCSVを直して、選び直してください（1件も登録していません）。</p>'
        : d.ok ? '<p class="hint">内容を確かめて「登録する」を押してください。登録済みの求人（同じ求人企業・同じ求人名）は二重に登録しません。</p>'
          : '<p class="callout">登録する行がありません（すべて登録済みです）。</p>'}
      <div class="table-wrap"><table class="table import-table">
        <thead><tr><th>行</th><th>求人企業・求人名</th><th>結果</th><th>紹介料・公開先</th><th>理由</th></tr></thead>
        <tbody>${d.rows.map((r) => `<tr class="${r.result === 'error' ? 'is-error' : ''}">
          <td class="mono">${r.line}行目</td>
          <td>${esc(r.client || '（空）')}<br><small class="sub">${esc(r.title || '（空）')}</small></td>
          <td><span class="tag ${RESULT[r.result].cls}">${RESULT[r.result].label}</span></td>
          <td>${r.fee == null ? '<span class="sub">紹介料 未設定</span>' : fmtYen(r.fee)}<br><small class="sub">公開先 ${r.shares}社</small></td>
          <td>${(r.messages || []).map(esc).join('<br>') || '—'}</td></tr>`).join('')}</tbody></table></div>`;
  }

  commitBtn.onclick = () => busy(commitBtn, async () => {
    if (!rows) return;
    try {
      const { data, error } = await sb().rpc('v2_jobs_import', { p_rows: rows, p_commit: true });
      if (error) throw userError(error, '登録できませんでした');
      toast(`${data.ok}件の求人を登録しました${data.skip ? `（登録済みの${data.skip}件はスキップ）` : ''}`);
      m.close(); onDone?.();
    } catch (err) { showError(err, '求人の一括登録'); }
  });
}
