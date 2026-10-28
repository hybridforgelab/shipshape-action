#!/usr/bin/env bats
# Unit tests: run.sh against a fake curl that answers with real recorded API responses.

ROOT="$BATS_TEST_DIRNAME/.."

setup() {
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock" REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$MOCK_DIR" "$REPO"
  cp -R "$ROOT/tests/fixtures/repo/." "$REPO/"
  (cd "$REPO" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
  cp "$ROOT/tests/responses/dockerfile_200.json" "$MOCK_DIR/body_200_dockerfile"
  cp "$ROOT/tests/responses/kubernetes_200.json" "$MOCK_DIR/body_200_kubernetes"
  cp "$ROOT/tests/responses/kubernetes_422.json" "$MOCK_DIR/body_422"
  cp "$ROOT/tests/responses/rapidapi_401.json" "$MOCK_DIR/body_401"
  cp "$ROOT/tests/responses/rapidapi_403.json" "$MOCK_DIR/body_403"
  cp "$ROOT/tests/responses/rapidapi_429.json" "$MOCK_DIR/body_429"
  echo '{"message":"Internal Server Error"}' > "$MOCK_DIR/body_503"
  echo '{"detail":"request body too large"}' > "$MOCK_DIR/body_413"
  echo 200 > "$MOCK_DIR/status_dockerfile"
  echo 200 > "$MOCK_DIR/status_kubernetes"
  export PATH="$ROOT/tests/bin:$PATH"
  export INPUT_RAPIDAPI_KEY=test-key INPUT_MODE=all INPUT_FAIL_ON=high INPUT_MIN_GRADE="" INPUT_IGNORE=""
  export INPUT_MAX_REQUESTS=10 INPUT_ON_QUOTA_EXCEEDED=warn INPUT_GITHUB_TOKEN=gh-token
  export INPUT_DOCKERFILE_PATHS="**/Dockerfile,**/*.Dockerfile,**/Dockerfile.*,**/Containerfile"
  export INPUT_KUBERNETES_PATHS="**/*.yaml,**/*.yml"
  export INPUT_EXCLUDE_PATHS=".github/**,**/templates/**,**/docker-compose*.y*ml,**/compose*.y*ml"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=acme/app GITHUB_API_URL=https://api.github.com
  export SHIPSHAPE_RETRY_DELAY=0
  unset SHIPSHAPE_API_URL SHIPSHAPE_AUTH_HEADER
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
}

run_action() { cd "$REPO" && run "$ROOT/scripts/run.sh"; }
out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
requests() { grep -c . "$MOCK_DIR/requests.log" 2>/dev/null || echo 0; }

# ---------- classification and pre-filter ----------

@test "globs: **/ also matches at the root, excludes win, unquoted lists never glob the disk" {
  source "$ROOT/scripts/lib.sh"
  cd "$REPO"
  [ "$(classify Dockerfile)" = dockerfile ]
  [ "$(classify app/api.Dockerfile)" = dockerfile ]
  [ "$(classify k8s/deployment.yaml)" = kubernetes ]
  [ -z "$(classify helm/templates/deployment.yaml)" ]
  [ -z "$(classify compose/docker-compose.yml)" ]
  [ -z "$(classify .github/workflows/ci.yml)" ]
  [ -z "$(classify README.md)" ]
}

@test "globs: /**/ also matches no folder at all" {
  source "$ROOT/scripts/lib.sh"
  glob_match app/Dockerfile 'app/**/Dockerfile'
  glob_match app/api/Dockerfile 'app/**/Dockerfile'
  glob_match deploy/k8s/web.yaml 'deploy/**/*.yaml'
  glob_match deploy/web.yaml 'deploy/**/*.yaml'
  ! glob_match other/Dockerfile 'app/**/Dockerfile'
}

@test "pre-filter: no FROM, not Kubernetes, Helm, too large" {
  source "$ROOT/scripts/lib.sh"
  cd "$REPO"
  [ -z "$(prefilter dockerfile Dockerfile)" ]
  [ "$(prefilter dockerfile broken/Dockerfile)" = "no FROM instruction" ]
  [ "$(prefilter kubernetes config/settings.yaml)" = "not a Kubernetes manifest" ]
  [ "$(prefilter kubernetes helm/templates/deployment.yaml)" = "Helm template (render it first)" ]
  head -c 600000 /dev/zero | tr '\0' 'a' > big.yaml
  [ "$(prefilter kubernetes big.yaml)" = "larger than 512 KiB" ]
  [ "$(prefilter kubernetes missing.yaml)" = "not found" ]
}

@test "grades: F is worse than A" {
  source "$ROOT/scripts/lib.sh"
  grade_worse D C
  ! grade_worse B C
  ! grade_worse C C
}

# ---------- a normal run ----------

@test "lints the Dockerfile and the manifest, annotates, fails on the high finding" {
  echo 41 > "$MOCK_DIR/quota"
  rm "$REPO/k8s/broken.yaml"
  run_action
  [ "$status" -eq 1 ]
  [ "$(out passed)" = false ]
  [ "$(out worst-grade)" = D ]
  [ "$(out lowest-score)" = 42 ]
  [ "$(out findings-total)" = 23 ]
  [ "$(out requests-used)" = 2 ]
  [ "$(out quota-remaining)" = 41 ]
  [[ $output == *"::error file=Dockerfile,line=1,title=DF-001 Final stage never sets USER%2C so the container runs as root::"* ]]
  [[ $output == *"::warning file=k8s/deployment.yaml,line=18,title=K8S-009"* ]]
  [ "$(grep -c '^::notice' <<<"$output")" -eq 10 ]   # capped: GitHub shows at most 10 per level
  grep -q '| `Dockerfile` | D | 54 | 1 | 1 | 6 | 2 | ❌ |' "$GITHUB_STEP_SUMMARY"
  grep -q '| `broken/Dockerfile` | skipped: no FROM instruction |' "$GITHUB_STEP_SUMMARY"
  grep -q 'quota left this month: 41' "$GITHUB_STEP_SUMMARY"
  [[ $output == *"::error title=Shipshape check failed::1 of 2 analysed file(s) failed (fail-on: high)."* ]]
}

@test "passes when nothing is at or above fail-on" {
  rm "$REPO/Dockerfile" "$REPO/k8s/broken.yaml"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out passed)" = true ]
}

@test "min-grade fails a file that passed the API but grades worse" {
  rm "$REPO/Dockerfile" "$REPO/k8s/broken.yaml"
  INPUT_MIN_GRADE=c run_action
  [ "$status" -eq 1 ]
  [ "$(out passed)" = false ]
  [[ $output == *"1 of 1 analysed file(s) failed (fail-on: high, min-grade: C)"* ]]
}

@test "fail-on and ignore are sent in the request body" {
  rm "$REPO/k8s/deployment.yaml" "$REPO/k8s/broken.yaml"
  INPUT_FAIL_ON=medium INPUT_IGNORE=" DF-017 , DF-005" run_action
  grep -q '"fail_on":"medium"' "$MOCK_DIR/requests.log"
  grep -q '"ignore":\["DF-017","DF-005"\]' "$MOCK_DIR/requests.log"
}

@test "no matching files: passes without a request" {
  rm -r "$REPO"/*
  touch "$REPO/README.md"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out requests-used)" = 0 ]
  grep -q 'No Dockerfile or Kubernetes manifest was analysed' "$GITHUB_STEP_SUMMARY"
}

# ---------- error handling ----------

@test "422: error annotation on the file at the reported line" {
  rm "$REPO/Dockerfile" "$REPO/k8s/deployment.yaml"
  echo 422 > "$MOCK_DIR/status_kubernetes"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error file=k8s/broken.yaml,line=5,title=Shipshape could not parse this file::invalid YAML at line 5"* ]]
  [[ $output == *"::error title=Shipshape check failed::1 file(s) could not be parsed."* ]]
}

@test "401/403: error with the subscribe link, and no more requests" {
  echo 403 > "$MOCK_DIR/status_dockerfile"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"Shipshape refused the key (HTTP 403: You are not subscribed to this API.)"* ]]
  [ "$(requests)" -eq 1 ]
  grep -q 'not analysed: key refused' "$GITHUB_STEP_SUMMARY"
}

@test "429 with on-quota-exceeded=warn: warning, build not failed" {
  rm "$REPO/k8s/broken.yaml"
  echo 429 > "$MOCK_DIR/status_dockerfile"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning::Shipshape monthly quota exhausted"* ]]
  [ "$(requests)" -eq 1 ]
  grep -q 'not analysed: quota exhausted' "$GITHUB_STEP_SUMMARY"
}

@test "429 with on-quota-exceeded=fail: build fails" {
  echo 429 > "$MOCK_DIR/status_dockerfile"
  INPUT_ON_QUOTA_EXCEEDED=fail run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::Shipshape monthly quota exhausted"* ]]
}

@test "5xx: one retry, then a warning and the build is not failed by us" {
  rm "$REPO/k8s/broken.yaml"
  printf '503\n503\n' > "$MOCK_DIR/status_dockerfile"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"Shipshape API unavailable (HTTP 503)"* ]]
  [ "$(out requests-used)" = 2 ]
}

@test "a 5xx that recovers on the retry is analysed normally" {
  rm "$REPO/k8s/broken.yaml" "$REPO/k8s/deployment.yaml"
  printf '503\n200\n' > "$MOCK_DIR/status_dockerfile"
  run_action
  [ "$(out worst-grade)" = D ]
  [ "$(out requests-used)" = 2 ]
}

@test "413: the file is skipped with a warning" {
  rm "$REPO/k8s/broken.yaml" "$REPO/k8s/deployment.yaml"
  echo 413 > "$MOCK_DIR/status_dockerfile"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning file=Dockerfile::Shipshape skipped this file"* ]]
}

@test "max-requests caps the run and lists the rest as not analysed" {
  INPUT_MAX_REQUESTS=1 run_action
  [ "$(out requests-used)" = 1 ]
  grep -q 'not analysed: max-requests (1) reached' "$GITHUB_STEP_SUMMARY"
}

@test "warns when fewer than 3 requests are left" {
  echo 2 > "$MOCK_DIR/quota"
  rm "$REPO/k8s/broken.yaml"
  run_action
  [[ $output == *"::warning::Only 2 Shipshape requests left this month"* ]]
}

# ---------- keys and events ----------

@test "no key on a pull request (fork): skipped with a warning" {
  INPUT_RAPIDAPI_KEY="" GITHUB_EVENT_NAME=pull_request run_action
  [ "$status" -eq 0 ]
  [[ $output == *"Shipshape skipped: no rapidapi-key"* ]]
}

@test "no key outside a pull request: error" {
  INPUT_RAPIDAPI_KEY="" GITHUB_EVENT_NAME=push run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::rapidapi-key is empty"* ]]
}

@test "the key is masked" {
  rm "$REPO/k8s/broken.yaml"
  run_action
  [[ $output == *"::add-mask::test-key"* ]]
}

@test "mode=changed on a pull request lints only the files the PR changed" {
  echo '{"pull_request":{"number":7}}' > "$BATS_TEST_TMPDIR/event.json"
  echo '[{"filename":"Dockerfile","status":"modified"},{"filename":"k8s/deployment.yaml","status":"removed"},{"filename":"README.md","status":"added"}]' > "$MOCK_DIR/github.json"
  INPUT_MODE=changed GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json" run_action
  [ "$(out requests-used)" = 1 ]
  grep -q '| `Dockerfile` | D |' "$GITHUB_STEP_SUMMARY"
  ! grep -q 'k8s/deployment.yaml' "$GITHUB_STEP_SUMMARY"
}

@test "mode=changed without a diff (workflow_dispatch) falls back to every file" {
  rm "$REPO/k8s/broken.yaml"
  INPUT_MODE=changed run_action
  [[ $output == *"linting every matching file"* ]]
  [ "$(out requests-used)" = 2 ]
}

@test "invalid inputs are refused" {
  INPUT_FAIL_ON=critical run_action;   [ "$status" -eq 1 ]; [[ $output == *"fail-on must be"* ]]
  INPUT_MIN_GRADE=G run_action;        [ "$status" -eq 1 ]; [[ $output == *"min-grade must be"* ]]
  INPUT_MAX_REQUESTS=ten run_action;   [ "$status" -eq 1 ]; [[ $output == *"max-requests must be"* ]]
  INPUT_MODE=some run_action;          [ "$status" -eq 1 ]; [[ $output == *"mode must be"* ]]
  INPUT_ON_QUOTA_EXCEEDED=x run_action; [ "$status" -eq 1 ]; [[ $output == *"on-quota-exceeded must be"* ]]
}
