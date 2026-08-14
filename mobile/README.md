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
network, or `https://lynrummy.com`. A successful login is saved in the
device keychain as a profile (server + uid + key). Sign out leaves it
there so you can tap it next time; Settings → Forget this login deletes it.

## Tests / publish

```bash
ops/test_mobile          # jest: api / parse / compose / scroll (no simulator)
ops/test_mobile_e2e      # Maestro: login, tabs, rail, quote / refer / edit
ops/test_mobile_scroll   # Maestro: own-send jumps, ↓, stick-on-receive
ops/build_mobile         # iOS simulator app, and an Android debug APK if the SDK is present
ops/publish_testflight   # Release archive + IPA (add --upload after the paid team is live)
```

Unit tests sit next to the modules (`src/**/*.test.ts`), the same split the
Zulip Flutter client uses: wire/API, model (compose + feed append +
caught-up), and a Maestro pass for the screens. The default
`__tests__/App.test.tsx` is a placeholder; the real suite is under `src/`.

`ops/build_mobile` is the agent publish path: `xcodebuild` / `gradlew`, no
cloud builder, no login token.

## Give it to someone who has an iPhone and no Mac

Apple will not install an `.ipa` from a GitHub Release the way Android
installs an APK. Three paths, cheapest first.

### 1. The website (no install)

This is the same chat. On the phone:

1. Safari → [https://lynrummy.com/chat](https://lynrummy.com/chat)
2. Log in with the usual site account
3. Optional: Share → **Add to Home Screen** for an icon

No Xcode, no Apple Developer fee, no weekly refresh.

### 2. SideStore (native app, $0, refresh every 7 days)

They install the native client with **their** free Apple ID. You send them
an `.ipa`; you never share your Apple ID. Official docs:
[prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
and [install](https://docs.sidestore.io/docs/installation/install).

They need a computer **once** (Windows, Mac, or Linux). After that the
phone refreshes itself.

**You (this repo):** build a Release `.ipa` and send them the file.

**Them — one-time setup**

1. On the iPhone: install [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)
   from the App Store. Open it → Connect → allow the VPN profile.
2. On a computer: install [iloader](https://iloader.app)
   ([Mac dmg](https://github.com/nab138/iloader/releases/latest/download/iloader-darwin-universal.dmg)).
3. Cable the phone to that computer. Trust the computer. Unlock the phone.
4. Open iloader → sign in with **their** Apple Account → pick the phone →
   **Install SideStore (Stable)**.
5. On the phone:
   - **Settings → General → VPN & Device Management** → their Apple
     Account → **Trust**
   - **Settings → Privacy & Security → Developer Mode** on (phone reboots)
   - Open LocalDevVPN → Connect (Wi-Fi, not cellular)
   - Open SideStore → sign in with the **same** Apple Account used in iloader
   - **My Apps** → tap the **7 DAYS** badge on SideStore to finish setup

**Them — install Angry Gopher**

1. Put the `.ipa` on the phone (Files / AirDrop).
2. SideStore → **+** → pick the IPA → install.
3. Trust the developer profile again if iOS asks.
4. Sign in with server `https://lynrummy.com` and a chat API key
   (web Settings → `POST /settings/apikey`).

**Every week:** Wi-Fi on, LocalDevVPN connected, SideStore → **Refresh**,
before the counter hits 0. Miss it and the app dies until they refresh.
Free Apple IDs allow **3 sideloaded apps**, including SideStore.

A pairing file can die after an iOS update. Re-run iloader and
[replace the pairing file](https://docs.sidestore.io/docs/advanced/pairing-file).

### 3. TestFlight (native app, paid Apple Developer Program)

A free Personal Team cannot upload. Enroll the Apple ID already in Xcode
(`apoorvavpendse@gmail.com`, team `63958776FZ`):

1. Pay and enroll at <https://developer.apple.com/programs/enroll/>
2. Xcode → Settings → Accounts → select the team → Download Manual Profiles
3. [App Store Connect](https://appstoreconnect.apple.com) → New App:
   bundle id `org.lynrummy.gopher`, name Angry Gopher, SKU anything unique
4. From the repo root: `ops/publish_testflight --upload`
5. App Store Connect → TestFlight → Internal Testing: add the colleague
   to the team, **or** External Testing: invite their Apple ID email
   (first external build goes through Beta App Review)
6. Colleague: install **TestFlight** from the App Store, accept the invite,
   tap Install. Sign in with server `https://lynrummy.com` and a chat API key

Each upload needs a new build number. The script uses `git rev-list --count`.

## What is in v1

- API-key login (keychain)
- Live Recent inbox (parses `#recent-data` on `GET /chat/recent`, then SSE)
- Topic transcript over `/stream`
- Visible quote / refer / edit / save on every bubble
- Send + image/screencast upload
- Light/dark from the web palette

Docs editing is not in this tree yet.
