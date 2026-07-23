// ログイン画面（パートナー／KANOA管理者／招待の受諾）
import { adminLogin, partnerLogin, partnerAccept } from '../../auth.js';
import { toast } from '../../ui/components.js';
import { esc } from '../../ui/format.js';

export function renderLogin(onSuccess) {
  const app = document.getElementById('app');
  let tab = 'partner';   // 'partner' | 'kanoa' | 'accept'

  function draw() {
    app.innerHTML = `
      <div class="login-wrap"><div class="login-box">
        <div class="logo"><b>KANOA Partner Portal</b><small>パートナー企業さま向け 送客管理システム</small></div>
        <div class="card">
          <div class="login-tabs">
            <button data-tab="partner" class="${tab === 'partner' ? 'active' : ''}">パートナー</button>
            <button data-tab="kanoa" class="${tab === 'kanoa' ? 'active' : ''}">KANOA管理</button>
          </div>
          <form id="login-form">${formHtml()}</form>
          ${tab === 'partner' ? `<p style="margin-top:14px;text-align:center;font-size:12.5px">
            はじめての方（招待コードをお持ちの方）は <a href="#" id="to-accept">こちらから初回登録</a></p>` : ''}
          ${tab === 'accept' ? `<p style="margin-top:14px;text-align:center;font-size:12.5px">
            <a href="#" id="to-partner">通常のログインに戻る</a></p>` : ''}
        </div>
      </div></div>`;

    app.querySelectorAll('[data-tab]').forEach((b) => {
      b.onclick = () => { tab = b.dataset.tab; draw(); };
    });
    const toAccept = app.querySelector('#to-accept');
    if (toAccept) toAccept.onclick = (e) => { e.preventDefault(); tab = 'accept'; draw(); };
    const toPartner = app.querySelector('#to-partner');
    if (toPartner) toPartner.onclick = (e) => { e.preventDefault(); tab = 'partner'; draw(); };

    document.getElementById('login-form').onsubmit = submit;
  }

  function formHtml() {
    if (tab === 'kanoa') return `
      <div class="field"><label>メールアドレス</label><input name="email" type="email" required autocomplete="username"></div>
      <div class="field"><label>パスワード</label><input name="pw" type="password" required autocomplete="current-password"></div>
      <button class="btn btn-primary btn-block">ログイン</button>`;
    if (tab === 'accept') return `
      <p style="font-size:12.5px;color:var(--c-text-sub);margin-bottom:12px">
        招待文に記載の「企業コード」と「初期パスワード」を入力し、新しいパスワードを設定してください。</p>
      <div class="field"><label>企業コード（例: B00001）</label><input name="code" required autocapitalize="characters" autocomplete="off"></div>
      <div class="field"><label>初期パスワード（招待文に記載）</label><input name="tempPw" type="password" required autocomplete="off"></div>
      <div class="field"><label>新しいパスワード（8文字以上）</label><input name="newPw" type="password" required minlength="8" autocomplete="new-password"></div>
      <div class="field"><label>ご担当者名</label><input name="contact" required></div>
      <div class="field"><label>メールアドレス</label><input name="email" type="email"></div>
      <div class="field"><label>電話番号</label><input name="phone" type="tel"></div>
      <button class="btn btn-primary btn-block">登録してはじめる</button>`;
    return `
      <div class="field"><label>企業コード（例: A00001）</label><input name="code" required autocapitalize="characters" autocomplete="username"></div>
      <div class="field"><label>パスワード</label><input name="pw" type="password" required autocomplete="current-password"></div>
      <button class="btn btn-primary btn-block">ログイン</button>`;
  }

  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.target);
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      if (tab === 'kanoa') {
        await adminLogin(f.get('email'), f.get('pw'));
      } else if (tab === 'accept') {
        await partnerAccept({
          code: f.get('code'), tempPw: f.get('tempPw'), newPw: f.get('newPw'),
          contact: f.get('contact'), email: f.get('email'), phone: f.get('phone'),
        });
        toast('登録が完了しました。ようこそ！', 'ok');
      } else {
        const res = await partnerLogin(f.get('code'), f.get('pw'));
        if (res.must_change_pw) toast('パスワードの変更をおすすめします（設定画面から変更できます）');
      }
      onSuccess();
    } catch (err) {
      toast(err.message || 'ログインに失敗しました', 'err');
      btn.disabled = false;
    }
  }

  draw();
}
