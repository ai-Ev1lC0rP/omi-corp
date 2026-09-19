# Cason ASC / Codemagic retarget

Ship TestFlight to **OMI_glaDOS** under Apple team `GDR5M938K2`.

| Field | Value |
|-------|-------|
| ASC App ID | `6803648373` |
| Bundle ID (prod) | `com.casonclark.omi` |
| Bundle ID (dev flavor) | `com.casonclark.omi.dev` |
| Development team | `GDR5M938K2` |

## Codemagic (you must create these in the Codemagic UI)

The YAML now references integrations that do **not** exist until you add them:

- App Store Connect integration name: `cason_asc` (ASC API key for team GDR5M938K2, app 6803648373)
- iOS signing certificate/profile group: `cason_ios`
- Watch: `cason_watchos`
- Widget: `cason_widget`

Also register `com.casonclark.omi.dev` (and widget/watch suffixes if used) in Apple Developer → Identifiers if missing.

Firebase still points at Based Hardware projects in stock Codemagic scripts until `.personal_configs/` / your Firebase project is wired.

## Codemagic `firebase` env group (required for iOS builds)

Create a team Environment group named **`firebase`** with:

| Variable | Purpose |
|----------|---------|
| `FIREBASE_SERVICE_ACCOUNT_KEY` | JSON for a service account that can run `flutterfire config` on your **prod** Firebase project |
| `FIREBASE_PROJECT_ID` | Prod Firebase project id (not `based-hardware`) |
| `FIREBASE_SERVICE_ACCOUNT_DEV_KEY` | Service account JSON for the **dev** Firebase project |
| `FIREBASE_PROJECT_DEV_ID` | Dev Firebase project id (not `based-hardware-dev`) |

Register iOS apps `com.casonclark.omi` and `com.casonclark.omi.dev` in those projects before building.

Also keep groups **`app_env`** and **`shorebird`** attached (same names the YAML expects).
