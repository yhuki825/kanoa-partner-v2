// ホーム: お知らせ（RA=作成・編集・公開範囲・ピン留め・下書き／CA=閲覧、未読はバッジ）
import { register, setBadge, setTopbarActions } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDateTime } from '../../ui/format.js';
import { icon } from '../../ui/icons.js';
import { toast, openModal, confirmDialog, showError, busy } from '../../ui/components.js';
import { insertRow, updateRow, deleteRow, userError } from '../../ui/db.js';
import { tierLabel } from '../../config.js';

const isRA = () => S.role === 'ra';

async function loadNotices() {
  let q = sb().from('v2_notices').select('*')
    .order('pinned', { ascending: false }).order('published_at', { ascending: false, nullsFirst: true })
    .limit(100);
  const { data, error } = await q;
  if (error) throw userError(error, 'お知らせを読み込めませんでした');
  let readSet = new Set();
  if (!isRA() && data.length) {
    const { data: reads, error: e2 } = await sb().from('v2_notice_reads')
      .select('notice_id').eq('member_id', S.member.id).in('notice_id', data.map((n) => n.id));
    if (e2) throw userError(e2, '既読の状態を読み込めませんでした');
    readSet = new Set(reads.map((r) => r.notice_id));
  }
  return { notices: data, readSet };
}

// 未読数をナビに出す（CAのみ）。他の画面からも呼べるよう export
export async function refreshNoticeBadge() {
  if (isRA()) return;
  try {
    const { notices, readSet } = await loadNotices();
    setBadge('home', notices.filter((n) => !readSet.has(n.id)).length);
  } catch { /* バッジの失敗は画面を止めない */ }
}

function noticeCard(n, unread) {
  const target = n.audience === 'all' ? '全社' : `${n.target_company_ids.length}社`;
  return `
    <article class="notice ${n.pinned ? 'is-pinned' : ''} ${unread ? 'is-unread' : ''}" data-id="${n.id}">
      <button class="notice-head" aria-expanded="false">
        ${n.pinned ? `<span class="notice-pin" title="ピン留め">${icon('pin', 14)}</span>` : ''}
        ${unread ? '<span class="dot" aria-label="未読"></span>' : ''}
        <span class="notice-title">${esc(n.title)}</span>
        <span class="notice-meta">${n.status === 'draft' ? '<span class="tag">下書き</span>' : fmtDateTime(n.published_at)}${isRA() ? `・${target}` : ''}</span>
      </button>
      <div class="notice-body" hidden>
        <div class="pre">${esc(n.body)}</div>
        ${isRA() ? `<div class="notice-actions"><button class="btn btn-sm" data-edit="${n.id}">編集</button></div>` : ''}
      </div>
    </article>`;
}

async function editor(notice, onDone) {
  const { data: comps, error } = await sb().from('v2_companies').select('id,code,name,tier').order('code');
  if (error) throw userError(error, '会社の一覧を読み込めませんでした');
  const n = notice || { title: '', body: '', audience: 'all', target_company_ids: [], pinned: false, status: 'draft' };
  const sel = new Set(n.target_company_ids);
  const m = openModal(`
    <h3>${notice ? 'お知らせを編集' : '新しいお知らせ'}</h3>
    <form novalidate>
      <div class="field"><label for="nt-title">タイトル</label><input id="nt-title" name="title" value="${esc(n.title)}" required></div>
      <div class="field"><label for="nt-body">本文</label><textarea id="nt-body" name="body" rows="8">${esc(n.body)}</textarea></div>
      <fieldset class="field"><legend>公開する相手</legend>
        <label class="check"><input type="radio" name="audience" value="all" ${n.audience === 'all' ? 'checked' : ''}> 全社</label>
        <label class="check"><input type="radio" name="audience" value="selected" ${n.audience === 'selected' ? 'checked' : ''}> 選んだ会社だけ</label>
        <div class="company-picks" ${n.audience === 'selected' ? '' : 'hidden'}>
          ${comps.length ? comps.map((c) => `<label class="check"><input type="checkbox" name="cid" value="${c.id}" ${sel.has(c.id) ? 'checked' : ''}> ${esc(c.code)} ${esc(c.name)} <small>${esc(tierLabel(c.tier))}</small></label>`).join('')
            : '<p class="hint">まだパートナー会社がありません。</p>'}
        </div>
      </fieldset>
      <label class="check"><input type="checkbox" name="pinned" ${n.pinned ? 'checked' : ''}> 一番上に固定する（ピン留め）</label>
      <div class="modal-actions">
        ${notice ? '<button type="button" class="btn btn-danger" data-act="delete">削除</button><span class="grow"></span>' : ''}
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button type="button" class="btn" data-act="draft">下書き保存</button>
        <button type="button" class="btn btn-primary" data-act="publish">${n.status === 'published' ? '更新して公開' : '公開する'}</button>
      </div>
    </form>`, { wide: true });
  const form = m.el.querySelector('form');
  const picks = form.querySelector('.company-picks');
  form.querySelectorAll('input[name="audience"]').forEach((r) => { r.onchange = () => { picks.hidden = r.value !== 'selected' || !r.checked; }; });
  form.querySelector('[data-act="cancel"]').onclick = () => m.close();

  const save = async (status, btn) => busy(btn, async () => {
    const f = new FormData(form);
    const title = String(f.get('title') || '').trim();
    if (!title) { showError(new Error('タイトルを入力してください。'), 'お知らせの保存'); return; }
    const audience = f.get('audience');
    const ids = f.getAll('cid');
    if (status === 'published' && audience === 'selected' && !ids.length) {
      showError(new Error('公開する会社を1社以上選んでください。'), 'お知らせの保存'); return;
    }
    const values = {
      title, body: String(f.get('body') || ''), audience,
      target_company_ids: audience === 'selected' ? ids : [],
      pinned: f.get('pinned') === 'on', status,
      published_at: status === 'published' ? (n.published_at || new Date().toISOString()) : null,
    };
    try {
      if (notice) await updateRow('v2_notices', notice, values);
      else await insertRow('v2_notices', { ...values, author_id: S.member.id });
      toast(status === 'published' ? '公開しました' : '下書きを保存しました');
      m.close(); onDone();
    } catch (e) { showError(e, 'お知らせの保存'); }
  });
  form.querySelector('[data-act="draft"]').onclick = (e) => save('draft', e.target);
  form.querySelector('[data-act="publish"]').onclick = (e) => save('published', e.target);
  const del = form.querySelector('[data-act="delete"]');
  if (del) del.onclick = async () => {
    if (!await confirmDialog(`「${n.title}」を削除しますか？\n元に戻せません。`, { okLabel: '削除する', danger: true })) return;
    try { await deleteRow('v2_notices', notice.id); toast('削除しました'); m.close(); onDone(); }
    catch (e) { showError(e, 'お知らせの削除'); }
  };
}

async function render(el) {
  const { notices, readSet } = await loadNotices();
  const published = notices.filter((n) => n.status === 'published');
  const drafts = notices.filter((n) => n.status === 'draft');
  if (!isRA()) setBadge('home', published.filter((n) => !readSet.has(n.id)).length);

  if (isRA()) {
    const a = setTopbarActions('<button class="btn btn-primary" id="nt-new">新しいお知らせ</button>');
    a.querySelector('#nt-new').onclick = () => editor(null, () => render(el)).catch((e) => showError(e, 'お知らせの作成'));
  }

  el.innerHTML = `
    <section class="card">
      <h2>お知らせ</h2>
      ${published.length ? published.map((n) => noticeCard(n, !isRA() && !readSet.has(n.id))).join('')
        : `<div class="empty">${isRA() ? '公開中のお知らせはありません。右上の「新しいお知らせ」から作成できます。' : 'お知らせはまだありません。'}</div>`}
    </section>
    ${isRA() && drafts.length ? `<section class="card"><h2>下書き</h2>${drafts.map((n) => noticeCard(n, false)).join('')}</section>` : ''}`;

  el.querySelectorAll('.notice').forEach((art) => {
    const head = art.querySelector('.notice-head');
    const body = art.querySelector('.notice-body');
    head.onclick = async () => {
      const open = body.hidden;
      body.hidden = !open;
      head.setAttribute('aria-expanded', String(open));
      if (open && art.classList.contains('is-unread')) {
        const { error } = await sb().from('v2_notice_reads')
          .upsert({ notice_id: art.dataset.id, member_id: S.member.id }, { ignoreDuplicates: true });
        if (error) { showError(userError(error, '既読にできませんでした'), 'お知らせの既読'); return; }
        art.classList.remove('is-unread');
        art.querySelector('.dot')?.remove();
        refreshNoticeBadge();
      }
    };
  });
  el.querySelectorAll('[data-edit]').forEach((b) => {
    b.onclick = () => editor(notices.find((n) => n.id === b.dataset.edit), () => render(el)).catch((e) => showError(e, 'お知らせの編集'));
  });
}

register('home', { title: 'ホーム', icon: 'home', order: 1, render });
