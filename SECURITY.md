# Security

Report vulnerabilities through GitHub's private vulnerability reporting on this repository.
Never attach access tokens, user IDs, device IDs, reminder contents or unredacted logs to a public issue.

## What the app stores

| Data | Where | Notes |
| --- | --- | --- |
| Samsung Cloud credential (access token, user id, device id) | macOS login Keychain, item scoped to the app's bundle id | Never written to disk elsewhere, never logged, never shown (only a masked `••••1234` hint). |
| Reminder snapshot (titles, notes, due dates, lists) | App Group container, `snapshot.json`, file protection on | Read by the widget. Deleted on disconnect. |
| Settings (refresh interval, notification toggle) | `UserDefaults` | No personal data. |

## Network

The app talks only to `https://api.samsungcloud.com` over App Transport Security defaults, with an ephemeral `URLSession`
(no cookie or cache persistence) and a 20 s request timeout. The widget extension has no network entitlement.

## Sandbox

Both the app and the widget run in the macOS App Sandbox with hardened runtime. The app has `network.client`
and the shared App Group; the widget has only the App Group.

## Known limitations

- A credential pasted into the app is as sensitive as a password. Anyone with it can read and write your reminders until Samsung expires it.
- Deleting a reminder is guarded by a confirmation dialog and a matching-id check, but it is still a permanent cloud delete.
