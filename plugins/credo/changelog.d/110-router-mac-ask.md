---
bump: patch
---

### Added

- A bound network can hold several router MACs. A new router on a bound WLAN (same WLAN name and subnet) keeps the LAN relay off and the agent asks the user once, with the Ask tool, whether to add the router or not; the answer is recorded with `trust-router --profile <name>` (add) or `trust-router --profile <name> --refuse` (do not add). A refused router is not asked again for that subnet.
- A bound network whose Windows network category is Public (outside `windows_profiles`) gets the same hint, telling the user where to switch the network to Private.
- `check` prints a hint line for both cases, and the new `network-hint` subcommand prints the pending agent text for the SessionStart hook.
- A router refused for a subnet cannot be bound again: `bind` refuses it and `init` offers no bind command for it. `bind` also refuses a profile name that another router already uses, instead of overwriting that profile.
