# 自分のiPhoneで使い始める

英語の詳細版は [SETUP.md](SETUP.md)。ホスト上のGatewayと、MacでビルドするiPhoneアプリを用意します。
実接続を確認した環境はDGX Spark / DSH 0.1.2-rc.1です。

## 1. DSHを動かすホストで準備する

DeepSeek Harnessを起動し、ホスト自身でWeb画面につながることを確認します。
起動時URLに含まれるトークンは秘密情報なので公開しないでください。
Node.js 22以上とTailscaleを用意し、ホストで実行します。

```sh
git clone https://github.com/akinadayo/harness-pocket.git
cd harness-pocket
export POCKET_INSTALL_DIR="$HOME/.local/share/harness-pocket"
mkdir -p "$POCKET_INSTALL_DIR"
cp -R gateway "$POCKET_INSTALL_DIR/"
cd "$POCKET_INSTALL_DIR/gateway"
npm ci --ignore-scripts
cp .env.example .env
chmod 600 .env
```

エディタで `.env` の次の項目を設定します。

- `DSH_URL`：現在のDSH起動時URLの `http://127.0.0.1:ポート` 部分
- `DSH_TOKEN`：起動時URLのtokenの値
- `PUBLIC_URL`：自分の `https://ホスト名.tailnet名.ts.net:8443`
- `DATA_DIR=../data`：自動再接続プラグインの既定保存先と一致させる
- `APNS_TOPIC`：次の手順で設定する、自分のアプリのBundle ID

通知キーの欄は後からアプリで設定できます。

## 2. 常駐と外出先接続を設定する

ホストのリポジトリのフォルダへ戻り、実行します。

```sh
POCKET_NODE="$(command -v node)" bash scripts/install-gateway.sh
tailscale serve --bg --https=8443 http://127.0.0.1:8787
sudo loginctl enable-linger "$USER"
```

Linux/systemd用の手順です。nvmを使う場合は先にNode.js 22以上を選択してください。
Tailscaleが表示したHTTPS URLを `.env` の `PUBLIC_URL` に設定します。
稼働後に `.env` を変更したら `systemctl --user restart harness-pocket` で反映します。

Serveは自分のtailnet内で使用します。Funnelは使いません。既に8443で別のサービスを公開している場合は、先に既存設定を確認してください。
常駐設定はGatewayのもので、DSHやモデル本体の起動・再起動は行いません。

## 3. Macでアプリをビルドする

Macにもこのリポジトリを取得し、次を実行します。

```sh
cp ios/Local.xcconfig.example ios/Local.xcconfig
```

`ios/Local.xcconfig` を編集します。このファイルはGitに含まれません。

```xcconfig
POCKET_BUNDLE_ID = com.yourname.HarnessPocket
DEVELOPMENT_TEAM = YOURTEAMID
```

自分の一意なBundle IDとAppleのTeam IDへ置き換えます。
Xcodeで `ios/HarnessPocket.xcodeproj` を開き、HarnessPocketスキームとiPhoneを選んで実行します。
プッシュ通知を使うにはApple Developer Programと、Push Notificationsを有効にしたApp IDが必要です。
無料のPersonal TeamでAPNsを利用できるとは限りません。

画面を試すだけなら、iPhone Simulatorを選び、RunのArgumentsに `--demo` を追加します。
この場合はサーバーやAppleアカウントは不要です。実接続時はデモ用引数を外します。
一般公開のTestFlight招待はありません。必要に応じて自分のAppleアカウントで配布してください。

## 4. iPhoneを登録する

ホストで登録コードを発行します。

```sh
cd "$HOME/.local/share/harness-pocket/gateway"
node --env-file=.env scripts/pair.mjs
```

iPhoneのTailscaleをオンにし、アプリへ自分のHTTPS URLと登録コードを入力します。
コードは10分間・1回のみ有効です。ここへ入力するのは端末登録コードで、DSH起動時のtokenではありません。

## 5. 通知と自動再接続を設定する

[通知の設定](NOTIFICATIONS.md)からAPNsキーを登録し、テスト通知を送ります。
[再起動後の接続](RECONNECTION.md)のプラグインを追加すると、DSHのポートやトークンが変わった時に追従できます。

外出先ではホスト・DSH・Gatewayを起動し、iPhoneのTailscaleをオンにしてください。
通知は集中モードやネットワークの影響を受けます。
