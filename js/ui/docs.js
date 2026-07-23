// 書類（履歴書等）の共有部品: 一覧・アップロード・ダウンロード
// 保存先: storage bucket 'candidate-docs' / パス v2/{candidate_id}/{time}_{filename}
import { sb } from '../supabase.js';
import { S } from '../store.js';
import { esc, fmtDateTime } from './format.js';
import { toast, openModal, confirmDialog } from './components.js';

const BUCKET = 'candidate-docs';

function fmtSize(n) {
  if (n == null) return '—';
  if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))}KB`;
  return `${(n / 1024 / 1024).toFixed(1)}MB`;
}

export function docsModal(cand) {
  const m = openModal(`
    <h3>書類 — ${esc(cand.name)}</h3>
    <div id="doc-list"><div class="empty">読み込み中…</div></div>
    <div class="field" style="margin-top:12px"><label>アップロード（履歴書・職務経歴書など）</label>
      <input type="file" id="doc-file"></div>
    <div class="modal-actions"><button class="btn" data-act="close">閉じる</button></div>`);
  m.el.querySelector('[data-act="close"]').onclick = () => m.close();

  const listEl = m.el.querySelector('#doc-list');

  async function load() {
    const { data: docs, error } = await sb().from('documents_v2')
      .select('*').eq('candidate_id', cand.id).order('created_at', { ascending: false });
    if (error) { listEl.innerHTML = '<div class="empty">読み込みに失敗しました</div>'; return; }
    listEl.innerHTML = (docs || []).length ? `
      <table class="table">${docs.map((d) => `
        <tr>
          <td><a href="#" data-dl="${d.id}">${esc(d.name)}</a>
            <br><small style="color:var(--c-text-sub)">${fmtSize(d.size)}・${fmtDateTime(d.created_at)}</small></td>
          <td style="width:60px;text-align:right"><a href="#" data-del="${d.id}" style="color:var(--c-danger)">削除</a></td>
        </tr>`).join('')}</table>`
      : '<div class="empty">書類はまだありません</div>';

    listEl.querySelectorAll('[data-dl]').forEach((a) => {
      a.onclick = async (e) => {
        e.preventDefault();
        const d = docs.find((x) => x.id === a.dataset.dl);
        const { data: url } = await sb().storage.from(BUCKET).createSignedUrl(d.storage_path, 300);
        if (url?.signedUrl) window.open(url.signedUrl, '_blank');
        else toast('ダウンロードURLの取得に失敗しました', 'err');
      };
    });
    listEl.querySelectorAll('[data-del]').forEach((a) => {
      a.onclick = async (e) => {
        e.preventDefault();
        if (!await confirmDialog('この書類を削除しますか？', { okLabel: '削除', danger: true })) return;
        const d = docs.find((x) => x.id === a.dataset.del);
        try { await sb().storage.from(BUCKET).remove([d.storage_path]); } catch {}
        const { error: e2 } = await sb().from('documents_v2').delete().eq('id', d.id);
        if (e2) { toast('削除に失敗しました（権限がありません）', 'err'); return; }
        load();
      };
    });
  }

  m.el.querySelector('#doc-file').onchange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    if (file.size > 20 * 1024 * 1024) { toast('20MB以下のファイルにしてください', 'err'); return; }
    const safe = file.name.replace(/[^\w.\-ぁ-んァ-ヶ一-龠]/g, '_');
    const path = `v2/${cand.id}/${Date.now()}_${safe}`;
    const { error: upErr } = await sb().storage.from(BUCKET)
      .upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
    if (upErr) { toast(`アップロードに失敗しました（${upErr.message}）`, 'err'); return; }
    const { error: insErr } = await sb().from('documents_v2').insert({
      candidate_id: cand.id, name: file.name, kind: 'other', size: file.size,
      mime: file.type, storage_path: path,
      uploaded_by: S.role === 'partner' ? S.company.id : null,
    });
    if (insErr) { toast(`登録に失敗しました（${insErr.message}）`, 'err'); return; }
    toast('アップロードしました', 'ok');
    e.target.value = '';
    load();
  };

  load();
}
