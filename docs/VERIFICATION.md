# Verification

This document separates automated checks, live-host observations and physical-device
checks. Personal connection details, conversation content, release archives and
signing records are not included in this repository.

## Public-source preparation — 2026-09-09

- Removed character artwork, character UI and its setting from the public app.
- Added an original code-drawn icon and synthetic-data screenshots.
- Replaced personal signing and hostname defaults with an ignored local configuration and a blank connection field.
- Made the APNs topic follow the app's own Bundle ID, including persistence and invalid-input regression coverage.
- Gateway: **30 tests passed** on local Node.js 24. Tests use mock services and generated test keys; they do not call a live model or Apple APNs.
- Unsigned Simulator build passed on Xcode 26.1.1. Visually checked the welcome screen, demo chat, question card and multi-line input above the software keyboard on iPhone 17 Pro / iOS 26.1. Screenshots use synthetic data. CI builds the Simulator target and tests Node.js 22 and 24.

## Previously verified behavior

- A real DGX Spark gateway connected to DSH 0.1.2-rc.1 and read conversations, models and settings.
- Simulator UI checks covered keyboard placement, long-chat bottom scrolling, question selection, offline connection repair and conversation restoration.
- Port and startup-token changes were tested together using mock DSH servers. The active user's DSH process was not restarted solely for a test.
- A generic test notification was accepted by Apple APNs with HTTP 200 on the maintainer's deployment. This is not proof of device display or every question/approval path.
- Streaming workload: 80 history rows and 60 updates took about **1.32 seconds of CPU time** over **15.56 seconds elapsed** on iPhone 17 Pro / iOS 26.1 Simulator after stream batching and lazy rendering. These are Simulator measurements, not an iPhone thermal or battery benchmark.

## Japanese and English UI — 2026-09-10

- Added Japanese-source string catalogs with English translations for the app UI, client and gateway errors, demo data, camera and local-network permission descriptions.
- APNs payloads now use localization keys, so completion, approval, question and test notifications are rendered in the receiving iPhone's app language without sending conversation text.
- Gateway: **31 tests passed**, including all four notification localization keys and the absence of literal notification bodies.
- Unsigned Debug Simulator and Release device builds passed on Xcode 26.1.1. Visually checked the English welcome, question and settings screens, then relaunched the welcome screen in Japanese on the dedicated iPhone 17 Pro / iOS 26.1 Simulator.
- Physical-device notification language, layout and delivery were not re-tested in this localization pass.

## Connection-state regression — 2026-09-16

- A failed session, model or workspace refresh no longer closes an otherwise healthy mobile WebSocket or starts a reconnect loop.
- A local mock gateway deliberately returned HTTP 500 for the initial session refresh. The app kept one WebSocket connection and continued to show the connected state for more than 13 seconds.
- The private Tailscale HTTPS health endpoint returned HTTP 200 in 20 consecutive requests. This confirms gateway reachability, not the internal DSH connection state.
- Signed Debug Simulator and unsigned Release device builds passed on Xcode 26.1. The live physical-iPhone connection still needs confirmation after installing the updated build.

## Not yet established

- Physical-device temperature and power consumption.
- Question notification display and tap-through across every iOS/background state.
- Compatibility with all DSH releases or hosts other than the tested DGX configuration.
- General-purpose multi-user or public-internet hosting.

Run `cd gateway && npm ci --ignore-scripts && npm test` for the automated suite.
The GitHub Actions run attached to a commit is the source of truth for its CI result.
