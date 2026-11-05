# Samsung Reminder for macOS

Unofficial, native macOS client and widget for Samsung Reminder, written in Swift/SwiftUI.
It reads and writes your reminders directly in Samsung Cloud, the same record store the phone app syncs to.

> **Not affiliated with, endorsed by, or supported by Samsung.** It depends on private Samsung Cloud behaviour that can change without notice.
> Protocol knowledge comes from the open-source Windows client [eliasblume/samsung-reminder-desktop](https://github.com/eliasblume/samsung-reminder-desktop) (MIT).

## Features

- Lists, Today / Upcoming / Favorites / Completed views, search
- Full editing: title, notes, checklists, lists, importance, timed or all-day schedules, repeat rules, early reminders,
  alert strength, place triggers (arrive/leave, address search via MapKit); create, edit and delete lists
- Photo attachments are shown as a count only (Samsung's file storage protocol is not implemented)
- Menu bar panel with the next reminders
- WidgetKit widget (small / medium / large) that deep-links into the app
- Local notifications when a reminder is due
- Incremental sync every N minutes: only changed records are downloaded

## How it gets your data

Samsung Cloud exposes a generic record store at `api.samsungcloud.com/data/v2/<table>`, authenticated with four headers:
`x-sc-uid`, `x-sc-access-token`, `x-sc-app-id` and `x-sc-dvc-id`. Reminders live in the table
`com.samsung.android.app.reminder`, lists in `com.samsung.android.app.reminder.category`.

The Windows client obtains the access token from **Samsung Internet for Windows**, whose signed Calendar extension exposes a
private `chrome.credentials` API. That browser does not exist on macOS, so this app signs in differently:

1. **Sign in with Samsung Account** opens Samsung's own account page in your default browser (the same web flow
   Samsung's Windows apps use, with PKCE and an encrypted service parameter from `getEntryPoint`).
2. Samsung redirects to its registered `ms-app://` callback. This app registers that URL scheme on your Mac, so macOS
   hands the callback straight to it. Your password and second factor never touch the app.
3. The callback is exchanged for a Samsung Account session (`/auth/oauth2/authenticate`), then for an access/refresh token
   pair for the Reminder client (`/auth/oauth2/v2/authorize` + `/auth/oauth2/token`). Tokens are renewed with the refresh
   token, and re-issued from the session when that expires. Everything is stored in the Keychain only.

The sign-in protocol follows [charlesbel/samsung-re-health](https://github.com/charlesbel/samsung-re-health) and
[samsung-re-find](https://github.com/charlesbel/samsung-re-find) (MIT), which run the same flow on Linux. The one assumption
specific to Reminder is that its Samsung Cloud app id `8o8b82h22a` also serves as its OAuth client id, as it does for
Samsung Health. If Samsung rejects that client, the app reports the HTTP status on the connect screen.

**Advanced:** the connect screen also accepts a pasted credential JSON `{"accessToken","userId","deviceId"}`, for example
one exported from the Windows client's Credential Manager entry `SamsungReminderDesktop.SamsungCloud`.

## Architecture

```
Sources/Core/Shared   JSONValue, models, Samsung content XML, snapshot store      (app + widget)
Sources/Core/Cloud    Keychain credential, SamsungCloudClient, ReminderService     (app only)
Sources/App           SwiftUI app, menu bar, settings, notifications
Sources/Widget        WidgetKit extension (reads the snapshot only)
Tests                 XCTest for parsing, models, store, keychain
```

Data flow: `Keychain → SamsungCloudClient → ReminderService.sync() → snapshot.json (App Group) → UI + widget`.

Sync cost per refresh: one listing request (`record_id,mod_timestamp` for up to 500 records), then `ceil(changed / 100)`
`/get` requests for records whose `mod_timestamp` differs from the cache, plus two small requests for lists.
Memory: the raw records of one page (≤ 500) are kept in the service actor so edits can round-trip every field without a re-fetch.

## Build

Requirements: macOS 14+, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM
xcodegen generate
xcodebuild -scheme SamsungReminder -configuration Release build
xcodebuild -scheme SamsungReminder test
```

`Tools/install.sh [Debug|Release]` builds and copies the app into `/Applications` (default Release).
`Config/Local.xcconfig` is git-ignored. App Groups on macOS require a signing team; without one the widget cannot share the snapshot.

## Security

See [SECURITY.md](SECURITY.md). Short version: credential in the Keychain only, ephemeral HTTPS session to one host,
sandboxed app and widget, no telemetry, no third-party dependencies.

## License

[MIT](LICENSE). Samsung, Samsung Cloud and Samsung Reminder are trademarks of their respective owners, used only to describe compatibility.
