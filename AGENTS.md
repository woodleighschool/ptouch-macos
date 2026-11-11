# Working here

This is a headless macOS print bridge for Brother P-touch printers. Follow the sibling WoodBox, Plinth and assetcache-exporter repositories for project, tooling and release conventions.

- The Xcode project and shared scheme own build settings, signing and test selection. Mise owns tools and tasks; read `.mise/config.toml` before running them.
- launchd owns service lifetime. Installation and discovery own queue setup. Do not add an application-opening prerequisite or a permanent UI to make printing work.
- Keep device capabilities in printer profiles. The tested printer and label are verification evidence, not product-wide defaults. Do not claim unverified models work.
- Keep document artwork and application-specific data outside the bridge. Validate the whole PDF and loaded cassette before sending tape commands.
- Use Swift 6 strict concurrency. Keep Bluetooth callbacks, CUPS and process handling at the printing boundary.
- Bind queues to device identities and serialize jobs per printer. Complete jobs only after the printer reports completion. Never retry a possibly printed job automatically.
- Bind IPP to loopback and run Bluetooth access in the user session. The helper bundle exists for signing and macOS privacy identity.
- Tests use synthetic documents, devices and protocol requests. Hardware checks consume tape only when explicitly intended.
- Use the shared Lefthook, Renovate and Release Please configuration and organisation Apple release actions.
- Keep changes small, preserve unrelated work and avoid speculative abstractions. Comments explain constraints; source and configuration carry the ordinary facts.
- Do not commit, push or publish unless asked. Distinguish local verification from signed and notarized distribution.
