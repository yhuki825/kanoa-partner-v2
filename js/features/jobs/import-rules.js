// 求人のCSV一括登録: CSVの読み取りと、1行＝1求人の形への変換（DBにも画面部品にも触れない。node でも確かめられる）
// 登録してよいかの最終的な確認（必須・重複・公開先の会社コード・返金規定など）は DB の v2_jobs_import が行う
import { CANDIDATE_FIELDS } from '../../ui/candidate-fields.js';

// CSVの列（見出しの文言 → 項目）。ひな形もこの順で作る
export const IMPORT_COLUMNS = [
  { key: 'client', label: '求人企業', required: true, example: '（例）株式会社サンプル', note: '必須。名前が同じ求人企業があればそれを使い、無ければ新しく作ります' },
  { key: 'title', label: '求人名・職種', required: true, example: '法人営業（例）', note: '必須' },
  { key: 'description', label: '業務内容', example: '既存顧客への提案営業', note: '' },
  { key: 'location', label: '勤務地', example: '東京都', note: '' },
  { key: 'employment', label: '雇用形態', example: '正社員', note: '' },
  { key: 'salary', label: '給与', example: '月給25万円〜', note: '' },
  { key: 'status', label: '状態', example: '募集中', note: '「募集中」「一時停止」「終了」。空欄は「募集中」' },
  { key: 'conditions', label: 'その他の条件', example: '', note: '' },
  { key: 'flow', label: '選考フロー', example: '書類選考／一次面接／二次面接／最終面接／内定／入社', note: '段階を「／」で区切る（セル内の改行でも可）。空欄は標準の6段階' },
  { key: 'entry_requirements', label: 'エントリー時必須項目', example: '電話番号／履歴書', note: '項目名を「／」で区切る。候補者名は常に必須' },
  { key: 'spi', label: 'SPI', example: '', note: '「○」で有り。空欄は無し' },
  { key: 'compliance', label: 'コンプライアンスチェック', example: '○', note: '「○」で有り。空欄は無し' },
  { key: 'fee', label: '紹介料（基本額・円）', example: '300000', note: 'KANOA→1次パートナー。税抜・半角数字（カンマ可）。空欄は未設定' },
  { key: 'client_fee', label: '求人企業からの紹介料（円）', example: '350000', note: '求人企業→KANOA（KANOAだけが見られる）。税抜・半角数字。空欄は未設定' },
  { key: 'shares', label: '公開先', example: '全社', note: '「全社」＝1次パートナー全社。会社コードを「／」で区切っても可。空欄は非公開' },
  { key: 'refund', label: '返金規定', example: '1か月以内100%／3か月以内50%', note: '「◯か月以内◯%」を「／」で区切る。空欄は返金なし' },
];

const SEP = /[／/、,\n]+/;
const nfkc = (s) => String(s ?? '').normalize('NFKC');
const splitList = (s) => String(s ?? '').split(SEP).map((x) => x.trim()).filter(Boolean);

// ファイルの中身（バイト）を文字に。UTF-8（BOM付きも）で読めなければ、Excelの日本語の既定（Shift_JIS）で読む
export function decodeCsvBytes(buf) {
  let bytes = new Uint8Array(buf);
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) bytes = bytes.subarray(3);
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { /* Shift_JIS で読み直す */ }
  return new TextDecoder('shift_jis').decode(bytes);
}

// CSV（RFC 4180）: "" の中のカンマ・改行・"" を扱う。戻り値は [{ line, cells }]
// line は表計算ソフトの行番号（セル内の改行は数えない。空行も1行と数える）
export function parseCsv(text) {
  const out = [];
  let cells = [], cur = '', q = false;
  const s = String(text).replace(/^﻿/, '');
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) {
      if (ch === '"') { if (s[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += ch;
    } else if (ch === '"') q = true;
    else if (ch === ',') { cells.push(cur); cur = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && s[i + 1] === '\n') i++;
      cells.push(cur); out.push({ line: out.length + 1, cells }); cells = []; cur = '';
    } else cur += ch;
  }
  if (cur !== '' || cells.length) { cells.push(cur); out.push({ line: out.length + 1, cells }); }
  // 中身の無い行（空行・カンマだけの行）は除く
  return out.filter((r) => r.cells.some((c) => c.trim() !== ''));
}

const YES = new Set(['○', '〇', '◯', 'o', 'O', 'はい', '有', '有り', 'あり', '1', 'true', 'TRUE', 'yes', 'Yes', 'YES']);
const NO = new Set(['', '×', '✕', 'x', 'X', 'いいえ', '無', '無し', 'なし', '0', 'false', 'FALSE', 'no', 'No', 'NO', '-', '－']);

// 表（parseCsv の結果）→ 1行＝1求人の形。見出しの誤りはファイル全体の誤り（fileErrors）
export function rowsToJobs(table) {
  if (!table.length) return { fileErrors: ['CSVが空です'], rows: [] };
  const head = table[0].cells.map((h) => nfkc(h).replace(/\s+/g, '').trim());
  const norm = (l) => nfkc(l).replace(/\s+/g, '');
  const idx = {};
  const unknown = [];
  head.forEach((h, i) => {
    if (!h) return;
    const col = IMPORT_COLUMNS.find((c) => norm(c.label) === h);
    if (col) idx[col.key] = i; else unknown.push(table[0].cells[i].trim());
  });
  const fileErrors = [];
  const missing = IMPORT_COLUMNS.filter((c) => c.required && idx[c.key] == null).map((c) => c.label);
  if (missing.length) fileErrors.push(`見出しの行に「${missing.join('」「')}」がありません（ひな形の1行目をそのまま使ってください）`);
  if (unknown.length) fileErrors.push(`知らない見出しがあります：「${unknown.join('」「')}」（ひな形の見出しと同じ文言にしてください）`);
  if (fileErrors.length) return { fileErrors, rows: [] };

  const reqByLabel = Object.fromEntries(CANDIDATE_FIELDS.map((f) => [norm(f.label), f.key]));
  const rows = table.slice(1).map(({ line, cells }) => {
    const get = (k) => (idx[k] == null ? '' : String(cells[idx[k]] ?? '')).trim();
    const errors = [];
    const yesNo = (k, label) => {
      const v = nfkc(get(k)).trim();
      if (YES.has(v)) return true;
      if (NO.has(v)) return false;
      errors.push(`${label}は「○」か空欄にしてください（${get(k)}）`); return false;
    };
    // 紹介料: 半角・全角の数字、カンマ・円・¥ は許す
    let fee = null;
    const feeRaw = nfkc(get('fee')).replace(/[,\s円¥￥]/g, '');
    if (feeRaw !== '') {
      if (/^\d+$/.test(feeRaw)) fee = Number(feeRaw);
      else errors.push(`紹介料は半角数字で入れてください（${get('fee')}）`);
    }
    let clientFee = null;
    const cfRaw = nfkc(get('client_fee')).replace(/[,\s円¥￥]/g, '');
    if (cfRaw !== '') {
      if (/^\d+$/.test(cfRaw)) clientFee = Number(cfRaw);
      else errors.push(`求人企業からの紹介料は半角数字で入れてください（${get('client_fee')}）`);
    }
    // 返金規定: 「1か月以内100%」「3ヶ月 50％」「1:100」など
    const refund = [];
    for (const part of splitList(nfkc(get('refund')))) {
      const m = /^(\d+)\s*(?:か月|ヶ月|ケ月|カ月|ヵ月|月)?\s*(?:以内)?\s*[:：\s]?\s*(\d+)\s*%?$/.exec(part);
      if (m) refund.push({ months: Number(m[1]), rate: Number(m[2]) });
      else errors.push(`返金規定の書き方が読めません（${part}）。「1か月以内100%」のように書いてください`);
    }
    // エントリー時必須項目: 項目名 → 項目のキー
    const reqs = [];
    for (const label of splitList(get('entry_requirements'))) {
      const key = reqByLabel[norm(label)];
      if (key) reqs.push(key); else errors.push(`エントリー時必須項目に知らない項目があります（${label}）`);
    }
    const sharesRaw = get('shares');
    const shares = ['全社', '全て', 'すべて', 'all', 'ALL'].includes(nfkc(sharesRaw).trim()) ? 'all' : splitList(nfkc(sharesRaw)).map((c) => c.toUpperCase());
    return {
      line,
      client: get('client'), title: get('title'), description: get('description'), location: get('location'),
      employment: get('employment'), salary: get('salary'), status: get('status'), conditions: get('conditions'),
      flow: splitList(get('flow')),
      entry_requirements: reqs,
      spi: yesNo('spi', 'SPI'), compliance: yesNo('compliance', 'コンプライアンスチェック'),
      fee, client_fee: clientFee, shares, refund, errors,
    };
  });
  if (!rows.length) return { fileErrors: ['見出しの下に求人の行がありません'], rows: [] };
  if (rows.length > 500) return { fileErrors: [`行が多すぎます（${rows.length}行）。500行までに分けてください`], rows: [] };
  return { fileErrors: [], rows };
}

// ひな形（Excelで文字化けしないよう UTF-8 の BOM 付き・改行は CRLF）
export function templateCsv() {
  const cell = (v) => (/[",\n\r]/.test(v) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  const lines = [IMPORT_COLUMNS.map((c) => cell(c.label)).join(','), IMPORT_COLUMNS.map((c) => cell(c.example)).join(',')];
  return `﻿${lines.join('\r\n')}\r\n`;
}
