// 選考ごとのチャット（選考詳細の右側）
// 相手は直上と直下だけ。中間の会社は「アップラインとの連絡」「紹介元との連絡」をタブで切り替える
// 送信は送信ボタン or ⌘/Ctrl+Enter（Enter単体は改行。誤送信防止・ユーザー指定）
// 更新はリアルタイム配信＋保険の定期取得（配信が止まっていても会話が止まらない。V1の教訓）
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDateTime } from '../../ui/format.js';
import { icon } from '../../ui/icons.js';
import { openModal, confirmDialog, showError, busy } from '../../ui/components.js';
import { userError } from '../../ui/db.js';

const REACTIONS = ['👍', '✅', '🙏', '😄', '🎉'];
const STAMPS = ['👍', '🙏', '🎉', '💪', '😄', '🙇', '✨', '⭕', '❌', '⏰'];
const POLL_MS = 15000;

const tabLabel = (t) => (t.my_side === 'self' ? `アップラインとの連絡` : `紹介元との連絡`);

export function mountChat(box, app, { onUnreadChange } = {}) {
  let threads = [];
  let current = null;
  let messages = [];
  let replyTo = null;
  let hasOlder = false;
  let channel = null;
  let timer = null;
  let alive = true;
  let seq = 0;               // 読み込みの順番（遅れて返ってきた古い結果を捨てる）
  let holdUnread = false;    // 「未読に戻す」を押した後は、自分が操作するまで自動で既読にしない
  let lastMarked = null;     // 最後に既読にした時点の相手の最新メッセージ時刻

  async function loadThreads() {
    const { data, error } = await sb().rpc('v2_my_threads', { p_app: app.id });
    if (error) throw userError(error, '連絡の相手を読み込めませんでした');
    threads = data;
  }

  function emptyReason() {
    if (app.kind === 'external') return '外部求人の選考には、連絡する相手がいません（あなたの会社の中だけの選考です）。';
    if (!app.applied_by_company) return 'KANOAの求職者の選考です。パートナーとの連絡はありません。';
    return 'この選考で連絡できる相手はまだいません。';
  }

  function shell() {
    if (!threads.length) { box.innerHTML = `<h2>連絡</h2><p class="hint">${esc(emptyReason())}</p>`; return; }
    box.innerHTML = `
      ${threads.length > 1 ? `<div class="tabs chat-tabs" role="tablist">${threads.map((t, i) => `
        <button role="tab" class="tab ${t === current ? 'active' : ''}" data-ti="${i}" aria-selected="${t === current}">
          ${esc(tabLabel(t))}<span class="badge" ${Number(t.unread) ? '' : 'hidden'}>${Number(t.unread) || ''}</span></button>`).join('')}</div>` : ''}
      <div class="chat-head">
        <div><b>${esc(current.partner_label)}</b><small class="sub">${esc(tabLabel(current))}</small></div>
        <button class="btn btn-sm" data-act="unread" title="この会話を未読に戻す">未読に戻す</button>
      </div>
      <div class="pin-bar" hidden></div>
      <div class="conv-body" aria-live="polite"></div>
      <div class="reply-bar" hidden><span></span><button class="btn btn-sm" data-act="reply-cancel">取消</button></div>
      <form class="composer" novalidate>
        <button type="button" class="btn" data-act="stamp" title="スタンプ" aria-label="スタンプ">🙂</button>
        <label class="sr-only" for="chat-input">メッセージ</label>
        <textarea id="chat-input" rows="2" placeholder="メッセージ（${navigator.platform.includes('Mac') ? '⌘' : 'Ctrl'}+Enterで送信）"></textarea>
        <button class="btn btn-primary">送信</button>
      </form>`;
    box.querySelectorAll('[data-ti]').forEach((b) => { b.onclick = () => openThread(threads[Number(b.dataset.ti)]); });
    box.querySelector('[data-act="unread"]').onclick = async () => {
      const { error } = await sb().rpc('v2_thread_mark_unread', { p_app: app.id, p_thread: current.thread_company_id });
      if (error) { showError(userError(error), '未読に戻す'); return; }
      holdUnread = true; lastMarked = null;
      await refreshUnread(); onUnreadChange?.();
    };
    box.querySelector('[data-act="reply-cancel"]').onclick = () => setReply(null);
    const release = () => { if (holdUnread) { holdUnread = false; markReadIfNeeded(); } };
    box.querySelector('.conv-body').addEventListener('click', release);
    box.querySelector('.composer textarea').addEventListener('focus', release);
    box.querySelector('[data-act="stamp"]').onclick = (e) => stampPicker(e.currentTarget);
    const form = box.querySelector('.composer');
    const ta = form.querySelector('textarea');
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && !e.isComposing) { e.preventDefault(); form.requestSubmit(); }
    });
    form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
      const body = ta.value.trim();
      if (!body) return;
      if (await send({ body })) { ta.value = ''; ta.dataset.dirty = ''; }
    }); };
  }

  async function send({ body = null, stamp = null }) {
    const { error } = await sb().rpc('v2_msg_send', {
      p_app: app.id, p_thread: current.thread_company_id, p_body: body, p_stamp: stamp, p_reply_to: replyTo });
    if (error) { showError(userError(error, '送信できませんでした'), '連絡の送信'); return false; }
    setReply(null); holdUnread = false;
    await loadMessages(); return true;
  }

  function setReply(m) {
    replyTo = m?.id || null;
    const bar = box.querySelector('.reply-bar');
    if (!bar) return;
    bar.hidden = !m;
    if (m) bar.querySelector('span').textContent = `返信先：${(m.stamp || m.body || '').slice(0, 40)}`;
  }

  function stampPicker(anchor) {
    box.querySelector('.stamp-pop')?.remove();
    const pop = document.createElement('div');
    pop.className = 'stamp-pop';
    pop.innerHTML = STAMPS.map((s) => `<button type="button" aria-label="スタンプ ${s}">${s}</button>`).join('');
    anchor.closest('.composer').appendChild(pop);
    pop.querySelectorAll('button').forEach((b) => { b.onclick = () => { pop.remove(); send({ stamp: b.textContent }); }; });
    setTimeout(() => document.addEventListener('mousedown', function h(ev) { if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener('mousedown', h); } }), 0);
  }

  function reactionsHtml(m) {
    const list = Array.isArray(m.reactions) ? m.reactions : [];
    if (!list.length) return '';
    const g = {};
    list.forEach((r) => { (g[r.emoji] ||= []).push(r.member_id); });
    return `<div class="msg-reactions">${Object.entries(g).map(([e, ids]) =>
      `<button class="rx ${ids.includes(S.member.id) ? 'on' : ''}" data-rx="${esc(m.id)}" data-emoji="${esc(e)}" aria-label="${esc(e)} ${ids.length}件">${esc(e)}${ids.length > 1 ? ` ${ids.length}` : ''}</button>`).join('')}</div>`;
  }

  function msgHtml(m, byId) {
    const side = m.mine ? 'mine' : 'other';
    if (m.deleted) return `<div class="msg-row ${side}"><div class="msg ${side} is-deleted">削除されたメッセージ</div><div class="msg-meta">${fmtDateTime(m.created_at)}</div></div>`;
    const rep = m.reply_to && byId[m.reply_to];
    return `
      <div class="msg-row ${side}" data-id="${esc(m.id)}">
        ${!m.mine && m.sender_name ? `<div class="msg-sender">${esc(m.sender_name)}</div>` : ''}
        <div class="msg ${side} ${m.stamp ? 'is-stamp' : ''}">
          ${m.pinned ? `<span class="msg-pin" title="ピン留め">${icon('pin', 12)}</span>` : ''}
          ${rep ? `<div class="msg-reply">↩ ${esc((rep.deleted ? '削除されたメッセージ' : (rep.stamp || rep.body || '')).slice(0, 40))}</div>` : ''}
          ${m.stamp ? `<div class="msg-stamp">${esc(m.stamp)}</div>` : `<div class="msg-body pre">${esc(m.body)}</div>`}
        </div>
        ${reactionsHtml(m)}
        <div class="msg-meta">
          ${fmtDateTime(m.created_at)}${m.edited ? '・編集済み' : ''}${m.mine && m.read_by_other ? '・既読' : ''}
          <a href="#" data-act="react" aria-label="リアクション">😊</a>
          <a href="#" data-act="reply">返信</a>
          <a href="#" data-act="pin">${m.pinned ? 'ピン解除' : 'ピン'}</a>
          ${m.mine ? `${m.stamp ? '' : '<a href="#" data-act="edit">編集</a>'}<a href="#" data-act="delete">削除</a>` : ''}
        </div>
      </div>`;
  }

  async function loadMessages({ older = false, silent = false } = {}) {
    if (!current || !alive) return;
    const mySeq = ++seq;
    const tid = current.thread_company_id;
    const oldest = messages[0];
    const { data, error } = await sb().rpc('v2_thread_messages', {
      p_app: app.id, p_thread: tid, p_before: older ? oldest?.created_at : null, p_before_id: older ? oldest?.id : null, p_limit: 200 });
    // 待っている間に画面を離れた・タブを替えた・新しい読み込みが始まった → この結果は捨てる
    if (!alive || mySeq !== seq || !current || current.thread_company_id !== tid) return;
    if (error) {
      if (silent) console.warn('連絡の定期取得に失敗', error);   // 定期取得の失敗で帯を出し続けない
      else showError(userError(error, '連絡を読み込めませんでした'), '連絡');
      return;
    }
    const body = box.querySelector('.conv-body');
    if (!body) return;
    const atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
    if (older) { messages = [...data, ...messages]; hasOlder = data.length === 200; }
    else {
      const keepOld = messages.filter((m) => data.length && (m.created_at < data[0].created_at || (m.created_at === data[0].created_at && m.id < data[0].id)));
      messages = [...keepOld, ...data];
      hasOlder = hasOlder || data.length === 200;
    }
    render(body, older ? null : atBottom);
    await markReadIfNeeded();
  }

  // 相手の新しいメッセージがあり、画面が見えていて、「未読に戻す」直後でなければ既読にする
  async function markReadIfNeeded() {
    if (holdUnread || document.visibilityState !== 'visible' || !current) return;
    const newestOther = messages.filter((m) => !m.mine).map((m) => m.created_at).sort().pop() || null;
    if (!newestOther || (lastMarked && newestOther <= lastMarked)) return;
    const { error } = await sb().rpc('v2_thread_mark_read', { p_app: app.id, p_thread: current.thread_company_id });
    if (error || !alive) return;
    lastMarked = newestOther;
    await refreshUnread(); onUnreadChange?.();
  }

  function render(body, stickBottom) {
    const byId = Object.fromEntries(messages.map((m) => [m.id, m]));
    const prevH = body.scrollHeight, prevTop = body.scrollTop;
    body.innerHTML = (hasOlder ? '<button class="btn btn-sm older" data-act="older">さらに前を読み込む</button>' : '') +
      (messages.length ? messages.map((m) => msgHtml(m, byId)).join('') : '<div class="empty">まだやり取りはありません。</div>');
    if (stickBottom === null) body.scrollTop = body.scrollHeight - prevH + prevTop;   // 前を読み込んだら位置を保つ
    else if (stickBottom !== false) body.scrollTop = body.scrollHeight;
    const pins = messages.filter((m) => m.pinned && !m.deleted);
    const pinBar = box.querySelector('.pin-bar');
    pinBar.hidden = !pins.length;
    pinBar.innerHTML = pins.slice(-3).map((m) => `<a href="#" data-jump="${esc(m.id)}">${icon('pin', 12)} ${esc((m.stamp || m.body || '').slice(0, 40))}</a>`).join('');
    bindMessages(body, byId);
  }

  function bindMessages(body, byId) {
    body.querySelector('[data-act="older"]')?.addEventListener('click', () => loadMessages({ older: true }));
    box.querySelectorAll('[data-jump]').forEach((a) => {
      a.onclick = (e) => {
        e.preventDefault();
        const t = body.querySelector(`[data-id="${a.dataset.jump}"]`);
        if (t) { t.scrollIntoView({ behavior: 'smooth', block: 'center' }); t.classList.add('flash'); setTimeout(() => t.classList.remove('flash'), 1200); }
      };
    });
    body.querySelectorAll('.msg-row[data-id]').forEach((row) => {
      const m = byId[row.dataset.id];
      const act = (name, fn) => row.querySelector(`[data-act="${name}"]`)?.addEventListener('click', (e) => { e.preventDefault(); fn(e); });
      act('reply', () => { setReply(m); box.querySelector('textarea').focus(); });
      act('pin', () => rpc('v2_msg_pin', { p_id: m.id, p_pinned: !m.pinned }, 'ピン留め'));
      act('delete', async () => {
        if (!await confirmDialog('このメッセージを削除しますか？', { okLabel: '削除する', danger: true })) return;
        rpc('v2_msg_delete', { p_id: m.id }, 'メッセージの削除');
      });
      act('edit', () => editModal(m));
      act('react', (e) => reactionPicker(e.target, m));
    });
    body.querySelectorAll('.rx').forEach((b) => { b.onclick = () => rpc('v2_msg_react', { p_id: b.dataset.rx, p_emoji: b.dataset.emoji }, 'リアクション'); });
  }

  async function rpc(fn, args, context) {
    const { error } = await sb().rpc(fn, args);
    if (error) { showError(userError(error, '操作できませんでした'), context); return; }
    await loadMessages();
  }

  function reactionPicker(anchor, m) {
    box.querySelector('.emoji-pop')?.remove();
    const pop = document.createElement('div');
    pop.className = 'emoji-pop';
    pop.innerHTML = REACTIONS.map((x) => `<button aria-label="${x}">${x}</button>`).join('');
    anchor.closest('.msg-row').appendChild(pop);
    pop.querySelectorAll('button').forEach((b) => { b.onclick = () => { pop.remove(); rpc('v2_msg_react', { p_id: m.id, p_emoji: b.textContent }, 'リアクション'); }; });
    setTimeout(() => document.addEventListener('mousedown', function h(ev) { if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener('mousedown', h); } }), 0);
  }

  function editModal(m) {
    const md = openModal(`
      <h3>メッセージを編集</h3>
      <form novalidate><div class="field"><label for="ed-body">内容</label><textarea id="ed-body" rows="5">${esc(m.body)}</textarea></div>
      <div class="modal-actions"><button type="button" class="btn" data-act="cancel">キャンセル</button><button class="btn btn-primary">保存</button></div></form>`);
    md.el.querySelector('[data-act="cancel"]').onclick = () => md.close();
    md.el.querySelector('form').onsubmit = (e) => { e.preventDefault(); busy(md.el.querySelector('.btn-primary'), async () => {
      const v = md.el.querySelector('textarea').value.trim();
      if (!v || v === m.body) { md.close(); return; }
      const { error } = await sb().rpc('v2_msg_edit', { p_id: m.id, p_version: m.version, p_body: v });
      if (error) { showError(userError(error, '保存できませんでした'), 'メッセージの編集'); return; }
      md.close(); loadMessages();
    }); };
  }

  async function refreshUnread() {
    const { data } = await sb().rpc('v2_my_threads', { p_app: app.id });
    if (!data || !alive) return;
    data.forEach((d) => { const t = threads.find((x) => x.thread_company_id === d.thread_company_id); if (t) t.unread = d.unread; });
    box.querySelectorAll('[data-ti]').forEach((b) => {
      const t = threads[Number(b.dataset.ti)]; const badge = b.querySelector('.badge');
      badge.hidden = !Number(t.unread); badge.textContent = Number(t.unread) || '';
    });
  }

  async function openThread(t) {
    current = t; messages = []; hasOlder = false; replyTo = null; holdUnread = false; lastMarked = null;
    shell();
    await loadMessages();
  }

  function subscribe() {
    try {
      channel = sb().channel(`v2-chat-${app.id}-${crypto.randomUUID()}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'v2_messages', filter: `application_id=eq.${app.id}` },
          (p) => {
            const tid = p.new?.thread_company_id || p.old?.thread_company_id;
            if (current && tid === current.thread_company_id) {
              if (p.eventType === 'INSERT' && p.new?.side && p.new.side !== current.my_side) holdUnread = false;
              loadMessages({ silent: true });
            }
            else refreshUnread().then(() => onUnreadChange?.());
          })
        .subscribe();
    } catch { /* 配信が使えなくても、下の定期取得で追いつく */ }
    timer = setInterval(() => { if (alive && document.visibilityState === 'visible') loadMessages({ silent: true }); }, POLL_MS);
  }

  (async () => {
    try {
      await loadThreads();
      if (!alive) return;
      current = threads.find((t) => Number(t.unread)) || threads[0] || null;
      shell();
      if (current) { await loadMessages(); if (alive) subscribe(); }
    } catch (e) {
      if (!alive) return;
      box.innerHTML = '<h2>連絡</h2><p class="hint">連絡を表示できませんでした。</p>';
      showError(e, '連絡');
    }
  })();

  return function cleanup() {
    alive = false;
    if (channel) { try { sb().removeChannel(channel); } catch {} channel = null; }
    if (timer) { clearInterval(timer); timer = null; }
  };
}
