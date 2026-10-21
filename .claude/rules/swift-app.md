---
paths:
  - "app/**"
---

# The Handfree Code app (Swift)

- Done only when `sh app/install.sh` builds it (outside the sandbox). It signs with the installed app's identity, so macOS keeps its permissions: do not change how it picks it.
- Interface text is written in English; every new string gets its French line in `app/Resources/fr.lproj/Localizable.strings` and its German line in `de.lproj`. A string with a value in it uses `%@` in its key.
- The plugin's paths and settings come from `Plugin.swift`: `supportDir`, `configPath`, `pluginConfig()`, `bridgeAddress()`. No path written out again.
- One file per part (listed in docs/architecture.md, *The app*); a new part gets its own file with a header comment.
- The local server (`Server.swift`) refuses requests with an `Origin` or another `Host`; anything that types, pastes or presses keys needs the app's secret.
- Swift 5.10 and WhisperKit 0.9.4 (Xcode 15): no newer language features.
