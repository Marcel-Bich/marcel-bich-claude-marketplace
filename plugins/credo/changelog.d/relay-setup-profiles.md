---
bump: minor
---

### Added

- LAN relay `profiles` subcommand (`list`, `set <name>...`, `add <name>`, `all`) to choose which Claude Code profiles the one machine relay serves
- LAN relay setup asks which profiles to serve (step 2, default: all found) and stores the choice in the machine config
- `onboarding --state --dir` also prints the directory of the machine config, used by the autostart hook

### Changed

- The LAN relay serves the profiles listed in the machine config's `profiles` key; without the key every discovered profile is served, as before
- A session in a served sibling profile starts the one machine relay with the machine config; no second config or daemon is created
- A profile the machine config does not serve gets an add-profile note at session start instead of the setup offer, and `onboarding --state` reports it as `unserved`
- A served profile that does not hold an unbound machine config gets an informational note only; the setup is no longer offered again per profile
- Pairing copies go to the served profiles only; pair-reset still removes the pairing from every profile keystore and trust list
