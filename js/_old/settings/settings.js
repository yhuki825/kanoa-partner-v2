// 設定: 自社情報の編集・パスワード変更（パートナー）／管理者情報（KANOA）
import { register } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';
import { toast } from '../../ui/components.js';
import { tierLabel } from '../../config.js';

async function render(el) {
  if (S.role === 'kanoa') {
    el.innerHTML = `
      <div class="card"><h2>管理者情報</h2>
        <p>ログイン中: <b>${esc(S.adminEmail || '—')}</b></p>
        <p style="color:var(--c-text-sub);font-size:12.5px;margin-top:6px">
          パスワードの変更はSupabaseの管理画面、またはログイン画面の「パスワードを忘れた場合」から行えます。</p>
      </div>`;
    return;
  }

  const { data: me, error } = await sb().from('companies')
    .select('code,tier,name,contact,email,phone,bank').eq('id', S.company.id).single();
  if (error) throw error;

  el.innerHTML = `
    <div class="card">
      <h2>自社情報</h2>
      <p style="margin-bottom:12px">企業コード: <b>${esc(me.code)}</b>（${esc(tierLabel(me.tier))}）</p>
      <form id="info-form">
        <div class="field"><label>会社名</label><input name="name" value="${esc(me.name || '')}" required></div>
        <div class="field"><label>担当者名</label><input name="contact" value="${esc(me.contact || '')}"></div>
        <div class="field"><label>メールアドレス</label><input name="email" type="email" value="${esc(me.email || '')}"></div>
        <div class="field"><label>電話番号</label><input name="phone" type="tel" value="${esc(me.phone || '')}"></div>
        <div class="field"><label>振込先（銀行・支店・口座）</label><textarea name="bank" rows="2">${esc(me.bank?.text || '')}</textarea></div>
        <button class="btn btn-primary">保存</button>
      </form>
    </div>
    <div class="card">
      <h2>パスワード変更</h2>
      <form id="pw-form">
        <div class="field"><label>現在のパスワード</label><input name="current" type="password" required autocomplete="current-password"></div>
        <div class="field"><label>新しいパスワード（8文字以上）</label><input name="new" type="password" required minlength="8" autocomplete="new-password"></div>
        <button class="btn btn-primary">変更する</button>
      </form>
    </div>`;

  el.querySelector('#info-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const { error: e2 } = await sb().from('companies').update({
      name: f.get('name'), contact: f.get('contact'), email: f.get('email'),
      phone: f.get('phone'), bank: { text: f.get('bank') || '' },
    }).eq('id', S.company.id);
    if (e2) { toast(`保存に失敗しました（${e2.message}）`, 'err'); return; }
    S.company.name = f.get('name');
    toast('保存しました', 'ok');
  };

  el.querySelector('#pw-form').onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const { error: e2 } = await sb().rpc('v2_change_password', {
      p_current: f.get('current'), p_new: f.get('new'),
    });
    if (e2) {
      const msg = /mismatch/.test(e2.message) ? '現在のパスワードが違います。'
        : /weak/.test(e2.message) ? '新しいパスワードは8文字以上にしてください。'
        : `変更に失敗しました（${e2.message}）`;
      toast(msg, 'err'); return;
    }
    e.target.reset();
    toast('パスワードを変更しました', 'ok');
  };
}

register('settings', { title: '設定', nav: true, icon: '⚙️', render });
