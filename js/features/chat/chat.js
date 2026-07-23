// 連絡チャット: スレッド = 企業⇔そのアップライン（Aラインの相手はKANOA）
// 自分が「上側」か「下側」かで sender の見え方を切り替える
//   - 自社スレッド（相手=アップ）: 自分の発言 = 'self'
//   - フロントのスレッド（相手=フロント）: 自分の発言 = 'up'
import { register, setBadge } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDateTime } from '../../ui/format.js';
import { toast, confirmDialog } from '../../ui/components.js';

let currentThread = null;   // { companyId, name, mySide: 'self'|'up' }
let rtChannel = null;
let pollTimer = null;

/* ---------- スレッド一覧 ---------- */
async function threadList() {
  const c = sb();
  const isAdmin = S.role === 'kanoa';
  const threads = [];

  if (!isAdmin) {
    // 自社スレッド（相手=アップライン。tier1ならKANOA）
    const { data: me } = await c.from('companies').select('parent_id').eq('id', S.company.id).single();
    let upName = 'KANOA';
    if (me?.parent_id) {
      const { data: up } = await c.from('companies').select('name').eq('id', me.parent_id).maybeSingle();
      upName = up?.name || 'アップライン企業';
    }
    threads.push({ companyId: S.company.id, name: `${upName}（アップ）`, mySide: 'self' });
  }

  // フロント各社のスレッド（admin: Aライン全社）
  let q = c.from('companies').select('id,code,name').eq('status', 'active').order('code');
  q = isAdmin ? q.eq('tier', 1) : q.eq('parent_id', S.company.id);
  const { data: fronts } = await q;
  (fronts || []).forEach((x) => threads.push({
    companyId: x.id, name: `${x.name}（${x.code}）`, mySide: 'up',
  }));

  // 未読数（相手側の発言で read=false）
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
function msgHtml(msg, mySide, replyMap) {
  if (msg.deleted) return `<div class="msg other" style="opacity:.55"><i>削除されたメッセージ</i></div>`;
  const mine = msg.sender === mySide;
  const reply = msg.reply_to && replyMap[msg.reply_to];
  return `
    <div class="msg ${mine ? 'mine' : 'other'}" data-msg="${msg.id}">
      ${reply ? `<div class="msg-reply">↩ ${esc((reply.body || '').slice(0, 40))}</div>` : ''}
      <div class="msg-body">${esc(msg.body || '')}</div>
      <div class="msg-meta">
        ${fmtDateTime(msg.created_at)}${msg.edited ? '・編集済み' : ''}${mine && msg.read ? '・既読' : ''}
        ${mine ? `<a href="#" data-edit="${msg.id}">編集</a> <a href="#" data-del="${msg.id}">削除</a>` : `<a href="#" data-reply="${msg.id}">返信</a>`}
      </div>
    </div>`;
}

async function loadConversation(el, thread) {
  const c = sb();
  const { data: msgs, error } = await c.from('messages_v2')
    .select('*').eq('company_id', thread.companyId).order('created_at').limit(500);
  if (error) { toast('読み込みに失敗しました', 'err'); return; }

  const replyMap = Object.fromEntries((msgs || []).map((x) => [x.id, x]));
  const body = el.querySelector('#conv-body');
  body.innerHTML = (msgs || []).map((x) => msgHtml(x, thread.mySide, replyMap)).join('')
    || '<div class="empty">まだメッセージはありません</div>';
  body.scrollTop = body.scrollHeight;

  // 相手の未読メッセージを既読化
  const unreadIds = (msgs || []).filter((x) => x.sender !== thread.mySide && !x.read).map((x) => x.id);
  if (unreadIds.length) await c.from('messages_v2').update({ read: true }).in('id', unreadIds);

  // 返信・編集・削除
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
      loadConversation(el, thread);
    };
  });
  body.querySelectorAll('[data-del]').forEach((a) => {
    a.onclick = async (e) => {
      e.preventDefault();
      if (!await confirmDialog('このメッセージを削除しますか？', { okLabel: '削除', danger: true })) return;
      await c.from('messages_v2').update({ deleted: true }).eq('id', a.dataset.del);
      loadConversation(el, thread);
    };
  });
}

let replyTo = null;
function setReplyTo(el, msg) {
  replyTo = msg?.id || null;
  const bar = el.querySelector('#reply-bar');
  if (msg) {
    bar.hidden = false;
    bar.querySelector('span').textContent = `↩ ${(msg.body || '').slice(0, 50)}`;
  } else bar.hidden = true;
}

/* ---------- リアルタイム＋保険ポーリング（V1の思想を継承） ---------- */
function subscribe(el, thread) {
  unsubscribe();
  try {
    rtChannel = sb().channel(`chat-${thread.companyId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages_v2', filter: `company_id=eq.${thread.companyId}` },
        () => loadConversation(el, thread))
      .subscribe();
  } catch {}
  // 保険: 15秒ごと（Realtimeが死んでいても会話が止まらない）
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
  unsubscribe(); currentThread = null; replyTo = null;
  const threads = await threadList();

  el.innerHTML = `
    <div class="chat-layout">
      <div class="chat-threads card" id="thread-list">
        ${threads.map((t, i) => `
          <button class="thread-item" data-idx="${i}">
            <span>${esc(t.name)}</span>
            <span class="badge" ${t.unread ? '' : 'hidden'}>${t.unread || ''}</span>
          </button>`).join('') || '<div class="empty">会話できる相手がいません</div>'}
      </div>
      <div class="chat-conv card" id="conv" hidden>
        <div class="conv-header" id="conv-title"></div>
        <div class="conv-body" id="conv-body"></div>
        <div class="reply-bar" id="reply-bar" hidden><span></span><button class="btn" id="reply-cancel">×</button></div>
        <form class="composer" id="composer">
          <textarea name="body" rows="1" placeholder="メッセージを入力（送信ボタンで送信）"></textarea>
          <button class="btn btn-primary">送信</button>
        </form>
      </div>
      <div class="chat-conv card empty" id="conv-empty" style="display:grid;place-items:center">会話を選んでください</div>
    </div>`;

  const open = async (t) => {
    currentThread = t; replyTo = null;
    el.querySelector('#conv-empty').style.display = 'none';
    const conv = el.querySelector('#conv');
    conv.hidden = false;
    el.querySelector('#conv-title').textContent = t.name;
    el.querySelectorAll('.thread-item').forEach((b) => b.classList.toggle('active', threads[b.dataset.idx] === t));
    await loadConversation(el, t);
    subscribe(el, t);
  };

  el.querySelectorAll('.thread-item').forEach((b) => {
    b.onclick = () => open(threads[b.dataset.idx]);
  });

  el.querySelector('#reply-cancel').onclick = (e) => { e.preventDefault(); setReplyTo(el, null); };

  const composer = el.querySelector('#composer');
  const ta = composer.querySelector('textarea');
  // Enterは改行のみ。送信は必ず「送信」ボタンで行う（文の途中での誤送信防止・ユーザー指定）
  ta.addEventListener('input', () => {
    ta.rows = Math.min(6, Math.max(1, ta.value.split('\n').length));
  });
  composer.onsubmit = async (e) => {
    e.preventDefault();
    if (!currentThread) return;
    const body = ta.value.trim();
    if (!body) return;
    ta.value = '';
    const { error } = await sb().from('messages_v2').insert({
      company_id: currentThread.companyId, sender: currentThread.mySide, body, reply_to: replyTo,
    });
    setReplyTo(el, null);
    if (error) { toast(`送信に失敗しました（${error.message}）`, 'err'); ta.value = body; return; }
    loadConversation(el, currentThread);
  };

  // 最初のスレッドを自動で開く（1件しかない場合に迷わせない）
  if (threads.length === 1) open(threads[0]);
}

register('chat', { title: '連絡', nav: true, icon: '💬', render });
