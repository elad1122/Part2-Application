#!/usr/bin/env bash



set -euo pipefail
H=${SONAR_HOST_URL:-http://localhost:9000}

api() {
  local auth=$1 method=$2 path=$3; shift 3
  local out code
  out=$(curl -sS -u "$auth" -X "$method" -w '\n%{http_code}' "$H$path" "$@")
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then
    echo "::error title=SonarQube API $method $path -> HTTP $code::$(jq -r '[.errors[]?.msg] | join("; ")' <<< "$out" 2>/dev/null || echo "$out")" >&2
    return 1
  fi
  printf '%s' "$out"
}

echo "Waiting for SonarQube to be UP..."
timeout 300 bash -c "until curl -fs $H/api/system/status | grep -q '\"status\":\"UP\"'; do sleep 5; done"
curl -fs "$H/api/system/status"; echo

DEFAULT_LOGIN=admin
DEFAULT_PASSWORD=$DEFAULT_LOGIN
PW="$(openssl rand -hex 16)Aa1!"
echo "::add-mask::$PW"
api "$DEFAULT_LOGIN:$DEFAULT_PASSWORD" POST /api/users/change_password \
  --data-urlencode "login=$DEFAULT_LOGIN" --data-urlencode "previousPassword=$DEFAULT_PASSWORD" \
  --data-urlencode "password=$PW" >/dev/null
ADMIN="$DEFAULT_LOGIN:$PW"
echo "admin password rotated"


api "$ADMIN" POST /api/qualitygates/create -d name=CI-Strict >/dev/null

for cond in \
  "software_quality_security_issues|vulnerabilities:GT:0" \
  "software_quality_reliability_issues|bugs:GT:0" \
  "security_hotspots_reviewed:LT:100" \
  "software_quality_maintainability_rating|sqale_rating:GT:1"; do
  IFS=: read -r metrics op threshold <<< "$cond"; added=""
  for m in ${metrics/|/ }; do
    if api "$ADMIN" POST /api/qualitygates/create_condition \
         -d gateName=CI-Strict -d metric="$m" -d op="$op" -d error="$threshold" >/dev/null 2>&1; then
      added=$m; break
    fi
  done
  [ -n "$added" ] || { echo "::error::no supported metric among: $metrics" >&2; exit 1; }
  echo "gate condition: $added $op $threshold -> FAIL"
done
api "$ADMIN" POST /api/qualitygates/set_as_default -d name=CI-Strict >/dev/null

TOKEN=$(api "$ADMIN" POST /api/user_tokens/generate -d name=ci -d type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)
echo "::add-mask::$TOKEN"
{
  echo "SONAR_TOKEN=$TOKEN"
  echo "SONAR_ADMIN_PW=$PW"
} >> "$GITHUB_ENV"
echo "SonarQube ready: admin password rotated, CI-Strict gate is default, analysis token issued"
