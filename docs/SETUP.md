# Set up your own Harness Pocket

There are two parts: a gateway next to DSH on your Linux host, and an app built
with Xcode on your Mac. The iPhone and host must be on the same Tailscale tailnet.
The live reference environment is DGX Spark with DSH 0.1.2-rc.1; other DSH versions
may need changes to the adapter documented in [UPSTREAM.md](UPSTREAM.md).

## 1. Prepare the host

Install and start [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
using its upstream instructions. Verify that its web interface works on the host.
Keep the startup URL private: it contains a launch token.

Install Node.js 22+ and Tailscale, then run these commands **on the DSH host**:

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

Edit `.env` in your editor:

```dotenv
HOST=127.0.0.1
PORT=8787
PUBLIC_URL=https://YOUR-HOST.YOUR-TAILNET.ts.net:8443
DSH_URL=http://127.0.0.1:YOUR-DSH-PORT
DSH_TOKEN=YOUR-PRIVATE-STARTUP-TOKEN
DATA_DIR=../data
APNS_TOPIC=com.yourname.HarnessPocket
```

Replace the host, port, token and Bundle ID with your own values. `DSH_URL` is the
loopback origin of the **current** DSH startup URL. `DSH_TOKEN` is its token value.
Keep the gateway data at `../data` for the restart plugin's default handoff path.
APNs key fields may stay empty until you configure notifications in the app.

## 2. Keep the gateway running

From your **repository checkout on the Linux host**:

```sh
POCKET_NODE="$(command -v node)" bash scripts/install-gateway.sh
```

This installs and starts a user systemd service. It does not start or restart DSH.
If you use nvm, load the intended Node.js version in this shell first; the installer
records its full executable path.

Enable private HTTPS and, if desired, keep your user service alive after logout:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8787
sudo loginctl enable-linger "$USER"
```

Use the HTTPS hostname that Tailscale reports as `PUBLIC_URL` in `.env`.
If you edit `.env` after the service is running, apply it with
`systemctl --user restart harness-pocket`.

Use **Serve**, not Funnel. Keep access limited to your trusted tailnet devices.
The gateway's 8787 listener should remain on loopback. Check existing Serve rules
before using port 8443 so you do not replace another service at that port.

Useful host checks:

```sh
systemctl --user status harness-pocket
curl http://127.0.0.1:8787/health
```

`/health` confirms that the gateway is running, not that DSH authentication has
succeeded. The app's connection screen shows the DSH state after pairing.

## 3. Build the app on your Mac

Clone this repository on your Mac and run:

```sh
cp ios/Local.xcconfig.example ios/Local.xcconfig
```

Edit the ignored `ios/Local.xcconfig`:

```xcconfig
POCKET_BUNDLE_ID = com.yourname.HarnessPocket
DEVELOPMENT_TEAM = YOURTEAMID
```

Use a unique Bundle ID and your own Apple team. Open
`ios/HarnessPocket.xcodeproj`, choose the **HarnessPocket** scheme, select your
iPhone, and build. Personal signing settings are not part of the public project.

The project includes the Push Notifications capability. For physical-device
push, your Apple Developer Program team must have an App ID with this Bundle ID
and Push Notifications enabled. Simulator preview builds do not require an Apple
account. Do not assume a free personal team supports APNs.

For UI preview only, add `--demo` to the scheme's Run arguments. Remove preview
arguments before using the live service. There is no shared public TestFlight
invite; distribute builds through your own Apple account if you choose to use it.

## 4. Pair the iPhone

On the host:

```sh
cd "$HOME/.local/share/harness-pocket/gateway"
node --env-file=.env scripts/pair.mjs
```

Enable Tailscale on your iPhone. In Harness Pocket, enter your private HTTPS
URL and the newly generated code. Codes expire in 10 minutes and work once.
The DSH startup token belongs in the host configuration or connection-repair
screen, not in the device pairing-code field.

The app can also scan a QR containing `{"url":"https://…:8443","code":"…"}`.
Do not post pairing codes or token-bearing URLs in issues or screenshots.

## 5. Enable notifications and restart recovery

- [Notifications](NOTIFICATIONS.md): register your APNs key in the app and send a test notice.
- [Restart recovery](RECONNECTION.md): install the optional DSH plugin so changed ports and startup tokens are picked up automatically.

The gateway must remain running to monitor work while the iPhone app is closed.
DSH and its model service must also be running. If you need them to survive a host
reboot, configure their startup separately using their upstream documentation.

## Updating

Before replacing the gateway, preserve its private `.env` and `../data` directory.
Update source and dependencies, restart the gateway service, then rebuild the app
with the same Bundle ID to keep its Keychain identity. Do not copy another user's
data directory, signing settings or credentials.
