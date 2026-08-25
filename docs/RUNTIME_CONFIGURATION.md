# Runtime configuration（実行時設定）

KOEON Clientは、private signing/build pipelineがProduct sourceを書き換えずにBackend API base URLを注入できる、共通のbuild-time configuration keyを備えています。

```text
KOEON_API_BASE_URL
```

## Public-safe default

overrideがない場合、または値が空・未展開・不正な場合は、必ず次の予約済みhostnameへfallbackします。

```text
https://example.invalid
```

隠れたProduction fallbackはありません。有効なoverrideは、hostを持ち、userinfo・query・fragmentを含まないHTTPS URLに限定されます。

## iOS

Xcode build setting `KOEON_API_BASE_URL`は、Info.plistの`KOEONAPIBaseURL`へ展開されます。`KOEONAPIClient`は`Bundle.main`からその値を読み、検証後に使用します。

placeholderだけを使うcommand-line例:

```sh
xcodebuild \
  -project ios/KOEON.xcodeproj \
  -scheme KOEON \
  -configuration Debug \
  KOEON_API_BASE_URL=https://api.example.test \
  build
```

generated xcconfigを使う場合、`//`がcommentとして解釈されないようslashをbuild settingとして組み立てられます。

```xcconfig
KOEON_URL_SLASH = /
KOEON_API_BASE_URL = https:$(KOEON_URL_SLASH)$(KOEON_URL_SLASH)api.example.test
```

このxcconfigはprivate/ephemeral build workspaceに生成し、Public repositoryへcommitしません。

## Android

Gradle property `KOEON_API_BASE_URL`はBuildConfigへ生成され、API client作成前に同じHTTPS validationを通ります。

placeholderだけを使う例:

```sh
./android/gradlew -p android assembleDebug \
  -PKOEON_API_BASE_URL=https://api.example.test
```

property未指定時は`https://example.invalid`で安全にbuildできます。

## Security boundary

- API base URLは配布binaryやInfo.plistから読み取れるconfigurationであり、secretではありません。
- API base URL設定にtoken、credential、invite code、API secret、署名情報を入れてはいけません。
- LiveKit API secretやtoken signing secretはserver-side onlyです。
- private signing/release pipeline、private endpoint値、証明書はこのrepositoryの対象外です。
- Production値をSwift/Kotlin sourceへhardcodeしたり、private buildでsource text patchしたりしてはいけません。
