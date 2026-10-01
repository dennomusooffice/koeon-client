# MacからTestFlight内部テストへアップロードする

GitHub Actionsを起動せず、このMacのXcodeでarchive、署名検証、TestFlightへのアップロードを行います。
既存の`ios-public-release.sh`とApple接続・署名検証を共通利用します。
対象は内部TestFlightです。App Store公開や外部テスターへの配布操作は含みません。

## このMacの準備状況

- Xcode 27.0、iOS SDK 27.0を利用します。
- Node.js 22.23.3を`~/Library/koeon-tools/`へ導入し、`~/.zprofile`にPATHを設定しています。
  既存のターミナルでは`source ~/.zprofile`を実行してください。
- Python 3、Git、Xcodeのコマンドラインツールを利用します。
- `.secret/testflight/config.json`を空の設定ファイルとして作成済みです（権限600、Git管理対象外）。
- Appleの設定・APIキーは未移行です。実際のApple認証、配布署名、アップロードは未検証です。

## Appleの設定とAPIキーを移す

既存アプリを更新するため、以前と同じApple Team、Bundle ID、接続先、Associated Domainを使用してください。
App Store Connect側にはそのBundle IDのアプリが登録されている必要があります。

1. 既存のApp Store Connect **チームAPIキー**の`.p8`を安全な方法でこのMacへ移します。
   保存先の例は`~/.config/koeon/AuthKey_ABCDE23456.p8`です。
   APIキーのファイル権限を`chmod 600`で設定してください。
2. Key IDとIssuer IDを確認します。Appleから秘密鍵を再ダウンロードすることはできません。
   元の秘密鍵が残っていない場合は、App Store Connectで必要な権限を持つ新しいキーを発行します。
   GitHubに登録済みのSecretをAPI経由で読み戻すことはできません。
3. `.secret/testflight/config.json`をローカルのエディタで編集します。
   キーの内容をこのJSONへ埋め込まず、ファイルの絶対パスを指定してください。

| 設定キー | 設定内容 |
| --- | --- |
| `APPLE_TEAM_ID` | 既存のApple Developer Team ID（10文字） |
| `KOEON_BUNDLE_ID` | App Store Connectの既存アプリのBundle ID |
| `KOEON_API_BASE_URL` | 実際のHTTPS API URL。認証情報・query・fragmentは不可 |
| `KOEON_ASSOCIATED_DOMAIN` | `applinks:`で始まる既存のAssociated Domain |
| `ASC_KEY_ID` | App Store ConnectチームAPIキーのKey ID（10文字） |
| `ASC_ISSUER_ID` | チームAPIキーのIssuer ID（UUID） |
| `ASC_KEY_PATH` | `.p8`への絶対パス。先頭の`~`は使用可能 |

署名には、対象アプリと証明書・Provisioningへのアクセス、およびクラウド署名に必要な権限が必要です。
Apple Developer側のApp IDにPush Notifications、Push-to-Talk、Associated Domainsを設定してください。
権限やCapabilityが不足している場合は候補作成で停止します。ローカル証明書を無条件に作成・削除する処理はありません。

新しいcloneで設定ファイルを作るには、次を一度実行します。既存ファイルは上書きしません。

```sh
python3 scripts/ios-local-testflight.py init
```

## 実行手順

コマンドはリポジトリのルートで実行します。以下のバージョン・ビルド番号は例です。
実際のApp Store Connectに合わせ、未使用のビルド番号へ置き換えてください。

```sh
# 設定・ファイル権限・APIキー形式・Xcode初期設定をローカルで確認
python3 scripts/ios-local-testflight.py check

# Apple APIのアクセス権、対象アプリ、バージョン内のビルド番号未使用を確認
python3 scripts/ios-local-testflight.py preflight --version 1.0.8 --build 10

# 署名まで実施して検証。アップロードは行わない
python3 scripts/ios-local-testflight.py candidate --version 1.0.8 --build 10

# 内容を確認後、同じコミットから再ビルド・署名して内部TestFlightへ送信
python3 scripts/ios-local-testflight.py upload --version 1.0.8 --build 10 \
  --confirm UPLOAD_TESTFLIGHT
```

`candidate`と`upload`は、未コミット・未追跡のソース変更があると停止します。
事前に変更をレビューし、コミットしてください。`.secret/`や`.build/`はこのチェックの対象外です。
実行開始時のHEADとtreeを記録し、一時ディレクトリへcloneした同一コミットをビルドします。
候補確認後にHEADを変更した場合は、新しいコミットで候補を再検証してください。

`check`成功はAppleアカウントへのアクセス成功を意味しません。
`preflight`成功も配布署名の成功を意味しません。署名を含めた確認には`candidate`を使用します。
ローカル実行はGitHub Environmentのreviewer承認を経由せず、このMacの操作者が実行を管理します。
GitHub Actionsの配布経路・承認条件は変更していません。

## 成果物とログ

- 設定・診断ログは`.secret/testflight/`内に保存し、Git管理から除外します。
- Xcodeの生ログには接続先やAppleの識別情報が含まれ得ます。公開Issue等には添付しないでください。
- 一時的なAPIキーのコピー、archive、IPA、解決済み依存・DerivedDataは成功・失敗時とも一時ディレクトリごと削除します。
- 元の`.p8`、設定ファイル、診断ログは保持します。
- 成功した候補のログには署名済みIPAのSHA-256と検証結果が含まれます。
- `upload`成功はAppleへの送信完了です。処理完了やテスターによる利用開始とは別です。

送信後はApp Store ConnectのTestFlight画面で、Processing、暗号化に関する質問、内部テスターグループへの追加を確認してください。
暗号化申告はアプリの実態に合わせて回答します。このスクリプトは申告やテスター招待を自動変更しません。

## ローカル検証

2026-10-02に、このMacでiPhone向けRelease archiveの作成（署名なし）が成功しました。
ローカル実行のテスト7件、既存iOS配布契約テスト17件、署名検証テスト3件も成功しています。

```sh
python3 scripts/ios-local-testflight.test.py
node --test scripts/ios-release-candidate-contract.test.mjs \
  scripts/ios-app-store-connect-preflight.test.mjs scripts/ios-testflight-security.test.mjs
python3 scripts/ios-signed-candidate-validation.test.py
```

これらは入力拒否、秘密情報を含めないエラー、ソースの隔離、失敗時の一時ファイル削除、既存配布契約を検証します。
モックを利用するテストは実際のApple署名・アップロード成功の証拠にはなりません。

参考: [Appleのビルドアップロード手順](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)、
[Appleのベータ配布手順](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。
