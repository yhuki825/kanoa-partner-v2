// ログイン画面（CA=ログインID／RA=メールアドレス）と、招待を受けた人の初回登録
import { login } from '../../auth.js';
import { callFn } from '../../supabase.js';
import { showError, toast } from '../../ui/components.js';

export function renderLogin(onSuccess) {
  const app = document.getElementById('app');
  let mode = 'login';   // 'login' | 'accept'

  function draw() {
    app.innerHTML = `
      <div class="login-wrap"><div class="login-box">
        <div class="logo"><b>KANOA Partner Portal</b><small>パートナー企業さま向け 選考管理システム</small></div>
        <div class="card">${mode === 'login' ? loginHtml() : acceptHtml()}</div>
      </div></div>`;
    const f = app.querySelector('form');
    f.onsubmit = submit;
    app.querySelector('[data-mode]').onclick = (e) => { e.preventDefault(); mode = e.target.dataset.mode; draw(); };
    f.querySelector('input')?.focus();
  }

  const loginHtml = () => `
    <form novalidate>
      <div class="field"><label for="lg-id">ログインID またはメールアドレス</label>
        <input id="lg-id" name="id" required autocomplete="username" autocapitalize="characters" placeholder="例：A00001-01"></div>
      <div class="field"><label for="lg-pw">パスワード</label>
        <input id="lg-pw" name="pw" type="password" required autocomplete="current-password"></div>
      <button class="btn btn-primary btn-block">ログイン</button>
    </form>
    <p class="login-sub">招待を受けてはじめて使う方は <a href="#" data-mode="accept">こちらから初回登録</a></p>`;

  const acceptHtml = () => `
    <form novalidate>
      <p class="hint">招待文に書かれた「企業コード」と「初期パスワード」を入力し、新しいパスワードを決めてください。</p>
      <div class="field"><label for="ac-code">企業コード</label><input id="ac-code" name="code" required autocapitalize="characters" autocomplete="off" placeholder="例：B00001"></div>
      <div class="field"><label for="ac-temp">初期パスワード（招待文に記載）</label><input id="ac-temp" name="temp" type="password" required autocomplete="off"></div>
      <div class="field"><label for="ac-name">あなたのお名前</label><input id="ac-name" name="name" required autocomplete="name"></div>
      <div class="field"><label for="ac-email">連絡用メールアドレス（任意）</label><input id="ac-email" name="email" type="email" autocomplete="email"></div>
      <div class="field"><label for="ac-pw">新しいパスワード（8文字以上）</label><input id="ac-pw" name="pw" type="password" required minlength="8" autocomplete="new-password"></div>
      <div class="field"><label for="ac-pw2">新しいパスワード（確認）</label><input id="ac-pw2" name="pw2" type="password" required autocomplete="new-password"></div>
      <button class="btn btn-primary btn-block">登録してはじめる</button>
    </form>
    <p class="login-sub"><a href="#" data-mode="login">ログイン画面に戻る</a></p>`;

  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.target);
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      if (mode === 'login') {
        if (!f.get('id') || !f.get('pw')) throw new Error('IDとパスワードを入力してください。');
        await login(f.get('id'), f.get('pw'));
      } else {
        if (!f.get('code') || !f.get('temp') || !f.get('name')) throw new Error('企業コード・初期パスワード・お名前を入力してください。');
        if (String(f.get('pw')).length < 8) throw new Error('新しいパスワードは8文字以上にしてください。');
        if (f.get('pw') !== f.get('pw2')) throw new Error('確認用のパスワードが一致しません。');
        const res = await callFn('v2-invite-accept', {
          code: f.get('code'), temp_pw: f.get('temp'), new_pw: f.get('pw'),
          name: f.get('name'), email: f.get('email'),
        });
        await login(res.login_id, f.get('pw'));
        alert(`登録が完了しました。\n\nあなたのログインIDは「${res.login_id}」です。\n次回からはこのIDでログインしてください。`);
        toast('ようこそ');
      }
      onSuccess();
    } catch (err) {
      showError(err, mode === 'login' ? 'ログイン' : '初回登録');
      btn.disabled = false;
    }
  }

  draw();
}
