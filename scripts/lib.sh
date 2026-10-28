#!/usr/bin/env bash
# Functions used by run.sh; sourced by the bats tests too.

SHIPSHAPE_HOST="shipshape-dockerfile-and-kubernetes-lint-api.p.rapidapi.com"
MAX_BYTES=524288 # the API rejects content over 512 KiB
GRADES="ABCDEF"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# glob_match PATH PATTERN: shell-style pattern; a leading "**/" also matches at the repository root.
glob_match() {
  local path="$1" pattern="$2"
  # Explicit ifs: bash 3.2 (macOS runners) with `set -e` exits on a failed `[[ ]] && return` at the end of a block.
  # shellcheck disable=SC2053 # the right-hand side is a pattern on purpose
  if [[ $path == $pattern ]]; then return 0; fi
  if [[ $pattern == '**/'* ]]; then
    # shellcheck disable=SC2053
    if [[ $path == ${pattern#'**/'} ]]; then return 0; fi
  fi
  # "/**/" also matches no folder at all: app/**/Dockerfile matches app/Dockerfile
  if [[ $pattern == *'/**/'* ]]; then
    local slash=/ zero
    zero="${pattern//\/\*\*\//$slash}" # a variable: escaping "/" in the replacement differs between bash versions
    # shellcheck disable=SC2053
    if [[ $path == $zero ]]; then return 0; fi
  fi
  return 1
}

# matches_any PATH "glob1,glob2,…"
matches_any() {
  local path="$1" list="$2" p pats=()
  # read, not `for p in $list`: an unquoted list would also be expanded against the files on disk
  IFS=',' read -r -a pats <<<"$list"
  for p in ${pats[@]+"${pats[@]}"}; do
    p="$(trim "$p")"
    if [[ -n $p ]] && glob_match "$path" "$p"; then return 0; fi
  done
  return 1
}

# classify PATH → "dockerfile", "kubernetes" or "" (excluded or no match)
classify() {
  local path="$1"
  if matches_any "$path" "${INPUT_EXCLUDE_PATHS:-}"; then return 0; fi
  if matches_any "$path" "${INPUT_DOCKERFILE_PATHS:-}"; then echo dockerfile; return 0; fi
  if matches_any "$path" "${INPUT_KUBERNETES_PATHS:-}"; then echo kubernetes; fi
  return 0
}

# prefilter TYPE FILE → empty when the file should be linted, else the reason to skip it (no request spent)
prefilter() {
  local type="$1" file="$2"
  if [[ ! -f $file ]]; then echo "not found"; return 0; fi
  if (( $(wc -c < "$file") > MAX_BYTES )); then echo "larger than 512 KiB"; return 0; fi
  if [[ $type == dockerfile ]]; then
    if ! grep -qiE '^[[:space:]]*FROM[[:space:]]' "$file"; then echo "no FROM instruction"; fi
    return 0
  fi
  if grep -q '{{' "$file"; then echo "Helm template (render it first)"; return 0; fi
  if ! grep -qE '^[[:space:]]*apiVersion:' "$file" || ! grep -qE '^[[:space:]]*kind:' "$file"; then
    echo "not a Kubernetes manifest"
  fi
  return 0
}

gh_api() { # gh_api PATH → JSON on stdout
  curl -sS --fail --max-time 30 \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}/$1"
}

# changed_files: the files the triggering pull request / push changed (not deleted ones), one per line.
# Returns 2 when the event has no usable diff, so the caller can fall back to every file.
changed_files() {
  local event="${GITHUB_EVENT_NAME:-}" ev="${GITHUB_EVENT_PATH:-}" repo="${GITHUB_REPOSITORY:-}"
  if [[ $event == pull_request* && -f $ev ]]; then
    local n page=1 batch
    n="$(jq -r '.pull_request.number' "$ev")"
    while :; do
      batch="$(gh_api "repos/$repo/pulls/$n/files?per_page=100&page=$page")" || return 1
      jq -r '.[] | select(.status != "removed") | .filename' <<<"$batch"
      [[ $(jq 'length' <<<"$batch") -lt 100 ]] && break
      page=$((page + 1))
    done
    return 0
  fi
  if [[ $event == push && -f $ev ]]; then
    local before after
    before="$(jq -r '.before // empty' "$ev")"; after="$(jq -r '.after // empty' "$ev")"
    [[ -z $before || $before =~ ^0+$ || -z $after ]] && return 2
    gh_api "repos/$repo/compare/$before...$after" | jq -r '.files[]? | select(.status != "removed") | .filename' || return 1
    return 0
  fi
  return 2
}

all_files() { git ls-files 2>/dev/null; }

# lint TYPE FILE OUT_BODY OUT_HEADERS → prints the HTTP status ("000" when the request itself failed)
lint() {
  local type="$1" file="$2" out="$3" headers="$4" body ignore
  ignore="$(jq -cn --arg s "${INPUT_IGNORE:-}" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  body="$(jq -cRs --arg fail_on "${INPUT_FAIL_ON:-high}" --argjson ignore "$ignore" \
    '{content: ., fail_on: $fail_on} + (if ($ignore | length) > 0 then {ignore: $ignore} else {} end)' "$file")"
  local url="${SHIPSHAPE_API_URL:-https://$SHIPSHAPE_HOST}/v1/$type"
  local auth=(-H "X-RapidAPI-Key: ${INPUT_RAPIDAPI_KEY:-}" -H "X-RapidAPI-Host: $SHIPSHAPE_HOST")
  # SHIPSHAPE_API_URL / SHIPSHAPE_AUTH_HEADER let the tests and maintainers call the API directly
  [[ -n ${SHIPSHAPE_AUTH_HEADER:-} ]] && auth=(-H "$SHIPSHAPE_AUTH_HEADER")
  local code
  code="$(printf '%s' "$body" | curl -sS --max-time 60 -o "$out" -D "$headers" -w '%{http_code}' \
    -X POST "$url" "${auth[@]}" -H "Content-Type: application/json" --data-binary @- 2>/dev/null)" || code="000"
  printf '%s' "${code:-000}"
}

# header_value HEADERS_FILE NAME (case-insensitive) → value or empty
header_value() { awk -v n="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" -F': *' \
  'tolower($1) == n { sub(/\r$/, "", $2); v = $2 } END { if (v != "") print v }' "$1" 2>/dev/null; }

# grade_worse A B → true when grade A is worse than B (F is the worst)
grade_worse() {
  local a="${GRADES%%"$1"*}" b="${GRADES%%"$2"*}"
  (( ${#a} > ${#b} ))
}
