#!/bin/bash
# Token-safe remote URL extraction
# Strips tokens from HTTPS URLs, SSH URLs remain unchanged
#
# Usage:
#   git-remote-safe.sh [url|host|owner|repo|owner-repo]
#
# Examples:
#   git-remote-safe.sh url        -> https://github.com/owner/repo.git (token stripped)
#   git-remote-safe.sh host       -> github.com
#   git-remote-safe.sh owner      -> owner
#   git-remote-safe.sh repo       -> repo
#   git-remote-safe.sh owner-repo -> owner/repo

MODE="${1:-url}"

# Read URL from .git/config and strip token (between :// and @)
RAW_URL=$(grep -m1 "url = " .git/config 2>/dev/null | sed 's/.*url = //')
SAFE_URL=$(echo "$RAW_URL" | sed -E 's|(https?://)[^@]+@|\1|')

case "$MODE" in
    url)
        echo "$SAFE_URL"
        ;;
    host)
        # SSH: git@host:path -> host
        # HTTPS: https://host/path -> host
        echo "$SAFE_URL" | sed -E 's|^[^@]*@([^:/]+).*|\1|; s|^https?://([^/]+).*|\1|'
        ;;
    owner)
        echo "$SAFE_URL" | sed -E 's|.*[:/]([^/]+)/[^/]+(\.git)?$|\1|'
        ;;
    repo)
        echo "$SAFE_URL" | sed -E 's|.*[:/][^/]+/([^/]+)(\.git)?$|\1|'
        ;;
    owner-repo)
        echo "$SAFE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|'
        ;;
    *)
        echo "Usage: $0 [url|host|owner|repo|owner-repo]" >&2
        exit 1
        ;;
esac
