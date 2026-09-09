# Security

Harness Pocket is a personal remote-control client. A paired device can change
Harness settings, access conversations and files, and respond to execution
approvals. Treat a pairing code as access to your Harness environment.

## Deployment model

- Run the gateway on loopback, behind Tailscale Serve HTTPS inside your tailnet.
- Do not expose it with Tailscale Funnel, public port forwarding, or an open reverse proxy.
- Pairing codes expire after 10 minutes and can be used once. Revoke lost devices from the app's settings.
- The gateway keeps hashed device tokens; the iPhone keeps its token in Keychain.
- DSH launch tokens, upstream cookies, APNs keys and uploaded files stay in the gateway's private data directory.
- APNs receives generic completion/approval/question notices and routing identifiers, without conversation or question text.

The gateway is designed for one trusted user and their devices. It is not a
multi-tenant service, and paired devices are not isolated from one another.
Uploads are retained on the host; there is currently no automatic retention policy.

## Reporting a vulnerability

Use [GitHub's private vulnerability report](https://github.com/akinadayo/harness-pocket/security/advisories/new).
Please avoid putting credentials or private conversations in a public issue.
Include the affected revision, a minimal reproduction, and the impact you observed.
