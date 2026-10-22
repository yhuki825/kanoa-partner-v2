// アカウント: 表示名・連絡用メールの変更、パスワード変更
import { register } from '../../router.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';
import { toast, showError, busy } from '../../ui/components.js';
import { updateRow } from '../../ui/db.js';
import { changePasswordWithCurrent, logout } from '../../auth.js';
import { tierLabel } from '../../config.js';

async function render(el) {
  const m = S.member;
  el.innerHTML = `
    <section class="card">
      <h2>あなたのアカウント</h2>
      <dl class="kv">
        ${S.role === 'ca' ? `<dt>ログインID</dt><dd class="mono">${esc(m.login_id)}</dd>
          <dt>会社</dt><dd>${esc(S.company.name)}（${esc(S.company.code)}・${esc(tierLabel(S.company.tier))}）</dd>
          <dt>役割</dt><dd>${m.is_owner ? '代表者（CAの追加・フロントの招待ができます）' : 'CA'}</dd>`
          : '<dt>役割</dt><dd>KANOA（RA）</dd>'}
      </dl>
      <form id="f-profile" novalidate>
        <div class="field"><label for="ac-name">表示名</label><input id="ac-name" name="name" value="${esc(m.name)}" required></div>
        <div class="field"><label for="ac-mail">連絡用メールアドレス</label><input id="ac-mail" name="email" type="email" value="${esc(m.email || '')}"></div>
        <button class="btn btn-primary">保存</button>
      </form>
    </section>
    <section class="card">
      <h2>パスワード変更</h2>
      <form id="f-pw" novalidate>
        <div class="field"><label for="pw-cur">現在のパスワード</label><input id="pw-cur" name="cur" type="password" required autocomplete="current-password"></div>
        <div class="field"><label for="pw-new">新しいパスワード（8文字以上）</label><input id="pw-new" name="pw" type="password" required minlength="8" autocomplete="new-password"></div>
        <div class="field"><label for="pw-new2">新しいパスワード（確認）</label><input id="pw-new2" name="pw2" type="password" required autocomplete="new-password"></div>
        <button class="btn btn-primary">変更する</button>
      </form>
    </section>
    <section class="card">
      <h2>ログアウト</h2>
      <p class="hint">この端末からログアウトします。</p>
      <button class="btn" id="ac-logout">ログアウト</button>
    </section>`;
  el.querySelector('#ac-logout').onclick = () => logout();

  el.querySelector('#f-profile').onsubmit = (e) => { e.preventDefault(); busy(e.target.querySelector('button'), async () => {
    const f = new FormData(e.target);
    const name = String(f.get('name') || '').trim();
    if (!name) { showError(new Error('表示名を入力してください。'), 'アカウントの保存'); return; }
    try {
      S.member = { ...S.member, ...await updateRow('v2_members', S.member, { name, email: String(f.get('email') || '').trim() || null }) };
      toast('保存しました');
      document.querySelector('.who')?.firstChild && (document.querySelector('.who').firstChild.textContent = name);
    } catch (err) { showError(err, 'アカウントの保存'); }
  }); };

  el.querySelector('#f-pw').onsubmit = (e) => { e.preventDefault(); busy(e.target.querySelector('button'), async () => {
    const f = new FormData(e.target);
    try {
      if (f.get('pw') !== f.get('pw2')) throw new Error('確認用のパスワードが一致しません。');
      await changePasswordWithCurrent(f.get('cur'), f.get('pw'));
      e.target.reset();
      toast('パスワードを変更しました');
    } catch (err) { showError(err, 'パスワード変更'); }
  }); };
}

register('account', { title: 'アカウント', icon: 'gear', order: 90, render });
