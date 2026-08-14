# Mobile

Native iOS/Android client for Chat. Same HTTP + SSE API as `chat/chat_client.py`.
The zig server still owns the markdown dialect; this app paints the HTML the
wire already ships, and quote / refer / edit insert the same markdown the
browser client types.

No Expo. An agent can build and install without an Expo account.

## Run

From this directory, after `npm install`:

```bash
# iOS Simulator (Xcode required)
bundle exec pod install --project-directory=ios
npx react-native run-ios

# Android (Android SDK + a JDK required)
npx react-native run-android
```

Sign in with a chat API key from web Settings (`POST /settings/apikey`).
Point the server field at `http://<lan-ip>:9001` for a phone on the same
network, or `https://lynrummy.com`.

## Tests / publish

```bash
ops/test_mobile     # jest unit tests (parsers, compose, SSE framing)
ops/build_mobile    # iOS simulator app, and an Android APK if the SDK is present
```

`ops/build_mobile` is the agent publish path: `xcodebuild` / `gradlew`, no
cloud builder, no login token.

## What is in v1

- API-key login (keychain)
- Live Recent inbox (parses `#recent-data` on `GET /chat/recent`, then SSE)
- Topic transcript over `/stream`
- Visible quote / refer / edit / save on every bubble
- Send + image/screencast upload
- Light/dark from the web palette

Docs editing is not in this tree yet.
