# Dogma Permissions

Configure what Claude is allowed to do autonomously.
Mark with `[x]` to allow, `[ ]` to block.

<permissions>
## Git Operations
- [ ] May run `git add` autonomously
- [ ] May run `git commit` autonomously
- [ ] May run `git push` autonomously

## File Operations
- [ ] May delete files autonomously (rm, unlink, git clean)
- [ ] Ask before deleting (instead of logging to TO-DELETE.md)
</permissions>

## Behavior When Blocked

| Permission | If [ ] (blocked) |
|------------|------------------|
| git add | Claude cannot stage files |
| git commit | Claude cannot create commits |
| git push | Claude cannot push to remote |
| delete files | Logged to TO-DELETE.md, delete manually |
| ask before deleting | Shows confirmation prompt before delete |
