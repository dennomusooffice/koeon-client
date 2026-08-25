# KOEON 日本語表記ガイド

この文書は、KOEON Clientの公開ドキュメントで用いる日本語表記を統一するためのガイドです。識別子、コード、コマンド、パス、URL、ライセンス表記、機械可読データは原文のまま扱います。

## 基本方針

- 公開ドキュメントの主言語は日本語（`ja-JP`）とします。
- 技術用語は、開発者が意味を正確に把握できることを優先します。
- 固有名詞とtechnical identifierは無理に翻訳せず、必要な場合のみ初出で日本語の説明を添えます。
- 監査用status fieldの名前と値は変更しません。
- third-partyのcopyright、license、legal noticeは翻訳しません。

## 標準表記

| 原語・識別子 | 標準的な説明 | 使用上の注意 |
| --- | --- | --- |
| KOEON Client | KOEONのiOS／Androidネイティブクライアント | 製品名は`KOEON`のまま表記 |
| PTT | プッシュ・トゥ・トーク | 識別子やプロトコル名では`PTT`を維持 |
| RX | 音声受信 | `RX_READY`などの識別子は変更しない |
| TX | 音声送信 | `TX`を維持してよい |
| Floor | 送信権 | プロトコル上の識別子では`Floor`を維持 |
| Floor Control | 送信権制御 | 初出以降は文脈に応じて「送信権制御」 |
| Room | LiveKit Room | クラス名・API名は原文維持 |
| Workspace | ワークスペース | 識別子では原文維持 |
| Channel | チャンネル | 識別子では原文維持 |
| CurrentSpeaker | 現在の話者 | フィールド名は原文維持 |
| PushToTalk | プッシュ・トゥ・トーク | 型名・機能名は原文維持 |
| LiveKit | LiveKit | 固有名詞のため翻訳しない |
| GitHub Actions | GitHub Actions | 固有名詞のため翻訳しない |
| XCTest | XCTest | 固有名詞のため翻訳しない |
| Gradle | Gradle | 固有名詞のため翻訳しない |
| CI | 継続的インテグレーション | 通常は`CI`と表記 |
| API | API | 通常は翻訳しない |
| SBOM | ソフトウェア部品表 | 初出で説明を添えてよい |
| SPDX | SPDX | expression、identifier、JSONの値は変更しない |
| MPL-2.0 | Mozilla Public License 2.0 | SPDX expressionは`MPL-2.0`を維持 |
| CLA | Contributor License Agreement | 外部コード受入れ前の方針を示す場合に使用 |
| DCO | Developer Certificate of Origin | 固有の制度名として原文維持 |
| PR | Pull Request | 通常は`PR`と表記 |
| SHA | Git commit/treeのSHA | 値を変更・省略しない |

## 文体

- 手順は簡潔な敬体、設計上の制約は断定的で明確な表現を使用します。
- `must`に相当する要件は「必須」「〜しなければなりません」、禁止事項は「禁止」「〜しないでください」と表現します。
- `review required`を「承認済み」と解釈せず、「レビューが必要」と表現します。
- `draft`は「草案」、`evidence`は「証跡」、`provenance`は「来歴」を標準とします。

## 変更してはならないもの

次の内容は日本語化の対象外です。

- `LICENSE`の本文
- third-partyのcopyright、license、legal notice
- SPDX expressions、package names、versions、URLs
- code blocks、commands、paths、technical identifiers
- SBOMおよびmachine-readable evidence
- `PASS`、`BLOCKED`、`REVIEW_REQUIRED`などの監査用status value
