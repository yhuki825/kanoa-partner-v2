// 自社の求職者: 登録・一覧・進捗確認（パートナー用）
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtDate } from '../../ui/format.js';
import { toast, openModal } from '../../ui/components.js';

// 進捗の見せ方: リレー中は「どこまで進んだか」、KANOA到着後は選考ステータス
function progressLabel(cand) {
  if (cand.stage === 'relay') {
    return cand.holder_id === S.company?.id
      ? '自社で確認中'
      : cand.holder_id ? 'アップライン側で確認中' : 'KANOA確認待ち';
  }
  if (cand.stage === 'screening') return `KANOA選考中（${cand.status || '確認中'}）`;
  if (cand.stage === 'rejected') return '見送り';
  return '終了';
}

async function registerModal(onDone) {
  // 共有されている募集中の案件（希望案件として選択可）
  const { data: pjs } = await sb().from('projects_v2').select('id,name').eq('status', 'open').order('name');
  const pjOptions = (pjs || []).map((p) => `<option value="${p.id}">${esc(p.name)}</option>`).join('');
  const m = openModal(`
    <h3>求職者を登録</h3>
    <form id="cand-form">
      <div class="field"><label>氏名 *</label><input name="name" required></div>
      ${pjOptions ? `<div class="field"><label>希望案件</label><select name="project_id"><option value="">未定</option>${pjOptions}</select></div>` : ''}
      <div class="field"><label>フリガナ</label><input name="kana"></div>
      <div class="field"><label>電話番号</label><input name="phone" type="tel"></div>
      <div class="field"><label>メールアドレス</label><input name="email" type="email"></div>
      <div class="field"><label>住所</label><input name="address"></div>
      <div class="field"><label>希望エリア</label><input name="area"></div>
      <div class="field"><label>申し送り（アップラインへの伝達事項）</label><textarea name="note" rows="3"></textarea></div>
      <div class="modal-actions">
        <button type="button" class="btn" data-act="cancel">キャンセル</button>
        <button class="btn btn-primary">登録する</button>
      </div>
    </form>`);
  m.el.querySelector('[data-act="cancel"]').onclick = () => m.close();
  m.el.querySelector('#cand-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const btn = e.target.querySelector('.btn-primary');
    btn.disabled = true;
    const payload = Object.fromEntries(['name','kana','phone','email','address','area','note','project_id'].map((k) => [k, f.get(k) || null]));
    const { error } = await sb().rpc('v2_register_candidate', { p: payload });
    if (error) {
      const msg = /duplicate|unique/i.test(error.message)
        ? 'この電話番号はすでに登録されています。' : `登録に失敗しました（${error.message}）`;
      toast(msg, 'err'); btn.disabled = false; return;
    }
    toast('登録しました。アップラインへ送られました', 'ok');
    m.close(); onDone();
  };
}

async function render(el) {
  const { data: cands, error } = await sb().from('candidates')
    .select('id,name,kana,area,stage,status,holder_id,created_at')
    .eq('registered_by', S.company.id)
    .order('created_at', { ascending: false });
  if (error) throw error;

  const rows = (cands || []).map((x) => `
    <tr>
      <td><b>${esc(x.name)}</b>${x.kana ? `<br><small style="color:var(--c-text-sub)">${esc(x.kana)}</small>` : ''}</td>
      <td>${esc(x.area || '—')}</td>
      <td>${esc(progressLabel(x))}</td>
      <td>${fmtDate(x.created_at)}</td>
    </tr>`).join('');

  el.innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h2 style="margin:0">自社の求職者</h2>
        <button class="btn btn-primary" id="btn-add">＋ 求職者を登録</button>
      </div>
      ${rows ? `<div style="overflow-x:auto"><table class="table">
        <tr><th>氏名</th><th>希望エリア</th><th>進捗</th><th>登録日</th></tr>${rows}</table></div>`
      : `<div class="empty">まだ求職者がいません。「求職者を登録」から登録すると、あなたのアップラインへ送られます。</div>`}
    </div>`;
  el.querySelector('#btn-add').onclick = () => registerModal(() => render(el));
}

register('candidates', {
  title: '自社の求職者', nav: true, icon: '👤', roles: ['partner'], render,
});
