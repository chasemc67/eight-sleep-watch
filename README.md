# Eight Sleep Remote

One SwiftUI remote for iPhone, Apple Watch and a four-family watch complication. Sign in on iPhone, choose Left / Right / Solo, then adjust your side on either device. The watch also supports the Digital Crown, a haptic per tap, and sending / ✓ / ! feedback. Requires iOS 18+ and watchOS 11+.

**Unofficial:** this uses Eight Sleep’s private cloud API. It can change or stop working without notice. This project is not affiliated with Eight Sleep, and no live API calls were made during development of this revision. No user credentials are included.

Levels display as −10…+10 (raw / 10), with approximate °F from the original pyEight nearest-key table. Each tap changes one app step. Both devices debounce for 600 ms, show the target immediately and roll back on failure. A shared coordinator serializes writes and coalesces queued targets; only an explicitly off side is powered on. Missing level/state fields remain unknown. Scene activation loads are coalesced.

## Endpoints

All requests use JSON, Bearer authorization where appropriate, and `User-Agent: okhttp/4.9.3`. The OAuth client ID/secret are public app constants used by existing open-source clients, not user credentials.

| Purpose | Request |
|---|---|
| Password / refresh grant | `POST https://auth-api.8slp.net/v1/tokens` |
| Account / device | `GET https://client-api.8slp.net/v1/users/me` |
| Side owners / away mode | `GET https://client-api.8slp.net/v1/devices/{id}?filter=leftUserId,rightUserId,awaySides` |
| Names (partner 403 is tolerated) | `GET https://client-api.8slp.net/v1/users/{userId}` |
| Temperature | `GET https://app-api.8slp.net/v1/users/{sideUserId}/temperature` |
| Power | `PUT …/temperature` with `{"currentState":{"type":"smart"}}` or `"off"` |
| Target | `PUT …/temperature` with `{"currentLevel": -100…100}` |

Device selection prefers `currentDevice.id`, then `devices.first`. Refresh is shared between concurrent callers, starts about two minutes before expiry, and requests retry once after a 401. A 429 blocks further requests until `Retry-After` (seconds or HTTP date; 60 seconds if absent). Password-grant 400/401/403 errors show “Wrong email or password.”

## Token sharing

The phone stores email, password and tokens in its Keychain using `AfterFirstUnlockThisDeviceOnly`. The watch has its own Keychain, containing tokens only. Phone-to-watch `WatchContext` carries access/refresh tokens, expiry, issue time, user ID and side selection; **it never includes the email or password**.

The watch calls the API directly. It tries a refresh grant, then asks a reachable phone for fresh tokens; the phone can fall back to its stored password. Expiry/issue-time checks reject older phone tokens, including replies to token requests. Same-side context updates preserve pending taps. Side changes discard queued work and ignore responses for the old side. Signing out clears credentials and sends a signed-out context; a credential-generation guard prevents late refreshes or phone replies from restoring the session.

The App Group `group.com.AnomalousResearch.EightSleepWatch` stores side selection and last known temperature/state for the watch/widget. Circular, corner, inline and rectangular complications launch the watch app; saved temperature updates reload the timeline. Widget colors may be overridden by the watch face’s rendering mode.

## Colors

`Shared/Theme.swift` is the single color definition compiled into phone, watch and widget:

| Role | Hex | Derivation |
|---|---|---|
| Warming / + | `#BD425B` | Median RGB of the big `+2` temperature text in Chase’s screenshot of the real Eight Sleep iOS app (October 2026) |
| Cooling / − | `#3858D0` | Median interior RGB of the official app’s blue `−4` temperature glyph |
| Neutral | `#FFFFFF` | Zero / unknown level |
| Navy background / card | `#0D1217` / `#1F262E` | Grok reference UI, rounded to 8-bit RGB |

Warming source: Chase supplied `#BD425B` (RGB `189,66,91`), the median color of the big `+2` temperature text in a screenshot he took of the real Eight Sleep iOS app in October 2026. This supersedes the earlier, lighter `#C6738C` App Store JPEG thin-glyph sample. Chase supplied this value and sampling provenance. Chase’s app icon is a separate illustration and is unchanged.

Cooling source (unchanged): [Eight Sleep’s App Store listing](https://apps.apple.com/us/app/eight-sleep/id1086913845), fetched through [Apple’s lookup API](https://itunes.apple.com/lookup?id=1086913845&country=us) on 2026-10-16, and its [1290×2796 temperature screenshot](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/ed/9b/7e/ed9b7e1c-d54b-040d-a0d0-13bae05ced05/2_APP_IPHONE_67_2.jpg/1290x2796bb.jpg). With Pillow, crop the blue `−4` glyph at `(620,1390)-(665,1450)` and retain `B>190, B>1.4R, B>1.1G` (196 pixels). Per-channel medians yield `(56,88,208)` / `#3858D0`. These are screenshot samples, not asserted official brand tokens. Downloaded images stay outside the repository.

Cross-check: [Eight Sleep’s website](https://www.eightsleep.com/) CSS contains `#4158EE`, consistent with the third-party “pulse blue” lead, but that website accent does not identify the app’s warm/cool temperature colors. The app screenshots are the primary sources used here.

## Build and test

Xcode 27 and XcodeGen are required. Bundle IDs, team `XPU32D9V4J`, automatic signing, and both scheme names remain unchanged. Version is 1.0; the timestamp build number is set once in `project.yml` and inherited by every target. Each shipped target includes a privacy manifest declaring UserDefaults reason `CA92.1`.

```sh
/opt/homebrew/bin/xcodegen generate
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemote \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemoteWatch \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath build/watch-dd build CODE_SIGNING_ALLOWED=NO
xcrun simctl list devices available
# Choose an available iPhone UUID; do not modify cmp-* simulators.
xcodebuild -project EightSleepRemote.xcodeproj -scheme EightSleepRemote \
  -destination 'platform=iOS Simulator,id=<IPHONE-UUID>' -derivedDataPath build/dd \
  -resultBundlePath build/Tests.xcresult test CODE_SIGNING_ALLOWED=NO
```

The host-less XCTest target compiles Shared directly. Injected transports exercise auth/refresh/401/429 without a real account. Regression coverage includes:

| Regression | Test(s) |
|---|---|
| Overlapping level writes / repeated power-on | `testLatestValueWinsWithOnePowerOnAndNoConcurrentWrites`, `testNewTapDiscardsPreviouslyQueuedTargetUntilDebounceSettles` |
| Failure with queued target | `testLevelFailureReportsRollbackAndKeepsLatestQueuedTarget` |
| Missing level / state | `testMissingTemperatureFieldsRemainUnknown`, `testUnknownPowerStateDoesNotTurnSideOn` |
| Refresh / phone reply after sign-out | `testRefreshFinishingAfterSignOutCannotRestoreCredentials`, `testPhoneFallbackFinishingAfterSignOutCannotRestoreCredentials` |
| Device priority | `testCurrentDeviceIsPreferredWithDevicesFallback` |
| Older phone tokens / pending taps | `testOlderPhoneTokenCannotReplaceWatchToken`, `testOlderPhoneFallbackCannotReplaceWatchToken`, `testSameSideContextPreservesPendingControls` |
| Wrong password message | `testPasswordGrant400401403ShowsWrongPassword` |
| Double launch load | `testLoadGateCoalescesLaunchAndSceneActive` |
| Password isolation | `testWatchContextRoundTripOmitsPassword` |
| Refresh, retry, throttle, partner privacy | `testConcurrentRefreshUsesOneGrant`, `test401RefreshesAndRetriesOnce`, `testSecond401IsNotRetried`, `test429HonorsRetryAfterAndBlocksFurtherRequests`, `testRetryAfterHTTPDateAndDefault`, `testPartnerProfile403IsOptional` |

The model decisions and shared state machines are covered by host-less tests; real Eight Sleep service behavior, physical-watch connectivity and haptics require testing with an account/device.

## Signed export (no upload)

Use the Xcode account on this Mac, with automatic signing. Do not pass App Store Connect API-key authentication flags. The committed export options export locally and preserve the timestamp build number.

```sh
~/bin/unlock-keychain.sh && xcodebuild -project EightSleepRemote.xcodeproj \
  -scheme EightSleepRemote -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/EightSleepRemote.xcarchive -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=XPU32D9V4J CODE_SIGN_STYLE=Automatic archive
~/bin/unlock-keychain.sh && xcodebuild -exportArchive \
  -archivePath build/EightSleepRemote.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
```

## Demo mode

Launch either app with `-demo` or `ESR_DEMO=1`. No networking: signed in, Left = Chase (raw 20, on), Right = Partner (raw −20, on), selected side Left. The watch shows Chase · Left, +2, ~87°F. The phone can switch sides and both apps support local demo temperature changes.

## Provenance

This unified revision was written in this repository from the Claude/Opus base (`opus-original`, bd97e0b). It retains Shared, the client actor and single refresh, separate phone/watch models, typed password-free context, host-less tests, crown/debounce/haptic/rollback behavior and four complication families. Grok supplied the visual direction (navy, eyebrow/title/tagline login, pill sign-in, side cards, large number), the serialized-send idea and build hygiene (privacy manifests, separate entitlements, export options). Codex supplied robustness ideas: credential-generation guard, Retry-After backoff and partner-profile 403 tolerance. Neither reference repository was modified or built. The shared cooling color was sampled independently from Eight Sleep’s App Store screenshot; Chase supplied the updated warming red from his screenshot of the real app.
