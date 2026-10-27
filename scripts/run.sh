#!/usr/bin/env bash
# Shipshape GitHub Action: lint the Dockerfiles and Kubernetes manifests a change touches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh"

PRICING="https://rapidapi.com/hybrid-forge-lab-hybrid-forge-lab-default/api/shipshape-dockerfile-and-kubernetes-lint-api/pricing"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results.jsonl"
: > "$RESULTS"

output() { printf '%s=%s\n' "$1" "$2" >> "$OUT"; }
record() { jq -cn "$@" >> "$RESULTS"; } # one JSON object per file

# 1. Preflight
for tool in curl jq git; do
  command -v "$tool" >/dev/null || { echo "::error::Shipshape needs $tool on the runner."; exit 1; }
done
case "${INPUT_FAIL_ON:-high}" in high|medium|low|info|never) ;; *)
  echo "::error::fail-on must be high, medium, low, info or never (got '${INPUT_FAIL_ON}')."; exit 1;; esac
case "${INPUT_ON_QUOTA_EXCEEDED:-warn}" in warn|fail) ;; *)
  echo "::error::on-quota-exceeded must be warn or fail."; exit 1;; esac
MIN_GRADE="$(printf '%s' "${INPUT_MIN_GRADE:-}" | tr '[:lower:]' '[:upper:]')"
if [[ -n $MIN_GRADE && ! $MIN_GRADE =~ ^[A-F]$ ]]; then echo "::error::min-grade must be one of A–F."; exit 1; fi
MAX_REQ="${INPUT_MAX_REQUESTS:-10}"
[[ $MAX_REQ =~ ^[0-9]+$ ]] || { echo "::error::max-requests must be a whole number."; exit 1; }

if [[ -z ${INPUT_RAPIDAPI_KEY:-} && -z ${SHIPSHAPE_AUTH_HEADER:-} ]]; then
  if [[ ${GITHUB_EVENT_NAME:-} == pull_request* ]]; then
    echo "::warning::Shipshape skipped: no rapidapi-key. Pull requests from forks don't get repository secrets."
    output passed true; output requests-used 0
    exit 0
  fi
  echo "::error::rapidapi-key is empty. Subscribe to the Shipshape API (free Basic plan) at $PRICING and store the key as a secret."
  exit 1
fi
[[ -n ${INPUT_RAPIDAPI_KEY:-} ]] && echo "::add-mask::$INPUT_RAPIDAPI_KEY"

# 2. Discover files
mode="${INPUT_MODE:-changed}"
if [[ $mode == changed ]]; then
  set +e; files="$(changed_files)"; rc=$?; set -e
  if [[ $rc -eq 2 ]]; then
    echo "::notice::No pull request or push diff for this event: linting every matching file."
    files="$(all_files)"
  elif [[ $rc -ne 0 ]]; then
    echo "::warning::Couldn't list the changed files (GitHub API): linting every matching file."
    files="$(all_files)"
  fi
elif [[ $mode == all ]]; then
  files="$(all_files)"
else
  echo "::error::mode must be changed or all."; exit 1
fi

# 3. Local pre-filter (no request spent)
candidates=()
while IFS= read -r f; do
  [[ -z $f ]] && continue
  type="$(classify "$f")"
  [[ -z $type ]] && continue
  reason="$(prefilter "$type" "$f")"
  if [[ -n $reason ]]; then
    record --arg file "$f" --arg reason "skipped: $reason" '{file: $file, reason: $reason}'
    continue
  fi
  candidates+=("$type|$f")
done <<<"$files"

# 4–5. One request per file
requests=0 quota="" all_passed=true stop=""
for c in ${candidates[@]+"${candidates[@]}"}; do
  type="${c%%|*}"; f="${c#*|}"
  if [[ -n $stop ]]; then
    record --arg file "$f" --arg reason "not analysed: $stop" '{file: $file, reason: $reason}'; continue
  fi
  if (( requests >= MAX_REQ )); then
    record --arg file "$f" --arg reason "not analysed: max-requests ($MAX_REQ) reached" '{file: $file, reason: $reason}'; continue
  fi
  body="$WORK/body.json"; headers="$WORK/headers.txt"
  code="$(lint "$type" "$f" "$body" "$headers")"; requests=$((requests + 1))
  if [[ $code == 000 || $code =~ ^5 ]]; then
    sleep "${SHIPSHAPE_RETRY_DELAY:-5}"
    code="$(lint "$type" "$f" "$body" "$headers")"; requests=$((requests + 1))
  fi
  q="$(header_value "$headers" x-ratelimit-requests-remaining)"; [[ -n $q ]] && quota="$q"
  case "$code" in
    200)
      p="$(jq -r '.passed' "$body")"; grade="$(jq -r '.grade' "$body")"
      ok=true; [[ $p == true ]] || ok=false
      if [[ -n $MIN_GRADE ]] && grade_worse "$grade" "$MIN_GRADE"; then ok=false; fi
      [[ $ok == true ]] || all_passed=false
      record --arg file "$f" --argjson passed "$ok" --slurpfile r "$body" '{file: $file, passed: $passed, report: $r[0]}'
      ;;
    401|403)
      msg="$(jq -r '.message // empty' "$body" 2>/dev/null || true)"
      echo "::error::Shipshape refused the key (HTTP $code${msg:+: $msg}). Subscribe (free Basic plan) at $PRICING."
      record --arg file "$f" --arg reason "not analysed: key refused (HTTP $code)" '{file: $file, reason: $reason}'
      all_passed=false; stop="key refused"
      ;;
    413)
      echo "::warning file=$f::Shipshape skipped this file: request too large."
      record --arg file "$f" --arg reason "skipped: request too large (HTTP 413)" '{file: $file, reason: $reason}'
      ;;
    422)
      detail="$(jq -r '.detail | if type == "string" then . else tostring end' "$body" 2>/dev/null || echo "invalid input")"
      line="$(grep -oE 'line [0-9]+' <<<"$detail" | head -1 | grep -oE '[0-9]+' || true)"
      echo "::error file=$f${line:+,line=$line},title=Shipshape could not parse this file::$detail"
      record --arg file "$f" --arg reason "invalid: $detail" '{file: $file, reason: $reason}'
      all_passed=false
      ;;
    429)
      if [[ ${INPUT_ON_QUOTA_EXCEEDED:-warn} == fail ]]; then
        echo "::error::Shipshape monthly quota exhausted. Upgrade at $PRICING."; all_passed=false
      else
        echo "::warning::Shipshape monthly quota exhausted: the remaining files were not linted. Upgrade at $PRICING."
      fi
      record --arg file "$f" --arg reason "not analysed: quota exhausted (HTTP 429)" '{file: $file, reason: $reason}'
      stop="quota exhausted"
      ;;
    *)
      echo "::warning::Shipshape API unavailable (HTTP $code): the remaining files were not linted. Your build is not failed because of it."
      record --arg file "$f" --arg reason "not analysed: API unavailable (HTTP $code)" '{file: $file, reason: $reason}'
      stop="API unavailable"
      ;;
  esac
done

# 6. Annotations
jq -s '[.[] | select(.report)]' "$RESULTS" | jq -r -f "$HERE/annotate.jq"

# 7. Summary
if [[ -n $quota && $quota =~ ^[0-9]+$ ]] && (( quota < 3 )); then
  echo "::warning::Only $quota Shipshape requests left this month. Plans: $PRICING"
fi
jq -s --argjson passed "$all_passed" --arg requests "$requests" --arg quota "$quota" \
  --arg fail_on "${INPUT_FAIL_ON:-high}" --arg min_grade "$MIN_GRADE" \
  '{results: ., passed: $passed, requests: $requests, quota: $quota, fail_on: $fail_on, min_grade: $min_grade}' "$RESULTS" \
  | jq -r -f "$HERE/summary.jq" >> "$SUMMARY"

# 8. Outputs and exit code
stats="$(jq -s '[.[] | select(.report)] | {
  worst: (map(.report.grade) | sort | last // ""),
  lowest: (map(.report.score) | min // ""),
  total: (map(.report.summary.total) | add // 0)}' "$RESULTS")"
output passed "$all_passed"
output worst-grade "$(jq -r '.worst' <<<"$stats")"
output lowest-score "$(jq -r '.lowest' <<<"$stats")"
output findings-total "$(jq -r '.total' <<<"$stats")"
output requests-used "$requests"
output quota-remaining "$quota"
n_ok="$(jq -s '[.[] | select(.report)] | length' "$RESULTS")"
echo "Shipshape: $n_ok file(s) analysed, $requests request(s), passed=$all_passed${quota:+, $quota left this month}"
if [[ $all_passed != true ]]; then
  # say why, instead of leaving only GitHub's generic "Process completed with exit code 1"
  n_fail="$(jq -s '[.[] | select(.report and (.passed | not))] | length' "$RESULTS")"
  n_invalid="$(jq -s '[.[] | select(.reason // "" | startswith("invalid:"))] | length' "$RESULTS")"
  why=()
  (( n_fail > 0 )) && why+=("$n_fail of $n_ok analysed file(s) failed (fail-on: ${INPUT_FAIL_ON:-high}${MIN_GRADE:+, min-grade: $MIN_GRADE})")
  (( n_invalid > 0 )) && why+=("$n_invalid file(s) could not be parsed")
  if (( ${#why[@]} > 0 )); then
    msg="$(IFS='; '; echo "${why[*]}")"
    echo "::error title=Shipshape check failed::$msg. The job summary lists every finding with its fix."
  fi
fi
[[ $all_passed == true ]]
