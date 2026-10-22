// 各種資料: RA=登録（ファイル or リンク）・編集・並べ替え・公開切替・削除／CA=公開中の資料の閲覧とダウンロード
import { register, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { openModal, showError, toast, busy, confirmDialog } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { ACCEPT, MAX_BYTES } from '../../ui/files.js';

const BUCKET = 'v2-files';
const CATEGORIES = ['履歴書・職務経歴書の雛形', '記入見本', 'マニュアル', '求人資料', 'その他'];

function editor(res, onDone) {
  const r = res || { title: '', category: CATEGORIES[0], description: '', kind: 'file', sort: 100, published: true };
  const m = openModal(`
    <h3>${res ? '資料を編集' : '資料を追加'}</h3>
    <form novalidate>
      <div class="field"><label for="rs-title">タイトル</label><input id="rs-title" name="title" value="${esc(r.title)}" required></div>
      <div class="field"><label for="rs-cat">分類</label><input id="rs-cat" name="category" value="${esc(r.category)}" list="rs-cats">
        <datalist id="rs-cats">${CATEGORIES.map((c) => `<option value="${esc(c)}">`).join('')}</datalist></div>
      <div class="field"><label for="rs-desc">説明</label><textarea id="rs-desc" name="description" rows="3">${esc(r.description)}</textarea></div>
      ${res ? (r.kind === 'link' ? `<div class="field"><label for="rs-url">リンク先URL</label><input id="rs-url" name="url" type="url" value="${esc(r.url)}"></div>`
          : `<p class="hint">ファイル：${esc(r.file_name)}（差し替えるときは、この資料を削除して追加し直してください）</p>`)
        : `<fieldset class="field"><legend>種類</legend>
          <label class="check"><input type="radio" name="kind" value="file" checked> ファイル</label>
          <label class="check"><input type="radio" name="kind" value="link"> リンク（外部のページ）</label></fieldset>
        <div class="field" data-for="file"><label for="rs-file">ファイル（20MBまで）</label><input id="rs-file" name="file" type="file" accept="${ACCEPT},.txt,.csv"></div>
        <div class="field" data-for="link" hidden><label for="rs-url">リンク先URL</label><input id="rs-url" name="url" type="url" placeholder="https://"></div>`}
      <div class="form-grid">
        <div class="field"><label for="rs-sort">並び順（小さいほど上）</label><input id="rs-sort" name="sort" type="number" value="${r.sort}"></div>
        <div class="field"><label>&nbsp;</label><label class="check"><input type="checkbox" name="published" ${r.published ? 'checked' : ''}> パートナーに公開する</label></div>
      </div>
      <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary">保存</button></div>
    </form>`, { wide: true });
  const form = m.el.querySelector('form');
  form.querySelectorAll('[name="kind"]').forEach((x) => { x.onchange = () => {
    form.querySelector('[data-for="file"]').hidden = x.value !== 'file';
    form.querySelector('[data-for="link"]').hidden = x.value !== 'link'; }; });
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();
  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    const values = {
      title: String(f.get('title') || '').trim(), category: String(f.get('category') || '').trim() || 'その他',
      description: String(f.get('description') || ''), sort: Number(f.get('sort') || 100), published: f.get('published') === 'on',
    };
    try {
      if (!values.title) throw new Error('タイトルを入力してください。');
      if (res) {
        if (res.kind === 'link') {
          values.url = String(f.get('url') || '').trim();
          if (!/^https?:\/\//i.test(values.url)) throw new Error('URLは http:// または https:// から始まる形で入力してください。');
        }
        await updateRow('v2_resources', res, values);
      } else if (f.get('kind') === 'link') {
        const url = String(f.get('url') || '').trim();
        if (!/^https?:\/\//i.test(url)) throw new Error('URLは http:// または https:// から始まる形で入力してください。');
        const { error } = await sb().from('v2_resources').insert({ ...values, kind: 'link', url, created_by: S.member.id });
        if (error) throw userError(error, '保存できませんでした');
      } else {
        const file = form.querySelector('[name="file"]').files[0];
        if (!file) throw new Error('ファイルを選んでください。');
        if (file.size > MAX_BYTES) throw new Error('20MBを超えるファイルは登録できません。');
        const id = crypto.randomUUID();
        const ext = (/\.[A-Za-z0-9]+$/.exec(file.name) || [''])[0].toLowerCase();
        const path = `resources/${id}/${crypto.randomUUID()}${ext}`;
        const up = await sb().storage.from(BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream' });
        if (up.error) throw userError(up.error, 'アップロードできませんでした');
        const { error } = await sb().from('v2_resources').insert({ ...values, id, kind: 'file', storage_path: path,
          file_name: file.name, size: file.size, mime: file.type, created_by: S.member.id });
        if (error) { await sb().storage.from(BUCKET).remove([path]); throw userError(error, '保存できませんでした'); }
      }
      toast('保存しました'); m.close(); onDone();
    } catch (err) { showError(err, '資料の保存'); }
  }); };
}

async function openRes(r) {
  if (r.kind === 'link') { window.open(r.url, '_blank', 'noopener'); return; }
  const { data, error } = await sb().storage.from(BUCKET).createSignedUrl(r.storage_path, 300, { download: r.file_name });
  if (error || !data?.signedUrl) throw userError(error, '資料を開けませんでした');
  window.open(data.signedUrl, '_blank', 'noopener');
}

async function render(el) {
  const isRA = S.role === 'ra';
  const reload = () => render(el);
  if (isRA) setTopbarActions('<button class="btn btn-primary" id="rs-new">資料を追加</button>').querySelector('#rs-new').onclick = () => editor(null, reload);
  const { data: list, error } = await sb().from('v2_resources').select('*').order('sort').order('created_at');
  if (error) throw userError(error, '資料を読み込めませんでした');
  const cats = [...new Set(list.map((r) => r.category))];
  el.innerHTML = list.length ? cats.map((c) => `
    <section class="card">
      <h2>${esc(c)}</h2>
      <ul class="res-list">${list.filter((r) => r.category === c).map((r) => `
        <li class="res-item">
          <div class="res-main">
            <a href="#" data-open="${esc(r.id)}"><b>${esc(r.title)}</b></a>
            ${r.kind === 'link' ? '<span class="tag">リンク</span>' : `<span class="sub">${esc(r.file_name || '')}</span>`}
            ${isRA && !r.published ? '<span class="tag st-closed">非公開</span>' : ''}
            ${r.description ? `<div class="sub pre">${esc(r.description)}</div>` : ''}
          </div>
          <span class="sub">${fmtDate(r.updated_at)}</span>
          ${isRA ? `<span class="row-actions"><button class="btn btn-sm" data-edit="${esc(r.id)}">編集</button><button class="btn btn-sm" data-del="${esc(r.id)}">削除</button></span>` : ''}
        </li>`).join('')}</ul>
    </section>`).join('')
    : `<section class="card"><div class="empty">${isRA ? 'まだ資料がありません。右上の「資料を追加」から、履歴書の雛形や記入見本などを登録できます。' : '公開されている資料はまだありません。'}</div></section>`;

  el.querySelectorAll('[data-open]').forEach((a) => { a.onclick = (e) => { e.preventDefault(); openRes(list.find((r) => r.id === a.dataset.open)).catch((err) => showError(err, '資料を開く')); }; });
  el.querySelectorAll('[data-edit]').forEach((b) => { b.onclick = () => editor(list.find((r) => r.id === b.dataset.edit), reload); });
  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      const r = list.find((x) => x.id === b.dataset.del);
      if (!await confirmDialog(`「${r.title}」を削除しますか？`, { okLabel: '削除する', danger: true })) return;
      const { error: e2 } = await sb().from('v2_resources').delete().eq('id', r.id);
      if (e2) { showError(userError(e2, '削除できませんでした'), '資料の削除'); return; }
      if (r.storage_path) await sb().storage.from(BUCKET).remove([r.storage_path]);
      toast('削除しました'); reload();
    };
  });
}

register('resources', { title: '各種資料', short: '資料', icon: 'folder', order: 40, render });
