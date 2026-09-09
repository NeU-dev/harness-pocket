# Contributing

Thanks for trying Harness Pocket. Bugs, documentation improvements, translations,
and small pull requests are welcome. For a new backend or a larger change, open
an issue describing the user flow first.

## Local development

```sh
cd gateway
npm ci --ignore-scripts
npm test
```

Open `ios/HarnessPocket.xcodeproj` in Xcode and choose an iPhone Simulator.
No signing account, gateway, or APNs key is needed for the bundled preview:
add `--demo` under **Product → Scheme → Edit Scheme → Run → Arguments**.
Add `--welcome-qa` for the welcome screen or `--question-qa` for a question card.
Preview data is synthetic, and preview mode does not connect to DSH.

The Xcode project is checked in. If you add a Swift file, regenerate it with
`gem install xcodeproj -v 1.27.0` followed by `ruby scripts/generate-project.rb`.
Personal signing values belong in the ignored `ios/Local.xcconfig`.

## Before sending a pull request

- Run the gateway tests when changing the gateway or its protocol.
- Build the iOS Simulator target when changing Swift or build settings.
- For chat layout changes, check a long conversation and the keyboard on a narrow screen.
- Keep stream updates batched, and avoid animations or repeated full-transcript work during token streaming.
- Add a regression test for a changed protocol behavior, rather than duplicating implementation details.

Use synthetic conversations and placeholder hostnames in screenshots and issue
reports. Keep startup URLs with tokens, APNs keys, device tokens, `.env`, local
signing configuration, and gateway data out of contributions.

Contributions are accepted under the project's MIT license. Third-party dependencies
retain their own licenses.
