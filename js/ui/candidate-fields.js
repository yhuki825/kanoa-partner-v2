// 求職者の項目定義（登録画面・詳細・求人の「エントリー時必須項目」で共通に使う）
export const GENDERS = ['男性', '女性', 'その他', '回答しない'];
export const EDUCATIONS = ['中学校', '高等学校', '専門学校', '高等専門学校', '短期大学', '大学', '大学院', 'その他'];
export const EMPLOYMENT_TYPES = ['正社員', '契約社員', '派遣社員', 'パート・アルバイト', '業務委託', '無職', '学生', 'その他'];
export const PREFECTURES = ['北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県','新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県','鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県'];

// key = v2_candidates の列名（書類は resume / cv）
export const CANDIDATE_FIELDS = [
  { key: 'name', label: '候補者名', always: true },
  { key: 'kana', label: 'ふりがな' },
  { key: 'birth_date', label: '生年月日' },
  { key: 'gender', label: '性別' },
  { key: 'education', label: '最終学歴' },
  { key: 'job_changes', label: '就業経験社数' },
  { key: 'employment_type', label: '現在の雇用形態' },
  { key: 'current_income', label: '直近の年収' },
  { key: 'prefecture', label: '現住所（都道府県）' },
  { key: 'email', label: 'メールアドレス' },
  { key: 'phone', label: '電話番号' },
  { key: 'desired_location', label: '希望勤務地' },
  { key: 'travel_ok', label: '出張の可否' },
  { key: 'relocation_ok', label: '転勤の可否' },
  { key: 'desired_income', label: '希望年収' },
  { key: 'recommendation', label: '推薦文' },
  { key: 'resume', label: '履歴書', file: true },
  { key: 'cv', label: '職務経歴書', file: true },
];
export const fieldLabel = (key) => CANDIDATE_FIELDS.find((f) => f.key === key)?.label || key;

export const FILE_KINDS = [
  { kind: 'resume', label: '履歴書' },
  { kind: 'cv', label: '職務経歴書' },
  { kind: 'offer_1', label: '内定承諾資料1' },   // 表示名は伏せ、保存値で区別（V1の方針）
  { kind: 'offer_2', label: '内定承諾資料2' },
  { kind: 'offer_3', label: '内定承諾資料3' },
  { kind: 'other', label: 'その他の書類' },
];
export const fileLabel = (kind) => FILE_KINDS.find((k) => k.kind === kind)?.label || kind;

export function yesNo(v) { return v === true ? '可' : v === false ? '不可' : '未確認'; }
