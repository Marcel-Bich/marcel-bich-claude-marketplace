#!/usr/bin/env bash
# Plan detection for Limit Plugin
# Outputs ONLY subscriptionType and rateLimitTier, NO secrets!

# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CREDS_FILE="${CLAUDE_BASE_DIR}/.credentials.json"

if [[ ! -f "${CREDS_FILE}" ]]; then
  echo "unknown"
  exit 0
fi

# Extract ONLY the two relevant fields
TIER=$(jq -r '.claudeAiOauth.rateLimitTier // "unknown"' "${CREDS_FILE}" 2>/dev/null)
SUB=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "${CREDS_FILE}" 2>/dev/null)

# Plan detection by elimination:
# 1. If "20x" is present -> max20
# 2. If "5x" is present -> max5
# 3. If "pro" is present -> pro
# 4. If subscriptionType = "max" -> max5 (fallback)
# 5. Otherwise -> unknown

if [[ "${TIER}" == *"20x"* ]]; then
  echo "max20"
elif [[ "${TIER}" == *"5x"* ]]; then
  echo "max5"
elif [[ "${TIER}" == *"pro"* ]] || [[ "${SUB}" == "pro" ]]; then
  echo "pro"
elif [[ "${SUB}" == "max" ]]; then
  echo "max5"
else
  echo "unknown"
fi
