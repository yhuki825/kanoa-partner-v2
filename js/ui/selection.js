// 選考の表示部品（一覧・詳細・求職者詳細で共通）
import { esc } from './format.js';
import { S } from '../store.js';

function md(d) { if (!d) return ''; const x = new Date(d); return `${x.getMonth() + 1}/${x.getDate()}`; }

// 状態の表示名（見る人の立場で変わる）
export function stageLabel(a) {
  const ms = a.milestones || [];
  if (a.stage === 'relay') {
    if (a.waiting_me) return { text: S.role === 'ra' ? '受入待ち' : '判断待ち', cls: 'st-wait' };
    if (a.holder_is_kanoa) return { text: 'KANOA確認待ち', cls: 'st-relay' };
    return { text: 'アップラインで確認中', cls: 'st-relay' };
  }
  if (a.stage === 'active') {
    const cur = ms.find((m) => m.result === 'pending');
    return { text: cur ? `選考中（${cur.name}）` : '選考中', cls: 'st-active' };
  }
  if (a.stage === 'rejected') return { text: '見送り', cls: 'st-closed' };
  if (a.stage === 'withdrawn') return { text: '辞退', cls: 'st-closed' };
  if (a.result === 'failed') {
    const f = ms.find((m) => m.result === 'failed');
    return { text: `不通過${f ? `（${f.name}）` : ''}`, cls: 'st-closed' };
  }
  return { text: `完了${ms.length ? `（${ms[ms.length - 1].name}）` : ''}`, cls: 'st-done' };
}

export function stageTag(a) { const s = stageLabel(a); return `<span class="tag ${s.cls}">${esc(s.text)}</span>`; }

// 選考フローの進み具合（各段階と日付）
export function milestoneChips(ms) {
  if (!ms?.length) return '<span class="sub">—</span>';
  return `<ol class="ms-chips">${ms.map((m) => {
    const mark = m.result === 'passed' ? '○' : m.result === 'failed' ? '×' : '・';
    const d = md(m.done_on || m.scheduled_on);
    return `<li class="ms-${m.result}" title="${esc(m.name)}${d ? ` ${d}` : ''}"><span class="ms-mark" aria-hidden="true">${mark}</span>${esc(m.name)}${d ? `<small>${d}</small>` : ''}</li>`;
  }).join('')}</ol>`;
}

export const RESULT_LABEL = { pending: '未定', passed: '通過', failed: '不通過' };
export const EVENT_LABEL = {
  applied: '応募', forwarded: '送客', rejected: '見送り', accepted: '受入',
  withdrawn: '辞退', registered_external: '外部求人に応募（URL登録）', milestone: '選考の進み具合を更新',
};
