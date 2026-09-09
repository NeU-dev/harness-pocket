# Completion, approval and question notifications

The gateway monitors DSH on the host while the iPhone app is in the background
or closed. It sends APNs alerts for completed turns, execution approvals and
follow-up questions. Notification text is generic; conversation and question text
are not included. A notification opens its associated conversation.

## Prerequisites

- Apple Developer Program membership with Push Notifications enabled for your App ID.
- A signed app whose Bundle ID matches the APNs topic.
- Your own APNs ES256 `.p8` key, Key ID and Team ID.
- Gateway network access to Apple APNs over HTTPS.

No notification key is bundled or shared by this repository. Chat remains
available without APNs configuration.

## Apple setup

1. Open [Apple Developer keys](https://developer.apple.com/account/resources/authkeys/list).
2. Create a key with Apple Push Notifications service enabled.
3. Choose the environment appropriate to your build. Xcode Debug uses **sandbox**;
   Release/TestFlight uses **production**. A sandbox-only key cannot send to TestFlight.
4. If the key is topic-restricted, select **your own Bundle ID**, as set in `ios/Local.xcconfig`.
5. Download the `.p8` key and keep its Key ID and your team's Team ID.

## Configure in the app

Open **設定 → 通知の設定・接続テスト**.

1. Tap **通知を許可して登録** to grant iOS permission and register the device.
2. Enter the Key ID and Team ID, then choose your `.p8` file.
3. Confirm the displayed Bundle ID, then tap **通知キーをDGXへ保存**.
4. Tap **テスト通知を送信** and check the actual iPhone's notification center.

The app sends its own Bundle ID with the key. The gateway stores the topic, key
and configuration in its private data directory. All devices on one gateway
should use the same app Bundle ID; this is not a multi-tenant push relay.
Alternatively, set `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC`
on the gateway before its first run. Once saved, `data/apns.json` takes precedence.

## Delivery behavior

- Completion uses durable `turn/end` with reason `completed`; cancelled or failed turns do not masquerade as completed answers.
- Approval requests and question requests are deduplicated for each device and conversation.
- Unsent notices are cancelled when answered or cancelled. Question notices wait through DSH disconnection until the request is reannounced.
- The notification queue is persisted and temporary APNs failures are retried. An APNs 410 removes the invalid device token.
- Queue persistence and stable collapse IDs reduce duplicates, but a crash between Apple acceptance and saving can still cause a resend.

An APNs HTTP 200 means Apple accepted the notice. It does **not** verify display,
timing, sound or deep-link behavior on your device. Check those on a physical
iPhone. Focus modes, disabled notifications, networking and iOS scheduling affect delivery.

## 日本語メモ

アプリの「設定 → 通知の設定・接続テスト」で通知を許可し、**自分の**Key ID・Team ID・`.p8`ファイルを登録してください。
表示されるBundle IDはアプリ自身の値です。TestFlightはproduction環境を使います。
「テスト通知を送信」の成功表示に加えて、iPhoneで通知が実際に届き、会話へ移動できることを確認してください。
