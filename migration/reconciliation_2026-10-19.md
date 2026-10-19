# V1 → V2 移行 照合レポート（お試し移行）2026-10-19

件数と金額だけを載せています（氏名・連絡先などの個人情報は載せていません）。V1 の ID は照合のためにそのまま載せています。
生成: 2026-10-19T07:35:15.389038+00:00 ／ 入社の扱い: V1 の入社日が 2026-10-19 以前なら「入社」 ／ 代表CA: 停止（お試し中は V2 にログインできない）

## 1. 照合（V1 と V2）

| 項目 | V1 | V2 | 一致 | 補足 |
|---|---:|---:|:-:|---|
| 会社（agencies → v2_companies） | 25 | 25 | ○ | V1 全 27 社のうち 2 社は決定5で対象外 |
| 代表CA（V1 のログイン用アカウントがある会社 → v2_members） | 25 | 25 | ○ | 会社コード経由で数えた。状態: suspended 25 |
| 求人（projects → v2_jobs） | 4 | 4 | ○ | 求人企業 2 社に集約 |
| 紹介料の合計（success_reward → v2_job_kanoa_fees） | 2,854,714 | 2,854,714 | ○ | 円・税抜 |
| 公開（assignments → v2_job_shares） | 100 | 100 | ○ | 対象外の会社の 8 行を除く |
| 　うち公開中 | 25 | 25 | ○ |  |
| 会社ごとの紹介料の上書き合計（suc_override → fee_override） | 0 | 0 | ○ | 円 |
| 求職者（referrals → v2_candidates） | 230 | 230 | ○ |  |
| 選考（referrals → v2_applications） | 230 | 230 | ○ | 状態の対応は 3 章 |
| 紹介フォームの確認待ち → 新しい求職者（選考なし） | 4 | 4 | ○ | V1 の確認待ち 12 件のうち、同じ会社に電話番号が同じ送客がある 8 件を除いた数（V1 の表だけで計算） |
| 　同じ人の送客がある確認待ち → その求職者にメモと添付を統合 | 8 | 8 | ○ | 電話番号の重複を防ぐ制約のため、2人目は作らない |
| 書類の行（documents → v2_candidate_files） | 484 | 484 | ○ |  |
| 書類の大きさ合計（documents.size → v2_candidate_files.size） | 235,638,996 | 235,638,996 | ○ | バイト |
| 書類の行（紹介フォームの添付を含む全体） | 490 | 490 | ○ | V2 の行数 ／ v2-files に実物がある数 |
| 書類の実物の大きさ合計（v2-files） | 245,980,375 | 245,980,375 | ○ | バイト。大きさの不一致 0 件 |
| 連絡（ref_id あり → 選考のチャット） | 1,644 | 1,644 | ○ |  |
| 　KANOA の送信（sender=kanoa → side=up） | 685 | 685 | ○ |  |
| 　パートナーの送信（sender=agency → side=self） | 959 | 959 | ○ |  |
| 会社単位の連絡（ref_id なし → CSV） | 22 | 22 | ○ | 決定3。migration/exports/v1_company_messages.csv（Git 対象外） |
| お知らせ | 4 | 4 | ○ |  |
| 報酬の件数（入社 → v2_rewards） | 1 | 1 | ○ | V1 で入社日が入っているのは 3 件（5 章） |
| 報酬の金額合計（税抜） | 916,062 | 916,062 | ○ | 円。すべて支払待ち（V1 に支払の記録なし） |
| 求人の文章に紹介料・返金の語（全パートナーに読める項目。0 であること） | 0 | 0 | ○ | 求人名・業務内容・その他の条件・付帯情報を検査 |

### 会社ごと（会社コード経由。移行の記録を通さずに数えた）

| V2 企業コード | V1 送客 | V2 選考 | 一致 | V1 送客＋確認待ち（重複除く） | V2 求職者 | 一致 |
|---|---:|---:|:-:|---:|---:|:-:|
| A00001 | 41 | 41 | ○ | 42 | 42 | ○ |
| A00002 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00003 | 60 | 60 | ○ | 60 | 60 | ○ |
| A00004 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00005 | 51 | 51 | ○ | 52 | 52 | ○ |
| A00006 | 11 | 11 | ○ | 11 | 11 | ○ |
| A00007 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00008 | 39 | 39 | ○ | 39 | 39 | ○ |
| A00009 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00010 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00011 | 1 | 1 | ○ | 2 | 2 | ○ |
| A00012 | 4 | 4 | ○ | 4 | 4 | ○ |
| A00013 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00014 | 3 | 3 | ○ | 3 | 3 | ○ |
| A00015 | 4 | 4 | ○ | 4 | 4 | ○ |
| A00016 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00017 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00018 | 0 | 0 | ○ | 1 | 1 | ○ |
| A00019 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00020 | 1 | 1 | ○ | 1 | 1 | ○ |
| A00021 | 3 | 3 | ○ | 3 | 3 | ○ |
| A00022 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00023 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00024 | 0 | 0 | ○ | 0 | 0 | ○ |
| A00025 | 9 | 9 | ○ | 9 | 9 | ○ |

## 2. V1 の全行の行き先（移した／意図して移さない／止まった）

| V1 の表 | V1 行数 | 移した | 移さない | 止まった | 未確認 |
|---|---:|---:|---:|---:|---:|
| agency | 27 | 25 | 2 | 0 | 0 |
| project | 4 | 4 | 0 | 0 | 0 |
| assignment | 108 | 100 | 8 | 0 | 0 |
| referral | 230 | 230 | 0 | 0 | 0 |
| intake | 105 | 12 | 93 | 0 | 0 |
| document | 484 | 484 | 0 | 0 | 0 |
| message | 1,666 | 1,644 | 22 | 0 | 0 |
| notice | 4 | 4 | 0 | 0 | 0 |
| reflog | 205 | 205 | 0 | 0 | 0 |
| task | 25 | 0 | 25 | 0 | 0 |
| tracker_link | 73 | 0 | 73 | 0 | 0 |

移さない理由: agency＝決定5（KA999・RE999）／assignment＝その2社の公開行／intake＝承認済み（すでに送客）・見送り（決定4）／message＝会社単位の連絡（決定3・CSV へ）／task・tracker_link＝設計で作らない機能。reflog（V1 の操作履歴）は選考の経路の記録へ移した。

移行の対象にしていない V1 の表（件数のみ）: login_logs・kanoa_admins（RA は 102 で登録済み）・invoices・subaccounts・members・「KANOA partner」

## 3. 選考の状態の対応（件数）

| V1 status | V1 fail_at | 入社日あり | V2 stage/result | 件数 |
|---|---|:-:|---|---:|
| declined | entry |  | withdrawn | 17 |
| declined | interview |  | withdrawn | 2 |
| declined | offer |  | withdrawn | 1 |
| declined | screening |  | withdrawn | 9 |
| declined | — |  | withdrawn | 2 |
| entry | — |  | relay | 42 |
| interview | — |  | active | 4 |
| offer | — |  | active | 2 |
| offer | — | ○ | active | 2 |
| offer | — | ○ | closed/passed | 1 |
| rejected | entry |  | rejected | 25 |
| rejected | interview |  | closed/failed | 27 |
| rejected | screening |  | closed/failed | 74 |
| rejected | — |  | rejected | 14 |
| screening | — |  | active | 8 |

V2 の状態別: active 16 ／ closed/failed 101 ／ closed/passed 1 ／ rejected 39 ／ relay 42 ／ withdrawn 31
／ 段階（v2_milestones）651 行 ／ 経路の記録 343 行

## 4. 止まった行・注意が要る行（理由）

| 種類 | V1 ID | 状態 | 理由 |
|---|---|---|---|
| agency | KANOA | skipped | decision 5: test/internal account (KA999) not migrated |
| agency | RECORE | skipped | decision 5: test/internal account (RE999) not migrated |
| intake | IK-mrojykwndefm | skipped | decision 4: approved, already a referral (R-b1zs3) - referral no longer exists in V1 |
| intake | IK-ms4ryzfxoi31 | skipped | decision 4: approved, already a referral (R-px5d6) - referral no longer exists in V1 |
| intake | IK-ms5igg77z2aj | migrated | merged into the candidate of V1 R-nbtrm (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-ms5xvglyv984 | migrated | merged into the candidate of V1 R-jbcui (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-msfvk0eelojz | skipped | decision 4: approved, already a referral (R-id5tc) - referral no longer exists in V1 |
| intake | IK-msgy1cdpyfyk | migrated | merged into the candidate of V1 R-fx2ed (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-msgzcbzs30ax | migrated | merged into the candidate of V1 R-r1kkv (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-msgzqwhfimo3 | migrated | merged into the candidate of V1 R-9yid8 (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-msiofolq1b7z | migrated | merged into the candidate of V1 R-wbmkv (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-mt2sf6eos36u | migrated | merged into the candidate of V1 R-bz0xp (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake | IK-mt2w1rh5gsm8 | migrated | merged into the candidate of V1 R-vj0rs (same company, same phone; a 2nd candidate is blocked by v2_candidates_phone_uq) |
| intake_doc | IK-ms5igg77z2aj/3dc14808-9840-44fb-be40-76a6a43ecf9e | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-ms5igg77z2aj/f338ecd8-c4e3-41a3-8454-7f3b83e529ea | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-ms5xvglyv984/2142624f-36ec-49d1-93d9-17eabc02ffbd | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-ms5xvglyv984/506a293c-3223-4b3e-b33e-70b350ae585a | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgy1cdpyfyk/0c3fb70b-920b-46de-9028-61110bd85b89 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgy1cdpyfyk/d60f6213-05da-4c1e-8da0-49819837d39d | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgzcbzs30ax/407212ae-960e-4bc9-92b5-7297de540eb8 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgzcbzs30ax/d2659e1e-258b-4471-a6e0-052dd25f2eb5 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgzqwhfimo3/285befb1-8b6d-4535-91a9-962cb4481be2 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msgzqwhfimo3/4d11c9b4-efa8-485f-84fc-860d6b7878e6 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msiofolq1b7z/0030d9d8-df08-4214-8928-dac98aaaa44e | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-msiofolq1b7z/55027cc1-121e-428a-95fc-c89f19e9c2e4 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-mt2sf6eos36u/636c6cd2-f4b4-43df-a5c1-16449e41e000 | skipped | same file is referenced by V1 documents (migrated there) |
| intake_doc | IK-mt2sf6eos36u/a040f760-3de9-4a2b-a6b5-a9d90588a997 | skipped | same file is referenced by V1 documents (migrated there) |
| referral | R-9uyk3 | migrated | joined_on 2026-11-01 is after 2026-10-19: kept as offer (入社 scheduled) |
| referral | R-sp2f8 | migrated | joined_on 2026-12-01 is after 2026-10-19: kept as offer (入社 scheduled) |
| assignment | （8 行） | skipped | 対象外の会社（KA999・RE999）の公開行 |

## 5. 報酬

- 入社として移した: 1 件 ／ 合計 916,062 円（税抜）／ 支払待ち 1 件
- V1 で入社日が入っている送客は 3 件。V1 の status はすべて offer のまま。入社日が 2026-10-19 より後のものは「入社待ち」（最後の段階「入社」の予定日＝V1 の入社日）として移し、報酬はまだ作らない。その日を過ぎてから流し直すと報酬が作られる
- 返金規定を持つ求人: 1 件（V1 の文章から「◯か月以内 ◯%」を読み取り。経歴詐称の全額返金は V2 に項目が無いため対象外）
- V1 の client_fee（求人企業が KANOA に払う額）は V2 に置き場が無いため移していない。合計 2,366,062 円（求人4件分）
- V1 の送客報酬（referral_reward）合計 0 円・会社ごとの上書き（ref_override）0 件 → V2 に送客報酬は無い（設計書14）

## 6. 書類ファイルのコピー（candidate-docs → v2-files）

- コピー先の数 490 ／ 今回コピー {} ／ コピー済みで飛ばした 490 ／ 失敗 0
- V1 から消えた書類のコピーを消した 0（消すのはコピー済み台帳にあるものだけ） ／ 台帳に無いファイル（触らない）0
- v2-files に実物がある 490 件・245980375 バイト ／ 大きさの不一致 0 件
- V1 の置き場 candidate-docs: 638 件・325,502,299 バイト。うち documents から参照されていないもの 154 件（紹介フォームの添付の控え・削除済みの送客の書類など。移していない）

## 7. 連絡（チャット）

- 返信つき 15 ／ 編集済み 23 ／ リアクションつき 291（V1 の文字のリアクション「承知しました」等もそのまま）
- 既読: V1 の read をそのまま再現。未読として残るのは パートナー側 6 件・KANOA 側 0 件（スレッドの既読 458 行）

## 8. V1 は読むだけだったことの確認（実行の前後）

| V1 | 前 | 後 | 変化 |
|---|---:|---:|:-:|
| agencies | 27 | 27 | なし |
| projects | 4 | 4 | なし |
| assignments | 108 | 108 | なし |
| referrals | 230 | 230 | なし |
| documents | 484 | 484 | なし |
| intake | 105 | 105 | なし |
| messages | 1,666 | 1,666 | なし |
| notices | 4 | 4 | なし |
| tasks | 25 | 25 | なし |
| reflog | 205 | 205 | なし |
| tracker_links | 73 | 73 | なし |
| kanoa_admins | 1 | 1 | なし |
| candidate_docs_objects | 638 | 638 | なし |
| v1_auth_users | 26 | 26 | なし |

## 9. 実行の記録

```
{"purged": {"jobs": 4, "clients": 2, "members": 25, "notices": 4, "rewards": 1, "companies": 25, "candidates": 234, "applications": 230, "discarded_preview_edits": {}}, "joined_until": "2026-10-19", "members_active": false, "discard_preview_edits": false, "disabled_triggers_after_run": 0}
```

## 10. V2 のテスト（移行後・順番に実行）

| テスト | PASS | FAIL |
|---|---:|---:|
| phase1 | 17 | 0 |
| phase2 | 23 | 0 |
| phase3 | 26 | 0 |
| phase4 | 31 | 0 |
| phase5 | 28 | 0 |
| phase6 | 162 | 0 |
| phase7 | 106 | 0 |
| phase8 | 55 | 0 |
| phase9 | 84 | 0 |
| ui_queries_check.py | 84 | 0 |
