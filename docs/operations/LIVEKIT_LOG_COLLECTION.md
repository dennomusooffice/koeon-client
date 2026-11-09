# LiveKitサーバーログの採取とクライアント照合

関連: [サーバーIssue #40](https://github.com/dennomusooffice/koeon/issues/40)、[クライアントIssue #57](https://github.com/dennomusooffice/koeon-client/issues/57)。

## 接続先と権限

サーバー側 `koeon` リポジトリの `deploy/livekit/SELF_HOST_RUNBOOK.md` と専用VPSのデプロイTASKを読む。KOEONバックエンドとLiveKitは別ホストの場合がある。専用ホストのローカル設定・既存SSH設定を参照し、デプロイTASKに記載された運用アカウントを明示する。既定のデプロイアカウントでDocker権限がないことを、ログが存在しない証拠として扱わない。

接続先・アカウント・Compose名は公開文書へ転記しない。既存の承認済み運用権限を使用し、認証設定やsudo権限を変更しない。

## 読み取り専用採取

運用アカウントで以下のコマンドを実行する。山括弧部分は既存runbookの値へ置換する。時刻はUTCの絶対時刻を使用し、必ず終了時刻を指定する。

```sh
sudo -n docker compose --project-name '<project>' --file '<compose-path>' \
  logs --no-color --timestamps --since '<UTC-start>' --until '<UTC-end>' '<livekit-service>'
sudo -n docker inspect --format '{{json .State}}' '<livekit-container>'
sudo -n docker inspect --format '{{.RestartCount}} {{.Config.Image}}' '<livekit-container>'
sudo -n docker stats --no-stream '<livekit-container>'
free -h
uptime
```

SSHの標準出力はMacのgitignoreされた保護ディレクトリへ直接保存する。ディレクトリ700、ファイル600、`umask 077`を使う。生ログをチャットやGitHubへ貼らない。`docker inspect`全体・`.env`・設定ファイル全体は秘密情報を含むため出力しない。常時debugログへの変更、コンテナ再起動、他プロジェクトの操作は採取に必要ない。

## 時系列の突合

1. アプリのビルド番号、ソースSHA、端末時計とタイムゾーン、試験開始・終了時刻を記録する。
2. クライアント診断のセッションハッシュとサーバー参加者情報を、保護されたローカル処理の中だけで照合する。公開結果は「送信側」「受信側A」等の試験内ラベルにする。
3. `SERVER_LEAVE_*`、ICE状態、signal close、サーバー `participant closing` の理由、新規セッションの開始・activeまでを同一セッションごとに並べる。
4. TURN失効・他参加者の切断を、対象セッションと照合せず原因にしない。v1.13.11ではTURN失効時もRefresh等を受け付け、Allocateの扱いと異なる。
5. OOMKilled、RestartCount、起動時刻を確認する。現在のメモリ余裕だけでは過去の圧迫を否定できない。
6. 初回通信断と復旧失敗を分離する。STATE_MISMATCHは、削除済み参加者でresumeした結果である場合がある。

公開可能な結果は時刻・数値・固定エラー分類のみ。SDP、ICE資格情報、IP、利用者／部屋／端末識別子、トークン、生音声を除く。JSONは許可したスカラー項目だけを抽出し、`state`・`worker`等の入れ子オブジェクトをそのまま公開しない。

## 次回追加採取

今回のinfoログだけでは初回ICE断のネットワーク起点は確定しない。次のエミュレータ試験では同時刻の双方のcandidate-pair統計（RTT、送受信bytes、loss、selected protocol）、ホストの経路変更／スリープ記録を保護先に採取する。必要な追加計測は対象・期間を限定し、他利用者の通信を収集しない。実機試験は新たな試験時間枠でのみ行う。
