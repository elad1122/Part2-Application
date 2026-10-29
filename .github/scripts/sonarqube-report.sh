#!/usr/bin/env bash
# Publishes the SonarQube results of this run: Quality Gate status, issues and security
# hotspots as annotations on the workflow run, plus a table in the job summary.
# (The server is discarded with the job, so this is the durable record.)
set -euo pipefail
H=${SONAR_HOST_URL:-http://localhost:9000}
P=${SONAR_PROJECT_KEY:?}
A=(-fsS -u "admin:${SONAR_ADMIN_PW:?}")

gate=$(curl "${A[@]}" "$H/api/qualitygates/project_status?projectKey=$P")
status=$(jq -r .projectStatus.status <<< "$gate")
measures=$(curl "${A[@]}" "$H/api/measures/component?component=$P&metricKeys=software_quality_security_issues,software_quality_reliability_issues,software_quality_maintainability_issues,software_quality_maintainability_rating,bugs,vulnerabilities,code_smells,sqale_rating,security_hotspots,ncloc")

{
  echo "## SonarQube SAST – Quality Gate: **$status**"
  echo
  echo "| Metric | Value |"; echo "|---|---|"
  jq -r '.component.measures[] | "| \(.metric) | \(.value) |"' <<< "$measures"
  echo
  echo "| Gate condition | Actual | Threshold | Status |"; echo "|---|---|---|---|"
  jq -r '.projectStatus.conditions[] | "| \(.metricKey) | \(.actualValue) | > \(.errorThreshold) fails | \(.status) |"' <<< "$gate"
} >> "$GITHUB_STEP_SUMMARY"

jq -r '.component.measures[] | "\(.metric)=\(.value)"' <<< "$measures" | paste -sd' ' | sed 's/^/::notice title=SonarQube Quality Gate '"$status"'::/'

curl "${A[@]}" "$H/api/issues/search?componentKeys=$P&resolved=false&ps=100" \
  | jq -r '.issues[] | "::warning file=\(.component | split(":")[1]),line=\(.line // 1),title=Sonar \(.type) \(.severity) \(.rule)::\(.message)"'
curl "${A[@]}" "$H/api/hotspots/search?project=$P&ps=100" \
  | jq -r '.hotspots[] | "::warning file=\(.component | split(":")[1]),line=\(.line // 1),title=Sonar security hotspot \(.ruleKey)::\(.message)"'
