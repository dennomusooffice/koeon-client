# iOS RX・TX中断・BUSY復旧（TASK005D）

## 状態の根拠

- Participantの解決だけではRX経路を有効扱いにしない。BATv1は現在generationのsubscription request、LiveKit fallbackは現在Roomの実際にsubscribeされたtrackを確認する。
- 250 / 750 / 1500 / 2500msでreconcile、receiver再bind、soft rebind、fresh runtimeへ段階昇格する。期限はepisode開始からのmonotonic clock。同じreconcileで期限を更新しない。
- full rebuildは同一leaseにつき最大1回。選択チャネルをUI上変更せず、旧callbackをfenceし、watchdog／player停止をawaitし、fresh backend session・Room・Apple channel bindingを再構築する。再構築後も無音なら次のbounded terminal段階へ収束する。ネットワーク復旧時間は別途必要であり、4秒以内の実音声復旧を保証するものではない。
- 250msの経過だけでspeakingを消さない。BATv1 generationにLiveKit PCMを混在させない。二重STARTはtimelineをseq0へ巻き戻さない。

## Background

`runtimeDirtySinceBackground`はbackground/inactive、切断、channel restoration、no-PCM昇格で立つ。PushToTalkによる一時的activeやcached CONNECTEDでは解除しない。fresh/current sessionとRX/TX bindings成立後だけ解除する。

## TX中断とFloor

通常送信はRELEASING中のrenewを維持し、hangover → final marker → control END → Floor releaseの順序を保つ。送信開始前の失敗ではbuffer discard → END → own Floor release → Apple end → managed audio rearmの別経路を使う。

Floor release失敗時はleaseを消さない。最大3回のrelease失敗後はstatusによる権限確認へ移り、未確認の間はERRORかつPTT禁止。他人のFloorを解放しない。Apple終了が未確認ならREADYへ偽装しない。

RX終端後は250 / 500 / 1000 / 2000 / 4000msのbounded status確認と既存status pollingにより、新しいPTTを待たずBUSYを再評価する。

## 診断と受入

current / lastCompletedのTX・RX・wakeを分離し、channelは短縮hash、runtimeはgenerationで記録する。current releaseLifecycleに前回timestampを代入しない。

自動テストは100回のTX→RX切替、50回のactivation fault injection、lease release失敗、dirty CONNECTED、段階昇格、channel再入場、終端後Floor収束を対象とする。仮想transport/playerによるテストは実機音声の合格証拠ではない。

実機ではAndroid 1.0.8 (9)を使用し、30回のrole reversal、50 generation交互送信、10回のA→B→A、20回のbackground participant消失を確認する。無音・ERROR/BUSY固定・manual recoveryが0であることをHumanが判定する。

SDKの依存versionは変更しない。LiveKit 2.16.0のpublic [`isSubscribed` API](https://github.com/livekit/client-sdk-swift/blob/2.16.0/Sources/LiveKit/TrackPublications/RemoteTrackPublication.swift)で実subscriptionを確認する。private API、manual setActive、SDK forkは使わない。
