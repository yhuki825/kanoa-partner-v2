// 求人: RA=一覧・登録・編集／CA=求人検索（自社に提示された求人だけ）
// 詳細は別タブで開く（画面遷移図）
import { register, setTopbarActions, navigate } from '../../router.js';
import { sb } from '../../supabase.js';
import { S } from '../../store.js';
import { esc, fmtYen } from '../../ui/format.js';
import { showError } from '../../ui/components.js';
import { userError } from '../../ui/db.js';
import { openJobEditor, JOB_STATUS } from './editor.js';

export function openJobTab(id) { window.open(`${location.pathname}#/job?id=${id}`, '_blank'); }

async function renderRA(el) {
  const a = setTopbarActions('<button class="btn btn-primary" id="j-new">求人を登録</button>');
  a.querySelector('#j-new').onclick = () => openJobEditor(null, () => render(el, {})).catch((e) => showError(e, '求人の登録'));
  const { data: jobs, error } = await sb().from('v2_jobs')
    .select('id,title,status,location,employment,updated_at,client:v2_clients!v2_jobs_client_id_fkey(name),v2_my_fee,shares:v2_job_shares!v2_job_shares_job_id_fkey(published)')
    .order('updated_at', { ascending: false }).limit(200);
  if (error) throw userError(error, '求人を読み込めませんでした');
  el.innerHTML = `<section class="card">
    ${jobs.length ? `<div class="table-wrap"><table class="table">
      <thead><tr><th>求人</th><th>求人企業</th><th>勤務地</th><th>状態</th><th>紹介料（基本額）</th><th>公開先</th><th></th></tr></thead>
      <tbody>${jobs.map((j) => `<tr>
        <td><a href="#" data-open="${j.id}"><b>${esc(j.title)}</b></a></td>
        <td>${esc(j.client?.name || '—')}</td><td>${esc(j.location || '—')}</td>
        <td><span class="tag st-${j.status}">${JOB_STATUS[j.status]}</span></td>
        <td>${j.v2_my_fee == null ? '未設定' : fmtYen(j.v2_my_fee)}</td>
        <td>${j.shares.filter((s) => s.published).length}社</td>
        <td><button class="btn btn-sm" data-edit="${j.id}">編集</button></td></tr>`).join('')}</tbody></table></div>`
    : '<div class="empty">まだ求人がありません。右上の「求人を登録」から登録できます。</div>'}</section>`;
  el.querySelectorAll('[data-open]').forEach((x) => { x.onclick = (e) => { e.preventDefault(); openJobTab(x.dataset.open); }; });
  el.querySelectorAll('[data-edit]').forEach((b) => {
    b.onclick = async () => {
      const { data: job, error: e2 } = await sb().from('v2_jobs').select('*').eq('id', b.dataset.edit).single();
      if (e2) { showError(userError(e2), '求人の編集'); return; }
      openJobEditor(job, () => render(el, {})).catch((e) => showError(e, '求人の編集'));
    };
  });
}

async function renderCA(el, params) {
  const { data: jobs, error } = await sb().from('v2_jobs')
    .select('id,title,description,location,employment,salary,status,client:v2_clients!v2_jobs_client_id_fkey(name),v2_my_fee')
    .eq('status', 'open').order('updated_at', { ascending: false }).limit(200);
  if (error) throw userError(error, '求人を読み込めませんでした');
  const q = (params.q || '').trim(), loc = params.loc || '', emp = params.emp || '';
  const uniq = (k) => [...new Set(jobs.map((j) => j[k]).filter(Boolean))].sort();
  const hit = jobs.filter((j) =>
    (!loc || j.location === loc) && (!emp || j.employment === emp) &&
    (!q || [j.title, j.description, j.location, j.salary, j.client?.name].some((v) => (v || '').includes(q))));
  el.innerHTML = `
    <section class="card">
      <form class="searchbar wrap" role="search">
        <label class="sr-only" for="jq">フリーワード</label>
        <input id="jq" name="q" value="${esc(q)}" placeholder="職種・会社名・業務内容など">
        <label class="sr-only" for="jloc">勤務地</label>
        <select id="jloc" name="loc"><option value="">勤務地：すべて</option>${uniq('location').map((v) => `<option ${v === loc ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select>
        <label class="sr-only" for="jemp">雇用形態</label>
        <select id="jemp" name="emp"><option value="">雇用形態：すべて</option>${uniq('employment').map((v) => `<option ${v === emp ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select>
        <button class="btn">検索</button>
      </form>
      <p class="count">募集中の求人 ${hit.length}件</p>
      ${hit.length ? `<div class="job-list">${hit.map((j) => `
        <button class="job-card" data-open="${j.id}">
          <span class="job-client">${esc(j.client?.name || '')}</span>
          <span class="job-title">${esc(j.title)}</span>
          <span class="job-meta">${[j.location, j.employment, j.salary].filter(Boolean).map(esc).join(' ／ ') || '—'}</span>
          <span class="job-fee">紹介料 ${j.v2_my_fee == null ? '未設定' : fmtYen(j.v2_my_fee)}</span>
        </button>`).join('')}</div>`
      : `<div class="empty">${jobs.length ? '条件に合う求人はありません。' : 'あなたの会社に提示されている求人はまだありません。'}</div>`}
    </section>`;
  el.querySelector('form').onsubmit = (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const p = new URLSearchParams({ q: f.get('q').trim(), loc: f.get('loc'), emp: f.get('emp') });
    [...p.keys()].forEach((k) => { if (!p.get(k)) p.delete(k); });
    navigate(`jobs${p.toString() ? `?${p}` : ''}`);
  };
  el.querySelectorAll('[data-open]').forEach((b) => { b.onclick = () => openJobTab(b.dataset.open); });
}

function render(el, params) { return S.role === 'ra' ? renderRA(el) : renderCA(el, params); }

register('jobs', { title: () => (S.role === 'ra' ? '求人' : '求人検索'), short: '求人', icon: 'search', order: 20, render });
