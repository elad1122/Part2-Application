#!/usr/bin/env bash
# Prepares the throwaway SonarQube Community server that runs as a service container in the
# SAST job: rotates the default admin password, installs a strict Quality Gate and creates
# a short-lived analysis token. Nothing here outlives the CI run.
set -euo pipefail
H=${SONAR_HOST_URL:-http://localhost:9000}

echo "Waiting for SonarQube to be UP..."
timeout 300 bash -c "until curl -fs $H/api/system/status | grep -q '\"status\":\"UP\"'; do sleep 5; done"
curl -fs "$H/api/system/status"; echo

# 1. Replace the well-known default credentials (admin/admin) with a random password
PW="$(openssl rand -hex 16)Aa1!"
echo "::add-mask::$PW"
curl -fsS -u admin:admin -X POST "$H/api/users/change_password" \
  --data-urlencode login=admin --data-urlencode previousPassword=admin --data-urlencode "password=$PW"
A=(-fsS -u "admin:$PW")

# 2. Classic metrics (bugs / vulnerabilities / hotspots) for the gate conditions
curl "${A[@]}" -X POST "$H/api/settings/set" -d key=sonar.multi-quality-mode.enabled -d value=false

# 3. Strict Quality Gate on OVERALL code.
#    The built-in "Sonar way" gate only checks *new* code, and on a fresh server every run is a
#    first analysis with no new-code baseline, so it would always pass. These conditions apply
#    to the whole codebase on every run.
curl "${A[@]}" -X POST "$H/api/qualitygates/create" -d name=CI-Strict >/dev/null
for cond in vulnerabilities:0 bugs:0 security_hotspots:0 sqale_rating:1; do
  curl "${A[@]}" -X POST "$H/api/qualitygates/create_condition" \
    -d gateName=CI-Strict -d metric="${cond%%:*}" -d op=GT -d error="${cond##*:}" >/dev/null
  echo "gate condition: ${cond%%:*} > ${cond##*:} -> FAIL"
done
curl "${A[@]}" -X POST "$H/api/qualitygates/set_as_default" -d name=CI-Strict

# 4. Analysis token for the scanner (valid only for this server, i.e. this run)
TOKEN=$(curl "${A[@]}" -X POST "$H/api/user_tokens/generate" -d name=ci -d type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)
echo "::add-mask::$TOKEN"
{
  echo "SONAR_TOKEN=$TOKEN"
  echo "SONAR_ADMIN_PW=$PW"
} >> "$GITHUB_ENV"
echo "SonarQube ready: admin password rotated, CI-Strict gate is default, analysis token issued"
