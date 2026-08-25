# Privacy disclosure input — Human / legal draft

この文書は、将来のprivacy policyとstore disclosureを作成するためのtechnical inputです。承認済みprivacy policyではありません。

## Google Code Scanner

- Component: `com.google.android.gms:play-services-code-scanner:16.1.0`
- Purpose: QR inviteをscanし、decodeしたvalueをappへ返す。
- Camera / image handling: Googleはon-device processingを説明し、imageやscan resultを保存しないとしています。
- Module delivery: Google Play servicesがunbundled scanner moduleをdownloadする場合があります。
- General ML Kit diagnostics / analytics: device / app information、identifier、performance / configuration / size / version / event / error metadataがGoogle documentationに記載されています。
- Auto-zoom: KOEONで有効化しています。Googleは追加収集dataとして、scan-session ID、zoom change、予測したbarcode bounding-box coordinateを記載しています。

decodeしたinvite valueはKOEON enrollment logicで処理します。logやpublic diagnosticsへ出力してはいけません。

## publication前に必要なHuman / legal field

```text
DATA_CONTROLLER = HUMAN_TBD
PUBLIC_PRIVACY_CONTACT = HUMAN_TBD
RETENTION_DISCLOSURE = HUMAN_TBD
JURISDICTIONAL_BASIS = COUNSEL_TBD
GOOGLE_PLAY_DATA_SAFETY_ANSWERS = HUMAN_TBD
APPLE_PRIVACY_DISCLOSURE = HUMAN_TBD
PRIVACY_POLICY_APPROVED = NO
```

technicalな一次情報へのlinkは`docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md`に記載しています。

