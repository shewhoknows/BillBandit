#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${RAILWAY_TOKEN:-}" || -z "${RAILWAY_SERVICE_ID:-}" ]]; then
  echo "::error::Set RAILWAY_TOKEN and RAILWAY_SERVICE_ID for the production Railway project."
  exit 1
fi

args=(--service "$RAILWAY_SERVICE_ID" --environment "${RAILWAY_ENVIRONMENT:-production}" --ci)
if [[ -n "${RAILWAY_PROJECT_ID:-}" ]]; then
  args+=(--project "$RAILWAY_PROJECT_ID")
fi

if railway up "${args[@]}"; then
  exit 0
else
  result=$?
  echo "::error::Railway deploy failed (exit $result). If Railway rejected the token, replace it with a project token scoped to the production environment."
  exit "$result"
fi
