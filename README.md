# Eight Sleep Remote

A small personal SwiftUI app for setting an Eight Sleep Pod's bed temperature from an Apple Watch.

- **iPhone app**: sign in, pick your side (Left / Right / Solo), see and adjust the level, power on/off.
- **Watch app**: one screen. Side label, a big level ("+3", "~90°F"), big − / + buttons, and Digital Crown. Taps are debounced (0.6 s), then sent as a single PUT.
- **Complication** ("Bed Temp"): circular, corner, inline and rectangular. Tapping it opens the watch app. Rectangular shows the last known level.

> ⚠️ **Unofficial.** This uses Eight Sleep's private, undocumented cloud API, the same one used by
> pyEight, Home Assistant's `eight_sleep` integration and `eightctl`. It can change or break at any time,
> and heavy use gets rate-limited (HTTP 429). Not affiliated with Eight Sleep.

## Endpoints used

All requests send `Content-Type: application/json`, `Accept: application/json` and `User-Agent: okhttp/4.9.3`.
The OAuth `client_id` / `client_secret` are the public app client that every open-source client includes. No user credentials are in this repo.

| Purpose | Request |
|---|---|
| Login / refresh | `POST https://auth-api.8slp.net/v1/tokens` (`grant_type` = `password` or `refresh_token`) |
| Me + devices | `GET https://client-api.8slp.net/v1/users/me` |
| Side owners | `GET https://client-api.8slp.net/v1/devices/{id}?filter=leftUserId,rightUserId,awaySides` |
| Names | `GET https://client-api.8slp.net/v1/users/{userId}` (may 403 for other household members) |
| Read temp | `GET https://app-api.8slp.net/v1/users/{sideUserId}/temperature` |
| On / off | `PUT …/temperature` `{"currentState":{"type":"smart"\|"off"}}` |
| Set level | `PUT …/temperature` `{"currentLevel": -100…100}` (turns the side on first if it's off) |

The display level is `raw / 10` (−10…+10). °F is the nearest key in pyEight's `RAW_TO_FAHRENHEIT_MAP`.

Tokens are refreshed about 2 minutes before they expire, and requests retry once on 401. If the refresh grant fails, the iPhone falls back to a password grant using the stored password.

## How token sharing works

1. The iPhone stores the access token, refresh token, expiry, userId, email and password in its Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
2. Whenever you sign in, a token refreshes or you change sides, the phone calls `WCSession.updateApplicationContext` with
   `{accessToken, refreshToken, expiresAt, userId, sideUserId, sideLabel, side, signedIn}`. **The password is never sent to the watch.**
3. The watch saves the tokens in its own Keychain and the side in the App Group (`group.com.AnomalousResearch.EightSleepWatch`). It then calls the Eight Sleep API directly with `URLSession`.
4. When the watch's token expires, it tries the refresh grant first. If that fails and the phone is reachable, it sends a `"needToken"` message. The phone refreshes (using a password grant if needed) and replies with a fresh context. If neither works, the watch shows "Open Eight Sleep Remote on your iPhone".
5. Sign out on the phone clears its Keychain and App Group and sends `signedIn: false`, which makes the watch clear its copy too.

## Layout

```
project.yml          XcodeGen spec (the .xcodeproj is generated and gitignored)
Shared/              API client, Keychain token store, models, side logic, level/°F formatting, debouncer
iOS/                 iPhone app (login, control screen, WCSession phone side)
Watch/               watchOS app (single screen, WCSession watch side)
Widget/              watchOS WidgetKit complication
Tests/               XCTest unit tests (formatting, °F lookup, sides, JSON decoding, debounce)
Tools/make_icon.swift  Generates the 1024×1024 app icon into both asset catalogs
```

## Build

```sh
xcodegen generate
# iOS app (builds and embeds the watch app and complication)
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemote \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
# Watch app only
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemoteWatch \
  -destination 'generic/platform=watchOS Simulator' build CODE_SIGNING_ALLOWED=NO
# Unit tests
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
# Regenerate the icon
swift Tools/make_icon.swift
```

## Demo mode (screenshots)

Launch either app with the `-demo` argument or the `ESR_DEMO=1` environment variable. Demo mode skips networking and shows fake data: signed in, Left = Chase, Right = Partner, level +3, on.

```sh
xcrun simctl launch booted com.AnomalousResearch.EightSleepWatch -demo
xcrun simctl launch booted com.AnomalousResearch.EightSleepWatch.watchkitapp -demo
```
