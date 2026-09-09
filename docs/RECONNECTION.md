# Recover after a DSH restart

DSH can restart with a different port and startup token. Reusing an old URL or
cookie will leave the gateway disconnected. The optional `dsh-link` plugin passes
fresh connection information directly from DSH to the gateway on the same host.

## Install the local plugin

These instructions target the inspected DSH **0.1.2-rc.1** web profile.
Back up that profile before editing; its plugin configuration can change between
DSH versions. Run this on the host, from this repository's checkout:

```sh
mkdir -p "$HOME/.dsh/plugins"
cp -R dsh-link "$HOME/.dsh/plugins/dsh-plugin-harness-pocket-link"
dsh plugin --profile web add "$HOME/.dsh/plugins/dsh-plugin-harness-pocket-link"
```

Ensure the Node.js and pnpm used by DSH are available in your shell.
In `~/.dsh/profiles/web/cordis.patch.yml`, add the following entry **once** to the
existing `insert` list, preserving all other entries:

```yaml
- id: harness-pocket-link
  name: dsh-plugin-harness-pocket-link
  disabled: false
```

The plugin also needs the local dependency registered in the web profile's
`package.json`; the add command above handles dependency registration. Do not add
a second instance under profile bundles. The tested web profile supported a live
patch without stopping DSH. If your version differs, consult its plugin workflow.

Use the default gateway `DATA_DIR=../data` when it is installed at
`~/.local/share/harness-pocket/gateway`. The plugin writes to
`~/.local/share/harness-pocket/data/dsh-runtime.json`; custom installations must
make the gateway and plugin use the same data directory.

## What the handoff does

- Calls DSH's `connection.authenticatedUrl()` with its actual web-server port.
- Saves the loopback origin, startup token and DSH PID to a private local file.
- Uses directory mode 700 and file mode 600, owned by the DSH user.
- Avoids logging the token or sending it off-host. Save failures do not crash DSH.
- The gateway rechecks file ownership, permissions, loopback URL and live PID at reconnect time, then authenticates again when the port or token changed.

The plugin and gateway must run as the same host user. It does not restart DSH,
change your model, or replace your settings. Existing iPhone pairing and APNs
configuration remain in the gateway data directory.

## Repair from the iPhone

Open **設定 → 接続を確認・修復**, or tap the reconnect banner above the chat.

1. Check the DSH and automatic-link status.
2. Tap **再接続する** to reread connection information.
3. Without automatic handoff, paste DSH's current startup URL into the secure
   field. The gateway validates authentication before saving, and the field clears.

If DSH itself is stopped, start it on the host. Enable Tailscale on the iPhone.
Use the startup URL from **your own DSH**, never one copied from another person's setup.

## 日本語メモ

DSH再起動後はポートとtokenが変わる場合があります。同じホスト・同じユーザーで連携プラグインを動かすとGatewayが追従します。
自動連携がない時も「接続を確認・修復」から新しい起動時URLを入力できます。
この機能はDSH本体の自動起動を行いません。
