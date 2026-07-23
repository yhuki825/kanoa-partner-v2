// 連絡チャット: スレッド = 企業⇔そのアップライン（Aラインの相手はKANOA）
// 送信は「送信ボタン」または ⌘/Ctrl+Enter のみ（Enter単体は改行・誤送信防止）
// 機能: 返信・編集・削除・既読・リアクション・ピン留め・スタンプ・候補者カード紐づけ
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDateTime } from '../../ui/format.js';
import { toast, confirmDialog, openModal } from '../../ui/components.js';

const REACTIONS = ['👍', '✅', '🙏', '😄', '🎉'];
const STAMPS = ['👍', '🙏', '🎉', '💪', '😄', '🙇', '✨', '⭕', '❌', '⏰'];

let currentThread = null;   // { companyId, name, mySide: 'self'|'up' }
let rtChannel = null;
let pollTimer = null;
let replyTo = null;
let attachedCand = null;    // { id, name } 送信時に紐づける候補者

/* ---------- スレッド一覧 ---------- */
async function threadList() {
  const c = sb();
  const isAdmin = S.role === 'kanoa';
  const threads = [];

  if (!isAdmin) {
    const { data: me } = await c.from('companies').select('parent_id').eq('id', S.company.id).single();
    let upName = 'KANOA';
    if (me?.parent_id) {
      const { data: up } = await c.from('companies').select('name').eq('id', me.parent_id).maybeSingle();
      upName = up?.name || 'アップライン企業';
    }
    threads.push({ companyId: S.company.id, name: `${upName}（アップ）`, mySide: 'self' });
  }

  let q = c.from('companies').select('id,code,name').eq('status', 'active').order('code');
  q = isAdmin ? q.eq('tier', 1) : q.eq('parent_id', S.company.id);
  const { data: fronts } = await q;
  (fronts || []).forEach((x) => threads.push({
    companyId: x.id, name: `${x.name}（${x.code}）`, mySide: 'up',
  }));

  const ids = threads.map((t) => t.companyId);
  if (ids.length) {
    const { data: unread } = await c.from('messages_v2')
      .select('company_id,sender').eq('read', false).eq('deleted', false).in('company_id', ids);
    const map = {};
    (unread || []).forEach((msg) => {
      const t = threads.find((x) => x.companyId === msg.company_id);
      if (t && msg.sender !== t.mySide) map[msg.company_id] = (map[msg.company_id] || 0) + 1;
    });
    threads.forEach((t) => { t.unread = map[t.companyId] || 0; });
  }
  return threads;
}

/* ---------- メッセージ描画 ---------- */
function reactionsHtml(msg, mySide) {
  const rx = Array.isArray(msg.reactions) ? msg.reactions : [];
  if (!rx.length) return '';
  const grouped = {};
  rx.forEach((r) => { grouped[r.emoji] = (grouped[r.emoji] || []).concat(r.by); });
  return `<div class="msg-reactions">${Object.entries(grouped).map(([e, bys]) =>
    `<button class="rx ${bys.includes(mySide) ? 'on' : ''}" data-rx="${msg.id}" data-emoji="${e}">${e}${bys.length > 1 ? bys.length : ''}</button>`
  ).join('')}</div>`;
}

function msgHtml(msg, mySide, replyMap, candMap) {
  if (msg.deleted) return `<div class="msg-row other"><div class="msg other" style="opacity:.55"><i>削除されたメッセージ</i></div></div>`;
  const mine = msg.sender === mySide;
  const reply = msg.reply_to && replyMap[msg.reply_to];
  const cand = msg.candidate_id && candMap[msg.candidate_id];
  return `
    <div class="msg-row ${mine ? 'mine' : 'other'}" data-msg="${msg.id}">
      <div class="msg ${mine ? 'mine' : 'other'} ${msg.stamp ? 'is-stamp' : ''}">
        ${msg.pinned ? '<span class="msg-pin">📌</span>' : ''}
        ${cand ? `<div class="msg-cand">👤 ${esc(cand)}</div>` : ''}
        ${reply ? `<div class="msg-reply">↩ ${esc((reply.stamp || reply.body || '').slice(0, 40))}</div>` : ''}
        ${msg.stamp ? `<div class="msg-stamp">${esc(msg.stamp)}</div>` : `<div class="msg-body">${esc(msg.body || '')}</div>`}
      </div>
      ${reactionsHtml(msg, mySide)}
      <div class="msg-meta">
        ${fmtDateTime(msg.created_at)}${msg.edited ? '・編集済み' : ''}${mine && msg.read ? '・既読' : ''}
        <a href="#" data-react="${msg.id}">😊</a>
        <a href="#" data-pin="${msg.id}">${msg.pinned ? 'ピン解除' : 'ピン'}</a>
        ${mine
          ? `${msg.stamp ? '' : `<a href="#" data-edit="${msg.id}">編集</a>`} <a href="#" data-del="${msg.id}">削除</a>`
          : `<a href="#" data-reply="${msg.id}">返信</a>`}
      </div>
    </div>`;
}

async function loadConversation(el, thread) {
  const c = sb();
  const { data: msgs, error } = await c.from('messages_v2')
    .select('*').eq('company_id', thread.companyId).order('created_at').limit(500);
  if (error) { toast('読み込みに失敗しました', 'err'); return; }

  const replyMap = Object.fromEntries((msgs || []).map((x) => [x.id, x]));

  // 紐づく候補者名を解決
  const candIds = [...new Set((msgs || []).map((x) => x.candidate_id).filter(Boolean))];
  let candMap = {};
  if (candIds.length) {
    const { data: cands } = await c.from('candidates').select('id,name').in('id', candIds);
    candMap = Object.fromEntries((cands || []).map((x) => [x.id, x.name]));
  }

  // ピン留めバー
  const pinned = (msgs || []).filter((x) => x.pinned && !x.deleted);
  const pinBar = el.querySelector('#pin-bar');
  pinBar.hidden = !pinned.length;
  pinBar.innerHTML = pinned.slice(-3).map((x) =>
    `<a href="#" data-jump="${x.id}">📌 ${esc((x.stamp || x.body || '').slice(0, 30))}</a>`).join('');

  const body = el.querySelector('#conv-body');
  body.innerHTML = (msgs || []).map((x) => msgHtml(x, thread.mySide, replyMap, candMap)).join('')
    || '<div class="empty">まだメッセージはありません</div>';
  body.scrollTop = body.scrollHeight;

  const unreadIds = (msgs || []).filter((x) => x.sender !== thread.mySide && !x.read).map((x) => x.id);
  if (unreadIds.length) await c.from('messages_v2').update({ read: true }).in('id', unreadIds);

  const reload = () => loadConversation(el, thread);

  pinBar.querySelectorAll('[data-jump]').forEach((a) => {
    a.onclick = (e) => {
      e.preventDefault();
      const t = body.querySelector(`[data-msg="${a.dataset.jump}"]`);
      if (t) { t.scrollIntoView({ behavior: 'smooth', block: 'center' }); t.classList.add('flash'); setTimeout(() => t.classList.remove('flash'), 1200); }
    };
  });
  body.querySelectorAll('[data-reply]').forEach((a) => {
    a.onclick = (e) => { e.preventDefault(); setReplyTo(el, replyMap[a.dataset.reply]); };
  });
  body.querySelectorAll('[data-edit]').forEach((a) => {
    a.onclick = async (e) => {
      e.preventDefault();
      const msg = replyMap[a.dataset.edit];
      const text = prompt('メッセージを編集', msg.body || '');
      if (text == null || text === msg.body) return;
      await c.from('messages_v2').update({ body: text, edited: true }).eq('id', msg.id);
      reload();
    };
  });
  body.querySelectorAll('[data-del]').forEach((a) => {
    a.onclick = async (e) => {
      e.preventDefault();
      if (!await confirmDialog('このメッセージを削除しますか？', { okLabel: '削除', danger: true })) return;
      await c.from('messages_v2').update({ deleted: true }).eq('id', a.dataset.del);
      reload();
    };
  });
  body.querySelectorAll('[data-pin]').forEach((a) => {
    a.onclick = async (e) => {
      e.preventDefault();
      const msg = replyMap[a.dataset.pin];
      await c.from('messages_v2').update({ pinned: !msg.pinned }).eq('id', msg.id);
      reload();
    };
  });
  // リアクション: 絵文字ピッカーを出してトグル
  const toggleReaction = async (msg, emoji) => {
    const rx = Array.isArray(msg.reactions) ? [...msg.reactions] : [];
    const i = rx.findIndex((r) => r.emoji === emoji && r.by === thread.mySide);
    if (i >= 0) rx.splice(i, 1); else rx.push({ emoji, by: thread.mySide });
    await c.from('messages_v2').update({ reactions: rx }).eq('id', msg.id);
    reload();
  };
  body.querySelectorAll('[data-react]').forEach((a) => {
    a.onclick = (e) => {
      e.preventDefault();
      const msg = replyMap[a.dataset.react];
      const pop = document.createElement('div');
      pop.className = 'emoji-pop';
      pop.innerHTML = REACTIONS.map((x) => `<button>${x}</button>`).join('');
      a.closest('.msg-row').appendChild(pop);
      pop.querySelectorAll('button').forEach((b) => { b.onclick = () => { pop.remove(); toggleReaction(msg, b.textContent); }; });
      setTimeout(() => document.addEventListener('click', function h(ev) {
        if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener('click', h); }
      }), 0);
    };
  });
  body.querySelectorAll('.rx').forEach((b) => {
    b.onclick = () => toggleReaction(replyMap[b.dataset.rx], b.dataset.emoji);
  });
}

function setReplyTo(el, msg) {
  replyTo = msg?.id || null;
  const bar = el.querySelector('#reply-bar');
  if (msg) {
    bar.hidden = false;
    bar.querySelector('span').textContent = `↩ ${(msg.stamp || msg.body || '').slice(0, 50)}`;
  } else bar.hidden = true;
}

function setAttachedCand(el, cand) {
  attachedCand = cand;
  const bar = el.querySelector('#cand-bar');
  if (cand) {
    bar.hidden = false;
    bar.querySelector('span').textContent = `👤 ${cand.name} についての連絡`;
  } else bar.hidden = true;
}

/* ---------- 候補者ピッカー（この会話に関係する候補者） ---------- */
async function candPicker(el, thread) {
  const c = sb();
  // この会話の相手企業（または自社）が「登録した／送客した」候補者 = 会話に関係する候補者
  const ownerId = thread.mySide === 'self' ? S.company.id : thread.companyId;
  const { data: steps } = await c.from('candidate_steps')
    .select('candidate_id').eq('company_id', ownerId).in('action', ['registered', 'forwarded'])
    .order('created_at', { ascending: false }).limit(100);
  const ids = [...new Set((steps || []).map((x) => x.candidate_id))].slice(0, 50);
  let cands = [];
  if (ids.length) {
    const { data } = await c.from('candidates').select('id,name,stage').in('id', ids);
    cands = data || [];
  }
  if (!cands.length) { toast('紐づけられる求職者がいません', 'err'); return; }
  const m = openModal(`
    <h3>求職者を紐づける</h3>
    ${cands.map((x) => `<button class="btn btn-block" style="justify-content:flex-start;margin-bottom:6px" data-c="${x.id}">👤 ${esc(x.name)}</button>`).join('')}
    <div class="modal-actions"><button class="btn" data-act="cancel">キャンセル</button></div>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelectorAll('[data-c]').forEach((b) => {
    b.onclick = () => { setAttachedCand(el, cands.find((x) => x.id === b.dataset.c)); m.close(); };
  });
}

/* ---------- 送信 ---------- */
async function send(el, { body = null, stamp = null }) {
  if (!currentThread) return;
  const { error } = await sb().from('messages_v2').insert({
    company_id: currentThread.companyId, sender: currentThread.mySide,
    body, stamp, reply_to: replyTo, candidate_id: attachedCand?.id || null,
  });
  if (error) { toast(`送信に失敗しました（${error.message}）`, 'err'); return false; }
  setReplyTo(el, null); setAttachedCand(el, null);
  loadConversation(el, currentThread);
  return true;
}

/* ---------- リアルタイム＋保険ポーリング ---------- */
function subscribe(el, thread) {
  unsubscribe();
  try {
    rtChannel = sb().channel(`chat-${thread.companyId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages_v2', filter: `company_id=eq.${thread.companyId}` },
        () => loadConversation(el, thread))
      .subscribe();
  } catch {}
  pollTimer = setInterval(() => {
    if (document.visibilityState === 'visible' && currentThread === thread) loadConversation(el, thread);
  }, 15000);
}
function unsubscribe() {
  if (rtChannel) { try { sb().removeChannel(rtChannel); } catch {} rtChannel = null; }
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
}

/* ---------- 画面 ---------- */
async function render(el) {
  unsubscribe(); currentThread = null; replyTo = null; attachedCand = null;
  const threads = await threadList();
  const sendKey = navigator.platform.includes('Mac') ? '⌘+Enter' : 'Ctrl+Enter';

  const fronts = threads.filter((t) => t.mySide === 'up');

  el.innerHTML = `
    <div class="chat-layout">
      <div class="chat-threads card" id="thread-list">
        ${fronts.length >= 2 ? '<button class="btn btn-block" id="btn-bc" style="margin-bottom:8px">📢 一斉連絡</button>' : ''}
        ${threads.map((t, i) => `
          <button class="thread-item" data-idx="${i}">
            <span>${esc(t.name)}</span>
            <span class="badge" ${t.unread ? '' : 'hidden'}>${t.unread || ''}</span>
          </button>`).join('') || '<div class="empty">会話できる相手がいません</div>'}
      </div>
      <div class="chat-conv card" id="conv" hidden>
        <div class="conv-header" id="conv-title"></div>
        <div class="pin-bar" id="pin-bar" hidden></div>
        <div class="conv-body" id="conv-body"></div>
        <div class="reply-bar" id="reply-bar" hidden><span></span><button class="btn" id="reply-cancel">×</button></div>
        <div class="reply-bar" id="cand-bar" hidden><span></span><button class="btn" id="cand-cancel">×</button></div>
        <form class="composer" id="composer">
          <button type="button" class="btn" id="btn-cand" title="求職者を紐づける">👤</button>
          <button type="button" class="btn" id="btn-stamp" title="スタンプ">🏷️</button>
          <textarea name="body" rows="1" placeholder="メッセージを入力（${sendKey}で送信）"></textarea>
          <button class="btn btn-primary">送信</button>
        </form>
      </div>
      <div class="chat-conv card empty" id="conv-empty" style="display:grid;place-items:center">会話を選んでください</div>
    </div>`;

  const open = async (t) => {
    currentThread = t; setReplyTo(el, null); setAttachedCand(el, null);
    el.querySelector('#conv-empty').style.display = 'none';
    const conv = el.querySelector('#conv');
    conv.hidden = false;
    el.querySelector('#conv-title').textContent = t.name;
    el.querySelectorAll('.thread-item').forEach((b) => b.classList.toggle('active', threads[b.dataset.idx] === t));
    await loadConversation(el, t);
    subscribe(el, t);
  };

  el.querySelectorAll('.thread-item').forEach((b) => { b.onclick = () => open(threads[b.dataset.idx]); });

  // 一斉連絡: 自分のフロント全社（KANOAはAライン全社）へ同じメッセージを送る
  const bcBtn = el.querySelector('#btn-bc');
  if (bcBtn) bcBtn.onclick = () => {
    const m = openModal(`
      <h3>📢 一斉連絡（${fronts.length}社へ送信）</h3>
      <p style="font-size:12.5px;color:var(--c-text-sub);margin-bottom:8px">
        ${fronts.map((t) => esc(t.name)).join('、')} の各スレッドに同じメッセージが送られます。</p>
      <form id="bc-form">
        <div class="field"><textarea name="body" rows="4" required placeholder="お知らせ内容を入力"></textarea></div>
        <div class="modal-actions">
          <button type="button" class="btn" data-act="cancel">キャンセル</button>
          <button class="btn btn-primary">${fronts.length}社へ送信</button>
        </div>
      </form>`);
    m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
    m.el.querySelector('#bc-form').onsubmit = async (e) => {
      e.preventDefault();
      const body = new FormData(e.target).get('body').trim();
      if (!body) return;
      const btn = e.target.querySelector('.btn-primary');
      btn.disabled = true;
      const rows = fronts.map((t) => ({ company_id: t.companyId, sender: 'up', body }));
      const { error } = await sb().from('messages_v2').insert(rows);
      if (error) { toast(`送信に失敗しました（${error.message}）`, 'err'); btn.disabled = false; return; }
      toast(`${fronts.length}社へ送信しました`, 'ok');
      m.close();
      if (currentThread) loadConversation(el, currentThread);
    };
  };
  el.querySelector('#reply-cancel').onclick = (e) => { e.preventDefault(); setReplyTo(el, null); };
  el.querySelector('#cand-cancel').onclick = (e) => { e.preventDefault(); setAttachedCand(el, null); };
  el.querySelector('#btn-cand').onclick = () => { if (currentThread) candPicker(el, currentThread); };

  // スタンプピッカー
  el.querySelector('#btn-stamp').onclick = (e) => {
    if (!currentThread) return;
    const old = el.querySelector('.stamp-pop');
    if (old) { old.remove(); return; }
    const pop = document.createElement('div');
    pop.className = 'stamp-pop';
    pop.innerHTML = STAMPS.map((x) => `<button>${x}</button>`).join('');
    el.querySelector('#composer').appendChild(pop);
    pop.querySelectorAll('button').forEach((b) => {
      b.onclick = () => { pop.remove(); send(el, { stamp: b.textContent }); };
    });
  };

  const composer = el.querySelector('#composer');
  const ta = composer.querySelector('textarea');
  ta.addEventListener('input', () => {
    ta.rows = Math.min(6, Math.max(1, ta.value.split('\n').length));
  });
  // 送信: ボタン or ⌘/Ctrl+Enter（Enter単体は改行のみ・誤送信防止）
  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); composer.requestSubmit(); }
  });
  composer.onsubmit = async (e) => {
    e.preventDefault();
    const body = ta.value.trim();
    if (!body) return;
    ta.value = ''; ta.rows = 1;
    if (!await send(el, { body })) ta.value = body;
  };

  if (threads.length === 1) open(threads[0]);
}

register('chat', { title: '連絡', nav: true, icon: '💬', render });
