# Samsung Reminder for macOS

Unofficial, native macOS client and widget for Samsung Reminder, written in Swift/SwiftUI.
It reads and writes your reminders directly in Samsung Cloud, the same record store the phone app syncs to.

> **Not affiliated with, endorsed by, or supported by Samsung.** It depends on private Samsung Cloud behaviour that can change without notice.
> Protocol knowledge comes from the open-source Windows client [eliasblume/samsung-reminder-desktop](https://github.com/eliasblume/samsung-reminder-desktop) (MIT).

## Features

- Lists, Today / Upcoming / Favorites / Completed views, search
- Complete, favorite, create (with a due time) and delete reminders; changes appear on your phone
- Menu bar panel with the next reminders
- WidgetKit widget (small / medium / large) that deep-links into the app
- Local notifications when a reminder is due
- Incremental sync every N minutes: only changed records are downloaded

## How it gets your data

Samsung Cloud exposes a generic record store at `api.samsungcloud.com/data/v2/<table>`, authenticated with four headers:
`x-sc-uid`, `x-sc-access-token`, `x-sc-app-id` and `x-sc-dvc-id`. Reminders live in the table
`com.samsung.android.app.reminder`, lists in `com.samsung.android.app.reminder.category`.

The Windows client obtains the access token from **Samsung Internet for Windows**: a signed Samsung extension exposes a
private `chrome.credentials` API that mints the token for the signed-in Samsung Account. **That browser does not exist on macOS**,
so this app cannot mint a token itself. Instead you provide the credential once and it is kept in your Keychain.

On a Windows PC with Samsung Internet installed and signed in to your Samsung Account:

1. Open `chrome-extension://bhbojgnklikmfoopegjhgfbklnpbjboa/src/index.html` in a Samsung Internet tab (Samsung's signed Calendar extension).
2. Press F12, and in the Console run:

   ```js
   chrome.credentials.getAccessToken({provider:'samsung'}, t =>
     chrome.credentials.getAccountInfo({provider:'samsung'}, a =>
       console.log(JSON.stringify({accessToken:t, userId:a.identifiers.userId,
         deviceId:crypto.randomUUID(), accountEmail:a.identifiers.loginId}))))
   ```

3. Copy the printed JSON and use **Connect → Paste credential JSON** on the Mac.

Alternatively, run the reference Windows client once: it stores the same JSON in Windows Credential Manager under
`SamsungReminderDesktop.SamsungCloud`. The console recipe has not been verified by the maintainers on Windows; the
reference client issues the same calls through the DevTools protocol, so the extension page's own console is expected to work.

When Samsung expires the token the app returns to the connect screen; nothing else is stored.
Contributions that add a native macOS token source (e.g. a Samsung Account sign-in flow) are welcome, see `ReminderService.connect`.

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

`Config/Local.xcconfig` is git-ignored. App Groups on macOS require a signing team; without one the widget cannot share the snapshot.

## Security

See [SECURITY.md](SECURITY.md). Short version: credential in the Keychain only, ephemeral HTTPS session to one host,
sandboxed app and widget, no telemetry, no third-party dependencies.

## License

[MIT](LICENSE). Samsung, Samsung Cloud and Samsung Reminder are trademarks of their respective owners, used only to describe compatibility.
