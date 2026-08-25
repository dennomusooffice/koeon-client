# Google dependency / privacy review

状態: technical / privacy evidenceのみです。legal approvalではありません。

## Exact component

```text
artifact = com.google.android.gms:play-services-code-scanner
version = 16.1.0
relationship = direct Android runtime dependency
purpose = QR invite scanning
GOOGLE_COMPONENT_STATUS = PRIVACY_DISCLOSURE_REQUIRED
LEGAL_REVIEW_REQUIRED = YES
```

Android UIは`GmsBarcodeScannerOptions`をbuildし、scan対象をQR codeへ限定してauto-zoomを有効化します。`GmsBarcodeScanning.getClient(...)`を取得し、`startScan()`を呼び出し、`Barcode.rawValue`だけをenrollment handlingへ渡します。

## Google公式documentationに基づくruntime behavior

- implementationはGoogle Play servicesから提供されます。このscannerのためにapp自身がcamera permissionをrequestすることはありません。
- image processingはon-deviceで行われます。Googleはimage dataやscan resultを保存しないと説明しています。
- scanner moduleはunbundledです。未installの場合、初回使用時にGoogle Play servicesがdownloadすることがあります。
- version 16.1.0はdocumented dependencyであり、有効化しているauto-zoom optionをsupportする最初のversionです。

一次情報: [Google Code Scanner for Android](https://developers.google.com/ml-kit/vision/barcode-scanning/code-scanner)

## Data Safety evidence

GoogleのML Kit Android disclosure guidanceでは、Google Play Data Safetyの回答に対する責任はdeveloperにあるとしています。ML Kit featureによるdiagnostic / usage collectionとして、device / app information、identifier、performance metrics、API configuration、input / output size、feature version、event type、error codeを記載しています。収集dataはtransit時にencryptedで、third partyへtransferしないと説明しています。

auto-zoomを有効化した`play-services-code-scanner`について、Googleはさらに、動的に生成されるscan-session identifier、zoom-level change、予測したbarcode bounding-box coordinateを挙げています。

一次情報: [ML Kit Android data disclosure guidance](https://developers.google.com/ml-kit/android-data-disclosure)

## Terms / privacy classification

Google API Termsは、user informationのcollection / use / sharingを正確に説明するprivacy policyと、applicable privacy lawへのcomplianceを求めています。一次情報: [Google APIs Terms of Service](https://developers.google.com/terms)

```text
IMAGE_OR_RESULT_TRANSMISSION_TO_GOOGLE = NOT_INDICATED_BY_OFFICIAL_SCANNER_DOCS
IMAGE_OR_RESULT_STORAGE_BY_GOOGLE = NO (official scanner documentation)
DIAGNOSTIC_USAGE_DATA = PRESENT_PER_OFFICIAL_DISCLOSURE_GUIDE
AUTO_ZOOM_ADDITIONAL_DATA = PRESENT
PRIVACY_DISCLOSURE = REQUIRED
LEGAL_APPROVAL = NO
```

A7では、publication / distribution前にapp privacy policyとGoogle Play Data Safety classificationを承認する必要があります。このauditは、各itemが特定jurisdictionでpersonal dataに該当するかを判断しません。

