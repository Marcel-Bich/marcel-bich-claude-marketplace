#!/usr/bin/env bash
# credo-reminder.sh turn|start - credo plugin hook entry of the periodic reminder
# (scripts/credo-reminder.py). "turn" is the UserPromptSubmit turn counter, "start" the
# SessionStart start of the worker of an armed session. The reminder is ON by default (the
# builtin template holds the defaults); the settings come from the credo config (key reminder).
#
# Cost when switched off. Before python or credo-config.sh run, a cheap shell check reads
# reminder.enabled from the user config layers in the order credo-config.sh resolves them
# (project, then profile, then global; the builtin template says true). When the layer that
# decides says false, the hook exits at once and nothing is counted or written. Every other
# case runs python, which decides from the merged config. The project layer is resolved the
# way credo-config.sh resolves it: CREDO_PROJECT, CREDO_DIR, the session pin, the git
# toplevel of the session dir, else the session dir itself.
#
# Always exits 0 - a hook never blocks a prompt or a session start.
set -u

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0
case "${1:-}" in
    turn|start) ;;
    *) exit 0 ;;
esac

reminder_enabled_value() { # file -> the reminder.enabled value (lower case), or nothing
    [ -f "$1" ] || return 0
    awk '
        function value(s,   m) {
            if (match(s, /enabled[ \t]*:[ \t]*[^ \t#,}]+/) == 0) return ""
            m = substr(s, RSTART, RLENGTH)
            sub(/^enabled[ \t]*:[ \t]*/, "", m)
            return m
        }
        /^reminder:/ { inblock = 1; v = value($0); if (v != "") { print v; exit }; next }
        /^[^[:space:]#]/ { inblock = 0 }
        inblock && /^[[:space:]]+enabled[[:space:]]*:/ { print value($0); exit }
    ' "$1" | tr -d ' \t"\047' | tr 'A-Z' 'a-z'
}

reminder_layers() { # sets project_cfg, profile_cfg, global_cfg: the paths credo-config.sh reads
    local sid pin_root pinned base top
    sid="$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -n "$sid" ] || sid="${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    pin_root="${CREDO_SESSION_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-projects}"
    pinned=""
    case "$sid" in
        ""|.|..|*[!A-Za-z0-9._-]*) ;;
        *) [ -f "$pin_root/$sid" ] && pinned="$(sed -n '1p' "$pin_root/$sid" 2>/dev/null | tr -d '\r')" ;;
    esac
    [ -n "$pinned" ] && [ -d "$pinned" ] || pinned=""
    base="${CLAUDE_PROJECT_DIR:-}"
    [ -d "$base" ] || base="$PWD"
    top="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ -n "${CREDO_PROJECT:-}" ]; then project_cfg="$CREDO_PROJECT"
    elif [ -n "${CREDO_DIR:-}" ]; then project_cfg="$CREDO_DIR/config"
    elif [ -n "$pinned" ]; then project_cfg="$pinned/.credo/config"
    elif [ -n "$top" ]; then project_cfg="$top/.credo/config"
    else project_cfg="$base/.credo/config"
    fi
    if [ -n "${CREDO_PROFILE:-}" ]; then profile_cfg="$CREDO_PROFILE"
    elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then profile_cfg="${CLAUDE_CONFIG_DIR%/}/credo/config"
    else profile_cfg=""
    fi
    global_cfg="${CREDO_GLOBAL:-$HOME/.claude/credo/config}"
}

reminder_switched_off() { # 0 when the layer that decides reminder.enabled says off
    local f v
    for f in "$project_cfg" "$profile_cfg" "$global_cfg"; do # highest layer first
        [ -n "$f" ] && [ -f "$f" ] || continue
        v="$(reminder_enabled_value "$f")"
        case "$v" in
            "") ;;
            false|no|off|0) return 0 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

reminder_layers
reminder_switched_off && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
printf '%s' "$input" | python3 "$SCRIPT_DIR/../scripts/credo-reminder.py" "$1" >/dev/null 2>&1 || true
exit 0
