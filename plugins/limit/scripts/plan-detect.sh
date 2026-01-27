#!/usr/bin/env bash
# Plan-Detection fuer Limit Plugin
# Gibt NUR subscriptionType und rateLimitTier aus, KEINE Secrets!

# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CREDS_FILE="${CLAUDE_BASE_DIR}/.credentials.json"

if [[ ! -f "${CREDS_FILE}" ]]; then
  echo "unknown"
  exit 0
fi

# Extrahiere NUR die zwei relevanten Felder
TIER=$(jq -r '.claudeAiOauth.rateLimitTier // "unknown"' "${CREDS_FILE}" 2>/dev/null)
SUB=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "${CREDS_FILE}" 2>/dev/null)

# Plan-Detection via Ausschlussverfahren:
# 1. Wenn "20x" enthalten -> max20
# 2. Wenn "5x" enthalten -> max5
# 3. Wenn "pro" enthalten -> pro
# 4. Wenn subscriptionType = "max" -> max5 (Fallback)
# 5. Sonst -> unknown

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
