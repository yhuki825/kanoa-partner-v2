// 初回ログイン時のパスワード変更（代表者が追加したCAは、初期パスワードのままでは使えない）
import { changePassword } from '../../auth.js';
import { showError, toast } from '../../ui/components.js';
import { esc } from '../../ui/format.js';
import { S } from '../../store.js';

export function renderForcePasswordChange(onDone) {
  const app = document.getElementById('app');
  app.innerHTML = `
    <div class="login-wrap"><div class="login-box">
      <div class="logo"><b>パスワードの変更</b><small>${esc(S.member.login_id || '')} ${esc(S.member.name)} さん</small></div>
      <div class="card"><form novalidate>
        <p class="hint">はじめてのログインです。代表者から受け取った初期パスワードを、自分だけが知っているパスワードに変更してください。</p>
        <div class="field"><label for="np1">新しいパスワード（8文字以上）</label><input id="np1" name="pw" type="password" required minlength="8" autocomplete="new-password"></div>
        <div class="field"><label for="np2">新しいパスワード（確認）</label><input id="np2" name="pw2" type="password" required autocomplete="new-password"></div>
        <button class="btn btn-primary btn-block">変更してはじめる</button>
      </form></div>
    </div></div>`;
  const form = app.querySelector('form');
  form.querySelector('input').focus();
  form.onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(form);
    const btn = form.querySelector('button');
    btn.disabled = true;
    try {
      if (f.get('pw') !== f.get('pw2')) throw new Error('確認用のパスワードが一致しません。');
      await changePassword(f.get('pw'));
      toast('パスワードを変更しました');
      onDone();
    } catch (err) { showError(err, '初回のパスワード変更'); btn.disabled = false; }
  };
}
