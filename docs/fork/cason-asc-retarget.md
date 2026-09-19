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
