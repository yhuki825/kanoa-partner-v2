// 求職者の登録・編集（保存したら、新規は一覧へ・編集は詳細へ戻る）
import { register, navigate } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc } from '../../ui/format.js';
import { toast, showError, busy } from '../../ui/components.js';
import { userError, updateRow } from '../../ui/db.js';
import { uploadCandidateFile, ACCEPT } from '../../ui/files.js';
import { GENDERS, EDUCATIONS, EMPLOYMENT_TYPES, PREFECTURES } from '../../ui/candidate-fields.js';

const opt = (list, v) => `<option value="">選択してください</option>` +
  list.map((x) => `<option ${x === v ? 'selected' : ''}>${esc(x)}</option>`).join('');
const triOpt = (v) => `
  <option value="" ${v == null ? 'selected' : ''}>未確認</option>
  <option value="true" ${v === true ? 'selected' : ''}>可</option>
  <option value="false" ${v === false ? 'selected' : ''}>不可</option>`;

async function render(el, params) {
  const editing = !!params.id;
  let c = {};
  let note = null;
  if (editing) {
    const { data, error } = await sb().from('v2_candidates').select('*').eq('id', params.id).maybeSingle();
    if (error) throw userError(error, '求職者を読み込めませんでした');
    if (!data) { el.innerHTML = '<div class="empty">この求職者は見つからないか、見る権限がありません。</div>'; return; }
    c = data;
    const { data: n } = await sb().from('v2_candidate_notes').select('*').eq('candidate_id', c.id).maybeSingle();
    note = n;
  }
  // 担当の候補: 自社のメンバー（RAはRA）
  let mq = sb().from('v2_members').select('id,name,login_id').eq('status', 'active').order('login_id');
  mq = S.role === 'ra' ? mq.eq('role', 'ra') : mq.eq('company_id', S.company.id);
  const { data: members, error: me } = await mq;
  if (me) throw userError(me, '担当の候補を読み込めませんでした');
  const assigned = c.assigned_member_id || (editing ? '' : S.member.id);

  document.getElementById('view-title').textContent = editing ? `求職者の編集：${c.name}` : '求職者の登録';
  el.innerHTML = `
    <form class="card form-grid" novalidate>
      <h2 class="span2">基本情報</h2>
      <div class="field"><label for="f-name">候補者名 <em>必須</em></label><input id="f-name" name="name" required value="${esc(c.name || '')}" autocomplete="off"></div>
      <div class="field"><label for="f-kana">ふりがな</label><input id="f-kana" name="kana" value="${esc(c.kana || '')}" autocomplete="off"></div>
      <div class="field"><label for="f-birth">生年月日</label><input id="f-birth" name="birth_date" type="date" value="${esc(c.birth_date || '')}"></div>
      <div class="field"><label for="f-gender">性別</label><select id="f-gender" name="gender">${opt(GENDERS, c.gender)}</select></div>
      <div class="field"><label for="f-edu">最終学歴</label><select id="f-edu" name="education">${opt(EDUCATIONS, c.education)}</select></div>
      <div class="field"><label for="f-jobs">就業経験社数</label><input id="f-jobs" name="job_changes" type="number" min="0" max="99" inputmode="numeric" value="${c.job_changes ?? ''}"></div>
      <div class="field"><label for="f-emp">現在の雇用形態</label><select id="f-emp" name="employment_type">${opt(EMPLOYMENT_TYPES, c.employment_type)}</select></div>
      <div class="field"><label for="f-inc">直近の年収（万円）</label><input id="f-inc" name="current_income" type="number" min="0" inputmode="numeric" value="${c.current_income ?? ''}"></div>
      <div class="field"><label for="f-pref">現住所（都道府県）</label><select id="f-pref" name="prefecture">${opt(PREFECTURES, c.prefecture)}</select></div>
      <div class="field"><label for="f-assign">担当</label><select id="f-assign" name="assigned_member_id">
        <option value="">未設定</option>${members.map((m) => `<option value="${m.id}" ${m.id === assigned ? 'selected' : ''}>${esc(m.name)}${m.login_id ? `（${esc(m.login_id)}）` : ''}</option>`).join('')}</select></div>

      <h2 class="span2">連絡先</h2>
      <div class="field"><label for="f-mail">メールアドレス</label><input id="f-mail" name="email" type="email" value="${esc(c.email || '')}" autocomplete="off"></div>
      <div class="field"><label for="f-tel">電話番号</label><input id="f-tel" name="phone" type="tel" value="${esc(c.phone || '')}" autocomplete="off">
        <small class="sub">同じ電話番号の求職者は二重に登録できません。</small></div>

      <h2 class="span2">希望条件</h2>
      <div class="field span2"><label for="f-loc">希望勤務地</label><input id="f-loc" name="desired_location" value="${esc(c.desired_location || '')}" placeholder="例：東京都23区、神奈川県"></div>
      <div class="field"><label for="f-travel">出張</label><select id="f-travel" name="travel_ok">${triOpt(c.travel_ok)}</select></div>
      <div class="field"><label for="f-reloc">転勤</label><select id="f-reloc" name="relocation_ok">${triOpt(c.relocation_ok)}</select></div>
      <div class="field"><label for="f-dinc">希望年収（万円）</label><input id="f-dinc" name="desired_income" type="number" min="0" inputmode="numeric" value="${c.desired_income ?? ''}"></div>

      <h2 class="span2">推薦文・メモ</h2>
      <div class="field span2"><label for="f-rec">推薦文 <small class="sub">（応募するとアップラインにも届きます）</small></label><textarea id="f-rec" name="recommendation" rows="5">${esc(c.recommendation || '')}</textarea></div>
      <div class="field span2"><label for="f-memo">メモ <small class="sub">（${S.role === 'ra' ? 'KANOAの中だけ' : '自社の中だけ'}で見えます）</small></label><textarea id="f-memo" name="memo" rows="3">${esc(note?.memo || '')}</textarea></div>

      ${editing ? '' : `
      <h2 class="span2">書類</h2>
      <div class="field"><label for="f-resume">履歴書</label><input id="f-resume" name="resume" type="file" accept="${ACCEPT}"></div>
      <div class="field"><label for="f-cv">職務経歴書</label><input id="f-cv" name="cv" type="file" accept="${ACCEPT}"></div>`}

      <div class="form-actions span2">
        <a class="btn" href="${editing ? `#/candidate?id=${c.id}` : '#/candidates'}">キャンセル</a>
        <button class="btn btn-primary">保存</button>
      </div>
    </form>`;

  const form = el.querySelector('form');
  form.onsubmit = (e) => { e.preventDefault(); busy(form.querySelector('.btn-primary'), async () => {
    const f = new FormData(form);
    const s = (k) => { const v = String(f.get(k) ?? '').trim(); return v || null; };
    const n = (k) => { const v = s(k); return v == null ? null : Number(v); };
    const b = (k) => { const v = s(k); return v == null ? null : v === 'true'; };
    if (!s('name')) { showError(new Error('候補者名を入力してください。'), '求職者の保存'); return; }
    const values = {
      name: s('name'), kana: s('kana'), birth_date: s('birth_date'), gender: s('gender'),
      education: s('education'), job_changes: n('job_changes'), employment_type: s('employment_type'),
      current_income: n('current_income'), prefecture: s('prefecture'), email: s('email'), phone: s('phone'),
      desired_location: s('desired_location'), travel_ok: b('travel_ok'), relocation_ok: b('relocation_ok'),
      desired_income: n('desired_income'), recommendation: s('recommendation'),
      assigned_member_id: s('assigned_member_id'),
    };
    let saved;
    try {
      if (editing) saved = await updateRow('v2_candidates', c, values);
      else {
        const { data, error } = await sb().from('v2_candidates').insert({
          ...values, owner_company_id: S.role === 'ra' ? null : S.company.id, created_by: S.member.id,
        }).select().single();
        if (error) {
          if (error.code === '23505') throw new Error('この電話番号の求職者はすでに登録されています。重複していないか確認してください。');
          throw userError(error, '求職者を保存できませんでした');
        }
        saved = data;
      }
    } catch (err) { showError(err, '求職者の保存'); return; }

    // メモ（自社の行）
    const memo = String(f.get('memo') || '');
    try {
      if (note) { if (memo !== note.memo) await updateRow('v2_candidate_notes', note, { memo }); }
      else if (memo) {
        const { error } = await sb().from('v2_candidate_notes').insert({
          candidate_id: saved.id, company_id: S.role === 'ra' ? null : S.company.id, memo });
        if (error) throw userError(error, 'メモを保存できませんでした');
      }
    } catch (err) { showError(err, 'メモの保存（求職者本体は保存済み）'); }

    // 書類（新規のみ。失敗しても求職者は保存済みなので、詳細から入れ直せる）
    if (!editing) {
      for (const kind of ['resume', 'cv']) {
        const file = form.querySelector(`[name="${kind}"]`).files[0];
        if (!file) continue;
        try { await uploadCandidateFile(saved.id, kind, file); }
        catch (err) { showError(err, '書類のアップロード（求職者は保存済み。詳細画面から入れ直せます）'); }
      }
    }
    toast('保存しました');
    navigate(editing ? `candidate?id=${saved.id}` : 'candidates');
  }); };
}

register('candidate-edit', { title: '求職者の登録', nav: false, navParent: 'candidates', render });
