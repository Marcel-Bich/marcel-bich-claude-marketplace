---
bump: minor
---

### Changed

- LAN trusted peers key on the session caption only: the name the user set with `/rename` (registry `nameSource` `user`, letters, digits, space `.` `_` `-`, at most 20 characters). The sending relay resolves it from its own session registry and sends it as `from_caption`; the free-form `from-name` the sending harness writes is display text only and can no longer earn trust. Sessions without a caption can still message but never hold trust
- `trust add <peer> <caption>` stores the caption in exactly the form the sending relay sends (filtered, whitespace collapsed, cut at 20 characters) and says so when that differs from the input, so a longer `/rename` still matches; a name with no caption characters is refused with the rule. `trust remove` accepts the typed or the stored form
- The trust marker is bound to the caption, the receiving session and the time (`from-caption` and `credo-trust-ts` in the opening tag, marker format v2): it verifies only in the session it was made for and for 10 minutes
- The LAN `from-name` is the sender's display name (caption, else short id from the holder; the daemon swaps in its roster-tick name with kitty / tmux labels), filtered to the same character set and capped at 20 characters. A deliver never waits on tmux or kitty
- `trust add` and `trust list` print a WARNING when a caption contains characters that look like plain Latin letters (Cyrillic or Greek lookalikes and similar, or characters NFKC folds, such as fullwidth letters); warning only, every script stays allowed

### Fixed

- `credo_session_name.clean` normalizes to NFC again after filtering, so it is idempotent (a removed character between decomposed Hangul jamo no longer leaves a non-NFC name)
- A message body holding a lone surrogate no longer fails the inject of a trusted deliver (the marker hashes with `surrogatepass`)
- Several registry descriptors on one socket path (a stale one next to the live one): the sending relay uses the live one

### Security

- The sending relay sends a caption only when the process that wrote the message into its proxy socket (`SO_PEERCRED`) is the captioned session's process or a child of it; another local process naming a session's reply socket gets no caption (its message is still delivered, untrusted)
- Duplicate captions fail closed: while 2+ live sessions of the sending relay's profile share a caption (case-insensitive; sessions without a messaging socket count too), the relay sends no caption, trust for it is suspended and the message carries a one-line notice to rename one session. Other profiles on the same machine are not checked yet
- Removing the last trust entry of a peer rotates the trust key, so a re-added grant never revives an older marker
- The trust file is opened without following a symlink and without blocking, and used only when it is a regular file of this user that is not group or world writable; `trust add` / `trust remove` change it under an exclusive lock (`peer-lan-trust.json.lock`) and abort with exit 1, changing nothing, when it exists but is unsafe or cannot be parsed
- The machine label in the hook's trusted-peer text is limited to `A-Z a-z 0-9 . _ -`, at most 24 characters
- Documented limits: same-user processes can read the trust key (the user account is the trust boundary), and a hostile paired relay can claim any caption and omit the duplicate flag (the caption is reported, not cryptographically proven)
- Migration: grants made before this change (keyed on the from-name) no longer match; `trust list` shows them as `LEGACY, inactive`. Give each trusted session a caption with `/rename`, re-add it once with `trust add <peer> <caption> --yes`, then drop the old entry with `trust remove <peer> <old name>`
