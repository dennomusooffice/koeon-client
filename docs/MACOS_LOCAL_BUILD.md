# Macでのローカルビルド

Apple Silicon Mac用の手順です。リポジトリのルートで実行します。
ネイティブアプリのビルドにNode.js、pnpm、CocoaPods、Flutterは不要です。

## 導入した環境

2026-10-02に以下の環境を構成しました。

| 項目 | バージョン・場所 |
| --- | --- |
| macOS | 26.6 / arm64 |
| Xcode | 27.0（27A266a）、`/Applications/Xcode.app` |
| iOS Simulator | iOS 27.0 / arm64 |
| Java | Eclipse Temurin JDK 17.0.20.1+1、`~/Library/Java/JavaVirtualMachines/` |
| Android SDK | `~/Library/Android/sdk` |
| Android Platform | API 36 |
| Android Build Tools | 35.0.0（このプロジェクトのAGPが使用） |
| Android Platform Tools | 37.0.1 |
| Gradle | リポジトリ付属のWrapper 8.13 |

Xcodeの初回コンポーネント導入は完了しています。CIはXcode 26.6を使用しますが、
このMacでは既存のXcode 27.0を使用します。

`~/.zprofile`に`JAVA_HOME`、`ANDROID_HOME`、Java・SDKツールの`PATH`を設定済みです。
既に開いているターミナルでは`source ~/.zprofile`で反映できます。
`android/local.properties`にもSDKの絶対パスを設定済みです。このファイルはGit管理対象外です。

確認結果（取得した`main`: `ac134f4183729c8959a10878e3b255e0bc9def45`）:

- iOS Simulator Debugビルド成功、コンパイル済みAppIcon検証成功。
- iOS XCTest: 215件成功、失敗0件。
- Android Debug APK生成成功、ユニットテスト151件成功、失敗0件。
- Android `lintDebug`成功（エラー0件、既存コード・依存関係等の警告35件）。
- ローカルの検証ログ: `.build/macos/ios-build.log`、`ios-test.log`、`android-build.log`、`doctor.log`。

実機での通話、iPhone実機署名、配布用Releaseビルドは未検証です。

## ビルドと検証

```sh
# 環境を確認
bash scripts/macos-build.sh doctor

# Android Debug APK
bash scripts/macos-build.sh android

# Androidユニットテスト・Lint・Debug APK
bash scripts/macos-build.sh android-check

# iOS Simulatorアプリ（署名不要）
bash scripts/macos-build.sh ios

# iOS XCTest（利用可能なiPhone Simulatorを自動選択）
bash scripts/macos-build.sh ios-test
```

Simulatorを指定する場合は、`xcrun simctl list devices available`でUDIDを確認し、
`SIMULATOR_UDID="対象のUDID" bash scripts/macos-build.sh ios-test`を実行します。

成果物:

- Android APK: `android/app/build/outputs/apk/debug/app-debug.apk`
- Androidテストレポート: `android/app/build/reports/tests/testDebugUnitTest/index.html`
- Android Lint: `android/app/build/reports/lint-results-debug.html`
- iOS Simulatorアプリ: `.build/macos/DerivedData/Build/Products/Debug-iphonesimulator/KOEON.app`
- XCTest結果: `.build/macos/DerivedData/Logs/Test/`の`.xcresult`
- Swift Packageキャッシュ: `.build/macos/SourcePackages/`

Swift Packageの解決結果は`ios/KOEON.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`に保存しています。
ビルドスクリプトは作業ディレクトリに依存せず、Mac付属のBashで動作します。
初回の依存取得にはインターネット接続が必要です。

## IDEと端末での実行

iOSは`open ios/KOEON.xcodeproj`でXcodeに開き、Scheme `KOEON`とiPhone Simulatorを選択します。
Android Studioは今回導入していません。必要なら公式サイトからApple Silicon版を導入し、
`android/`を開いてSDKの場所を`~/Library/Android/sdk`、Gradle JDKをJDK 17に設定してください。
Android Emulatorのシステムイメージも未導入ですが、APKのビルドには不要です。

USBデバッグを許可したAndroid端末では、`adb devices`で接続を確認してから
`adb install -r android/app/build/outputs/apk/debug/app-debug.apk`でインストールできます。

## 実機署名・本番接続

今回の標準コマンドはAndroid DebugとiOS Simulator向けです。
iPhone実機向けの署名には、XcodeのApple Account、開発Team、適切なBundle ID、
Push-to-Talk等のCapabilityとProvisioning Profileの設定が必要です。
Simulator用`.app`をiPhoneに直接インストールすることはできません。

公開ソースは初期状態で`https://example.invalid`を使用します。
ビルドが成功しても本番サービスへの接続・通話を保証するものではありません。
署名付き配布と接続先の設定については、
[Android配布手順](ANDROID_PUBLIC_RELEASE.md)と
[iOS配布手順](TESTFLIGHT_INTERNAL_RELEASE.md)を参照してください。
既存の署名鍵、Apple Account、接続先の値は今回変更していません。

## 別のMacで再構築する場合

1. Xcodeを導入して起動し、初回セットアップを完了します。
   `xcode-select -p`がXcodeのDeveloperディレクトリを指すことを確認してください。
   `xcodebuild -runFirstLaunch`と`xcodebuild -downloadPlatform iOS -architectureVariant arm64`でも準備できます。
2. [Eclipse Temurin公式](https://adoptium.net/temurin/releases/?version=17)のmacOS AArch64 JDK 17を導入します。
   アーカイブ版の場合は`~/Library/Java/JavaVirtualMachines/`に展開します。
3. [Android公式ツール](https://developer.android.com/studio#command-tools)を導入し、
   `~/Library/Android/sdk/cmdline-tools/latest/`の下に`bin/`と`lib/`を置きます。
4. 次を実行してSDKを導入します。求められるライセンス条項を確認してください。

   ```sh
   export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
   export ANDROID_HOME="$HOME/Library/Android/sdk"
   "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" \
     'platform-tools' 'platforms;android-36' 'build-tools;35.0.0'
   printf 'sdk.dir=%s\n' "$ANDROID_HOME" > android/local.properties
   ```

   新しいSDKツールでは`sdkmanager`がAndroid CLIへ処理を委譲する場合があります。
5. 上記のビルド・検証コマンドを実行します。

Protocol packageを編集・検証する場合のみ、別途Node.js 22以上とpnpm 10.15.0が必要です。
また、既存の`ci-public-safety.sh`は`mapfile`を使うためBash 4以上が必要です。
これらは今回のネイティブビルド環境の対象外です。
