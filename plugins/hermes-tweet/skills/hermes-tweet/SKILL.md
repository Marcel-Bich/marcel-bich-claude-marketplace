---
name: hermes-tweet
version: 0.1.6
author: Xquik
description: Use Xquik from Hermes Agent for X search, posting, replies, likes, reposts, follows, DMs, monitors, extraction jobs, draws, media, and trends.
tags:
    - hermes-agent
    - xquik
    - twitter
    - x
    - social-media
    - automation
metadata:
    version: 0.1.6
    author: Xquik
    tags:
        - hermes-agent
        - xquik
        - twitter
        - x
        - social-media
        - automation
---

# Hermes Tweet

Use Hermes Tweet when a Hermes Agent workflow needs X/Twitter data or controlled account actions through Xquik.

## When to Use

Use this skill for social listening, launch monitoring, support triage, creator research, brand research, giveaway audits, community audits, and controlled publishing workflows.

Use `tweet_explore` first when the user asks for a capability, endpoint, route, or Xquik API surface. Use `tweet_read` only after a read-only endpoint is known. Use `tweet_action` only after the user requests a write, private read, monitor, webhook, extraction job, giveaway draw, or media operation that requires action permissions.

## Workflow

1. Use `tweet_explore` to find the endpoint.
2. Use `tweet_read` for public read-only endpoints.
3. Use `tweet_action` only for writes or private reads after stating the exact endpoint and payload.

## Decision Rules

- IF the task is endpoint discovery, THEN call `tweet_explore` with a short query.
- IF the endpoint method is `GET` and the catalog does not mark it as an action, THEN call `tweet_read`.
- IF the endpoint method is not `GET`, or the route touches private account state, THEN call `tweet_action` only when actions are enabled and the user has approved the operation.
- IF `tweet_action` is unavailable or disabled, THEN explain that action tools are intentionally gated by `HERMES_TWEET_ENABLE_ACTIONS=true`.
- IF `XQUIK_API_KEY` is missing, THEN ask the user to set it in the Hermes runtime environment without requesting the key value in chat.
- IF Hermes lists the plugin as `not enabled`, THEN tell the user to run `hermes plugins enable hermes-tweet` or reinstall with `--enable`.
- IF the user is in Hermes Desktop with a remote gateway profile, THEN remind them that Hermes Tweet must be installed, enabled, and configured on the remote Hermes host where plugin tools execute.
- IF the workflow is unattended, scheduled, gateway-driven, or cron-driven, THEN prefer `tweet_read` and keep `tweet_action` disabled unless the workflow has a clear approval step.

## Safety

- Never ask for or reveal API keys, signing keys, passwords, cookies, or TOTP secrets.
- Never pass credentials in tool arguments.
- Use only catalog-listed `/api/v1/...` endpoints.
- Copied endpoint URLs are accepted only when they resolve to catalog-listed paths.
- Do not use account connection, re-authentication, API key, billing, credit top-up, or support-ticket endpoints.
- For posting, deleting, following, DMs, profile changes, monitors, webhooks, extraction jobs, and draws, summarize the action before calling `tweet_action`.

## Install

Install the official plugin on the Hermes runtime host:

```bash
hermes plugins install Xquik-dev/hermes-tweet --enable
```

Set `XQUIK_API_KEY` in the runtime environment or `~/.hermes/.env`. Keep `HERMES_TWEET_ENABLE_ACTIONS=false` unless the session intentionally needs account-changing actions.

## Testing

After installing or upgrading the plugin in Hermes Agent:

1. Run `hermes plugins enable hermes-tweet` unless the install used `--enable`.
2. Run `hermes plugins list` and confirm the plugin is `enabled`.
3. Run `hermes tools list` and confirm the `hermes-tweet` toolset is enabled.
4. Confirm `tweet_explore` is available without `XQUIK_API_KEY`.
5. Confirm `tweet_read` appears only when `XQUIK_API_KEY` is configured.
6. Confirm `tweet_action` stays hidden or disabled unless `HERMES_TWEET_ENABLE_ACTIONS=true`.
