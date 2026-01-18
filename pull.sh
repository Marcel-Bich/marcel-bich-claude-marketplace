#!/bin/bash

# Pull all git repositories in parent directory

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Pulling all repos in $PARENT_DIR"
echo "================================"

for dir in "$PARENT_DIR"/*/; do
    if [ -d "$dir/.git" ]; then
        repo_name=$(basename "$dir")
        echo -n "$repo_name: "

        output=$(cd "$dir" && git pull 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$output"
        else
            echo "FEHLER"
            echo "$output" | sed 's/^/  /'
        fi
    fi
done

echo "================================"
echo "Fertig"
