#!/usr/bin/env bash
# Prepares the throwaway SonarQube Community server that runs as a service container in the
# SAST job: rotates the default admin password, installs a strict Quality Gate and creates
# a short-lived analysis token. Nothing here outlives the CI run.
set -euo pipefail
H=${SONAR_HOST_URL:-http://localhost:9000}

# api <user:password> <METHOD> <path> [curl data args...] – prints the body; on HTTP error,
# emits an annotation with SonarQube's error message and fails.
api() {
  local auth=$1 method=$2 path=$3; shift 3
  local out code
  out=$(curl -sS -u "$auth" -X "$method" -w '\n%{http_code}' "$H$path" "$@")
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then
    # stderr, so the annotation still shows when the caller discards stdout
    echo "::error title=SonarQube API $method $path -> HTTP $code::$(jq -r '[.errors[]?.msg] | join("; ")' <<< "$out" 2>/dev/null || echo "$out")" >&2
    return 1
  fi
  printf '%s' "$out"
}

echo "Waiting for SonarQube to be UP..."
timeout 300 bash -c "until curl -fs $H/api/system/status | grep -q '\"status\":\"UP\"'; do sleep 5; done"
curl -fs "$H/api/system/status"; echo

# 1. Replace the factory-default admin credentials with a random password
DEFAULT_LOGIN=admin
DEFAULT_PASSWORD=$DEFAULT_LOGIN          # SonarQube's documented first-start default
PW="$(openssl rand -hex 16)Aa1!"
echo "::add-mask::$PW"
api "$DEFAULT_LOGIN:$DEFAULT_PASSWORD" POST /api/users/change_password \
  --data-urlencode "login=$DEFAULT_LOGIN" --data-urlencode "previousPassword=$DEFAULT_PASSWORD" \
  --data-urlencode "password=$PW" >/dev/null
ADMIN="$DEFAULT_LOGIN:$PW"
echo "admin password rotated"

# 2. Strict Quality Gate on OVERALL code.
#    The built-in "Sonar way" gate only checks *new* code, and on a fresh server every run is a
#    first analysis with no new-code baseline, so it would always pass. These conditions apply
#    to the whole codebase on every run.
#    SonarQube 2025+ defaults to MQR mode (software-quality metrics); older/Standard mode uses the
#    classic metrics. Each condition tries the MQR metric first, then the classic equivalent.
api "$ADMIN" POST /api/qualitygates/create -d name=CI-Strict >/dev/null
for cond in \
  "software_quality_security_issues|vulnerabilities:0" \
  "software_quality_reliability_issues|bugs:0" \
  "security_hotspots|security_hotspots:0" \
  "software_quality_maintainability_rating|sqale_rating:1"; do
  metrics=${cond%%:*}; threshold=${cond##*:}; added=""
  for m in ${metrics/|/ }; do
    if api "$ADMIN" POST /api/qualitygates/create_condition \
         -d gateName=CI-Strict -d metric="$m" -d op=GT -d error="$threshold" >/dev/null 2>&1; then
      added=$m; break
    fi
  done
  [ -n "$added" ] || { echo "::error::no supported metric among: $metrics" >&2; exit 1; }
  echo "gate condition: $added > $threshold -> FAIL"
done
api "$ADMIN" POST /api/qualitygates/set_as_default -d name=CI-Strict >/dev/null

# 4. Analysis token for the scanner (valid only for this server, i.e. this run)
TOKEN=$(api "$ADMIN" POST /api/user_tokens/generate -d name=ci -d type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)
echo "::add-mask::$TOKEN"
{
  echo "SONAR_TOKEN=$TOKEN"
  echo "SONAR_ADMIN_PW=$PW"
} >> "$GITHUB_ENV"
echo "SonarQube ready: admin password rotated, CI-Strict gate is default, analysis token issued"
