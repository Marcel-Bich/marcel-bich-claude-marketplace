# Hermes Tweet

Native Hermes Agent X/Twitter plugin guidance for Xquik automation with read-first workflows and approval-gated actions.

Hermes Tweet is maintained at [Xquik-dev/hermes-tweet](https://github.com/Xquik-dev/hermes-tweet). This marketplace entry installs the Claude Code skill that helps operators choose the right Hermes Tweet workflow, keep reads separate from actions, and avoid passing credentials through chat or tool arguments.

## Install Hermes Tweet

Install the official Hermes plugin on the Hermes runtime host:

```bash
hermes plugins install Xquik-dev/hermes-tweet --enable
```

Then configure `XQUIK_API_KEY` in the Hermes runtime environment or `~/.hermes/.env`.

Keep `HERMES_TWEET_ENABLE_ACTIONS=false` unless a session intentionally needs account-changing actions. When actions are enabled, summarize the exact endpoint and payload before calling `tweet_action`.

## Skill

| Skill          | Purpose                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| `hermes-tweet` | Guides Hermes Tweet install, endpoint discovery, read-only calls, action gating, and safe credential handling. |
