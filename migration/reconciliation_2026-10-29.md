# V1 → V2 移行 照合レポート（お試し移行）2026-10-29

件数と金額だけを載せています（氏名・連絡先などの個人情報は載せていません）。V1 の ID は照合のためにそのまま載せています。
生成: 2026-10-29T07:27:38.450809+00:00 ／ 入社の扱い: V1 の入社日が 2026-10-29 以前なら「入社」 ／ 代表CA: 停止（お試し中は V2 にログインできない）

## 1. 照合（V1 と V2）

| 項目 | V1 | V2 | 一致 | 補足 |
|---|---:|---:|:-:|---|
| 会社（agencies → v2_companies） | 24 | 24 | ○ | V1 全 27 社のうち 3 社は対象外（決定5: KA999・RE999、2026-10-29: PT000） |
| 代表CA（V1 のログイン用アカウントがある会社 → v2_members） | 24 | 24 | ○ | 会社コード経由で数えた。状態: suspended 24 |
| 求人（projects → v2_jobs） | 4 | 4 | ○ | 求人企業 2 社に集約 |
| 紹介料の合計（success_reward → v2_job_kanoa_fees） | 2,854,714 | 2,854,714 | ○ | 円・税抜 |
| 求人企業からの紹介料の合計（client_fee → v2_job_client_fees・KANOAだけが見られる） | 2,366,062 | 2,366,062 | ○ | 円・税抜（2026-10-29 決定） |
| 公開（assignments → v2_job_shares） | 96 | 96 | ○ | 対象外の会社の 12 行を除く |
| 　うち公開中 | 24 | 24 | ○ |  |
| 会社ごとの紹介料の上書き合計（suc_override → fee_override） | 0 | 0 | ○ | 円 |
| 求職者（referrals → v2_candidates） | 233 | 233 | ○ | 対象外の会社の 1 件を除く |
| 選考（referrals → v2_applications） | 233 | 233 | ○ | 状態の対応は 3 章 |
| 紹介フォームの確認待ち → 新しい求職者（選考なし） | 2 | 2 | ○ | V1 の確認待ち 3 件のうち、同じ会社に電話番号が同じ送客がある 1 件を除いた数（V1 の表だけで計算） |
| 　同じ人の送客がある確認待ち → その求職者にメモと添付を統合 | 1 | 1 | ○ | 電話番号の重複を防ぐ制約のため、2人目は作らない |
| 書類の行（documents → v2_candidate_files） | 490 | 490 | ○ |  |
| 書類の大きさ合計（documents.size → v2_candidate_files.size） | 237,117,380 | 237,117,380 | ○ | バイト |
| 書類の行（紹介フォームの添付を含む全体） | 492 | 492 | ○ | V2 の行数 ／ v2-files に実物がある数 |
| 書類の実物の大きさ合計（v2-files） | 237,395,288 | 237,395,288 | ○ | バイト。大きさの不一致 0 件 |
| 連絡（ref_id あり → 選考のチャット） | 1,711 | 1,711 | ○ |  |
| 　KANOA の送信（sender=kanoa → side=up） | 716 | 716 | ○ |  |
| 　パートナーの送信（sender=agency → side=self） | 995 | 995 | ○ |  |
| 会社単位の連絡（ref_id なし → CSV） | 22 | 22 | ○ | 決定3。migration/exports/v1_company_messages.csv（Git 対象外） |
| お知らせ | 4 | 4 | ○ |  |
| 報酬の件数（入社 → v2_rewards） | 1 | 1 | ○ | V1 で入社日が入っているのは 3 件（5 章） |
| 報酬の金額合計（税抜） | 916,062 | 916,062 | ○ | 円。すべて支払待ち（V1 に支払の記録なし） |
| 求人の文章に紹介料・返金の語（全パートナーに読める項目。0 であること） | 0 | 0 | ○ | 求人名・業務内容・その他の条件・付帯情報を検査 |

### 会社ごと（会社コード経由。移行の記録を通さずに数えた）

| V2 企業コード | V1 送客 | V2 選考 | 一致 | V1 送客＋確認待ち（重複除く） | V2 求職者 | 一致 |
|---|---:|---:|:-:|---:|---:|:-:|
| A00001 | 42 | 42 | ○ | 42 | 42 | ○ |
| A00002 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00003 | 60 | 60 | ○ | 60 | 60 | ○ |
| A00004 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00005 | 53 | 53 | ○ | 53 | 53 | ○ |
| A00006 | 11 | 11 | ○ | 11 | 11 | ○ |
| A00007 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00008 | 39 | 39 | ○ | 39 | 39 | ○ |
| A00009 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00010 | 2 | 2 | ○ | 2 | 2 | ○ |
| A00011 | 1 | 1 | ○ | 2 | 2 | ○ |
| A00012 | 4 | 4 | ○ | 4 | 4 | ○ |
| A00013 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00014 | 3 | 3 | ○ | 3 | 3 | ○ |
| A00015 | 4 | 4 | ○ | 4 | 4 | ○ |
| A00016 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00017 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00018 | 0 | 0 | ○ | 1 | 1 | ○ |
| A00019 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00021 | 3 | 3 | ○ | 3 | 3 | ○ |
| A00022 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00023 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00024 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00025 | 9 | 9 | ○ | 9 | 9 | ○ |

## 2. V1 の全行の行き先（移した／意図して移さない／止まった）

| V1 の表 | V1 行数 | 移した | 移さない | 止まった | 未確認 |
|---|---:|---:|---:|---:|---:|
| agency | 27 | 24 | 3 | 0 | 0 |
| project | 4 | 4 | 0 | 0 | 0 |
| assignment | 108 | 96 | 12 | 0 | 0 |
| referral | 234 | 233 | 1 | 0 | 0 |
| intake | 107 | 3 | 104 | 0 | 0 |
| document | 492 | 490 | 2 | 0 | 0 |
| message | 1,739 | 1,711 | 28 | 0 | 0 |
| notice | 4 | 4 | 0 | 0 | 0 |
| reflog | 213 | 212 | 1 | 0 | 0 |
| task | 25 | 0 | 25 | 0 | 0 |
| tracker_link | 73 | 0 | 73 | 0 | 0 |

移さない理由: agency＝決定5（KA999・RE999）／assignment＝その2社の公開行／intake＝承認済み（すでに送客）・見送り（決定4）／message＝会社単位の連絡（決定3・CSV へ）／task・tracker_link＝設計で作らない機能。reflog（V1 の操作履歴）は選考の経路の記録へ移した。

移行の対象にしていない V1 の表（件数のみ）: login_logs・kanoa_admins（RA は 102 で登録済み）・invoices・subaccounts・members・「KANOA partner」

## 3. 選考の状態の対応（件数）

| V1 status | V1 fail_at | 入社日あり | V2 stage/result | 件数 |
|---|---|:-:|---|---:|
| declined | entry |  | withdrawn | 19 |
| declined | interview |  | withdrawn | 3 |
| declined | offer |  | withdrawn | 1 |
| declined | screening |  | withdrawn | 11 |
| declined | — |  | withdrawn | 2 |
| entry | — |  | NOT MIGRATED | 1 |
| entry | — |  | relay | 36 |
| joined | — | ○ | closed/passed | 1 |
| offer | — |  | active | 2 |
| offer | — | ○ | active | 2 |
| rejected | entry |  | rejected | 31 |
| rejected | interview |  | closed/failed | 32 |
| rejected | screening |  | closed/failed | 75 |
| rejected | — |  | rejected | 14 |
| screening | — |  | active | 4 |

V2 の状態別: active 8 ／ closed/failed 107 ／ closed/passed 1 ／ rejected 45 ／ relay 36 ／ withdrawn 36
／ 段階（v2_milestones）658 行 ／ 経路の記録 351 行

## 4. 止まった行・注意が要る行（理由）

| 種類 | V1 ID | 状態 | 理由 |
|---|---|---|---|
| agency | AG-00 | skipped | decision 5 (PT000: 2026-10-29): test/internal account (PT000) not migrated |
| agency | KANOA | skipped | decision 5 (PT000: 2026-10-29): test/internal account (KA999) not migrated |
| agency | RECORE | skipped | decision 5 (PT000: 2026-10-29): test/internal account (RE999) not migrated |
| document | 12cfdc9b-15e4-4e5a-8657-fe16ea867b70 | skipped | referral not migrated (R-r1qwt) |
| document | 68efcd63-a5f8-433c-9ad7-375954c360cf | skipped | referral not migrated (R-r1qwt) |
| intake | IK-mrojykwndefm | skipped | decision 4: approved, already a referral (R-b1zs3) - referral no longer exists in V1 |
| intake | IK-ms4ryzfxoi31 | skipped | decision 4: approved, already a referral (R-px5d6) - referral no longer exists in V1 |
| intake | IK-msfvk0eelojz | skipped | decision 4: approved, already a referral (R-id5tc) - referral no longer exists in V1 |
| intake | IK-mt2w1rh5gsm8 | migrated | merged into the candidate of V1 R-vj0rs (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| referral | R-9uyk3 | migrated | joined_on 2026-11-01 is after 2026-10-29: kept as offer (入社 scheduled) |
| referral | R-r1qwt | skipped | agency not migrated (AG-00) |
| referral | R-sp2f8 | migrated | joined_on 2026-12-01 is after 2026-10-29: kept as offer (入社 scheduled) |
| assignment | （12 行） | skipped | 対象外の会社（KA999・RE999）の公開行 |

## 5. 報酬

- 入社として移した: 1 件 ／ 合計 916,062 円（税抜）／ 支払待ち 1 件
- V1 で入社日が入っている送客は 3 件。V1 の status はすべて offer のまま。入社日が 2026-10-29 より後のものは「入社待ち」（最後の段階「入社」の予定日＝V1 の入社日）として移し、報酬はまだ作らない。その日を過ぎてから流し直すと報酬が作られる
- 返金規定を持つ求人: 1 件（V1 の文章から「◯か月以内 ◯%」を読み取り。経歴詐称の全額返金は V2 に項目が無いため対象外）
- V1 の client_fee（求人企業が KANOA に払う額）は、KANOA だけが見られる v2_job_client_fees に移した（2026-10-29 決定）。合計 2,366,062 円
- 対象外の会社（KA999・RE999・PT000）の分は移していない: 送客 1 件・書類 2 件・連絡 6 件
- V1 の文字のリアクション（「承知しました」など）は ✅ に置き換えた（2026-10-29 決定）
- V1 の送客報酬（referral_reward）合計 0 円・会社ごとの上書き（ref_override）0 件 → V2 に送客報酬は無い（設計書14）

## 6. 書類ファイルのコピー（candidate-docs → v2-files）

- コピー先の数 492 ／ 今回コピー {} ／ コピー済みで飛ばした 492 ／ 失敗 0
- V1 から消えた書類のコピーを消した 0（消すのはコピー済み台帳にあるものだけ） ／ 台帳に無いファイル（触らない）0
- v2-files に実物がある 492 件・237395288 バイト ／ 大きさの不一致 0 件
- V1 の置き場 candidate-docs: 650 件・328,808,784 バイト。うち documents から参照されていないもの 158 件（紹介フォームの添付の控え・削除済みの送客の書類など。移していない）

## 7. 連絡（チャット）

- 返信つき 18 ／ 編集済み 25 ／ リアクションつき 310（V1 の文字のリアクション「承知しました」等もそのまま）
- 既読: V1 の read をそのまま再現。未読として残るのは パートナー側 6 件・KANOA 側 0 件（スレッドの既読 464 行）

## 8. V1 は読むだけだったことの確認（実行の前後）

| V1 | 前 | 後 | 変化 |
|---|---:|---:|:-:|
| agencies | 27 | 27 | なし |
| projects | 4 | 4 | なし |
| assignments | 108 | 108 | なし |
| referrals | 234 | 234 | なし |
| documents | 492 | 492 | なし |
| intake | 107 | 107 | なし |
| messages | 1,739 | 1,739 | なし |
| notices | 4 | 4 | なし |
| tasks | 25 | 25 | なし |
| reflog | 213 | 213 | なし |
| tracker_links | 73 | 73 | なし |
| kanoa_admins | 1 | 1 | なし |
| candidate_docs_objects | 650 | 650 | なし |
| v1_auth_users | 26 | 26 | なし |

## 9. 実行の記録

```
{"purged": {"jobs": 4, "clients": 2, "members": 24, "notices": 4, "rewards": 1, "companies": 24, "candidates": 235, "applications": 233, "discarded_preview_edits": {}}, "joined_until": "2026-10-29", "members_active": false, "discard_preview_edits": false, "disabled_triggers_after_run": 0}
```
