# Shipshape GitHub Action

Lint the **Dockerfiles and Kubernetes manifests** a pull request changes, right on the diff:

- root in the final stage;
- unpinned base images;
- `curl | sh`;
- secrets in ENV/ARG;
- the Kubernetes **Pod Security Standards** (baseline and restricted);
- resources and probes.

Every finding comes with the line, the fix and the standard behind it. Every file gets an A–F grade.

It calls the [Shipshape API](https://shipshape.hybridforgelab.com) with **your own RapidAPI key**. The free Basic plan
has 15 requests a month, and one file is one request.

```yaml
name: shipshape
on: pull_request
permissions:
  contents: read
  pull-requests: read
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: hybridforgelab/shipshape-action@v1
        with:
          rapidapi-key: ${{ secrets.RAPIDAPI_KEY }}
```

1. Subscribe to the [Shipshape API on RapidAPI](https://rapidapi.com/hybrid-forge-lab-hybrid-forge-lab-default/api/shipshape-dockerfile-and-kubernetes-lint-api)
   (Basic is $0 with a hard limit, so it never runs up a bill).
2. Add your RapidAPI key as the repository secret `RAPIDAPI_KEY`.
3. Add the workflow above.

## What you get

- **Annotations on the pull request diff:**
  - `high` findings as errors, `medium` as warnings, `low` and `info` as notices.
  - Each one has the rule id, the explanation and the fix.
  - GitHub shows at most 10 per level, so high severity comes first.
- **A job summary** with a table per file (grade, score, counts, passed), every finding with its fix and a link to the
  rule, the files that were skipped and why, and the quota you have left.
- **A pass/fail result:** the step fails when a finding is at or above `fail-on` (`high` by default), or when a file grades
  worse than `min-grade`.

## Inputs

| input | default | meaning |
|---|---|---|
| `rapidapi-key` | *required* | your RapidAPI key |
| `mode` | `changed` | `changed`: only the files the pull request (or push) changed; `all`: every matching file |
| `dockerfile-paths` | `**/Dockerfile,**/*.Dockerfile,**/Dockerfile.*,**/Containerfile` | comma-separated globs |
| `kubernetes-paths` | `**/*.yaml,**/*.yml` | comma-separated globs |
| `exclude-paths` | `.github/**,**/templates/**,**/docker-compose*.y*ml,**/compose*.y*ml` | comma-separated globs to skip |
| `fail-on` | `high` | `high`, `medium`, `low`, `info` or `never` |
| `min-grade` | *empty* | also fail when any file grades worse than this (A–F) |
| `ignore` | *empty* | comma-separated rule ids, e.g. `DF-017,K8S-025` |
| `max-requests` | `10` | cap per run; files over it are listed as not analysed |
| `on-quota-exceeded` | `warn` | `warn` or `fail` when the monthly quota runs out |
| `github-token` | `${{ github.token }}` | used to list the files a pull request changed |

## Outputs

`passed`, `worst-grade`, `lowest-score`, `findings-total`, `requests-used`, `quota-remaining`. The last one comes
from RapidAPI's `x-ratelimit-requests-remaining` header.

## Saving requests

One file is one request. A multi-document YAML (`---`) is a single request, up to 500 documents. Before anything is
sent, these files are skipped locally at no cost:

- Dockerfiles without `FROM`;
- YAML without `apiVersion` and `kind` (not a Kubernetes manifest);
- Helm templates (anything with `{{ }}`);
- files over 512 KiB.

With `mode: changed`, a typical pull request costs 1 to 3 requests. When fewer than 3 are left, the action warns you.

## When something goes wrong

| situation | what the action does |
|---|---|
| no key on a pull request from a fork (forks don't get secrets) | warning, step passes |
| key invalid or not subscribed (401/403) | error with the subscribe link, step fails |
| file can't be parsed (422) | error annotation on that file, step fails |
| quota exhausted (429) | `on-quota-exceeded: warn` gives a warning and the step passes; `fail` fails it |
| API down or timing out | one retry, then a warning: **your build is never failed because of us** |

Use `on: pull_request`, not `pull_request_target`. With `pull_request_target`, a pull request from a fork would run
with your secrets. Skipping fork pull requests is the safe default.

## Privacy

The content of each file is sent to the Shipshape API, parsed in memory and discarded. Nothing is stored, and
Dockerfiles and manifests are never logged. See the [privacy policy](https://shipshape.hybridforgelab.com/privacy.html).
Your key is masked in the logs.

## Limits

- Helm charts must be rendered first, for example `helm template … > rendered.yaml`, with `rendered.yaml` matched by `kubernetes-paths`.
- NetworkPolicies, PodDisruptionBudgets and RBAC are not checked, because they need several objects at once.
- A `USER` set inside a third-party base image can't be seen, and the finding says so.
- The runner needs `bash`, `curl`, `jq` and `git`. GitHub-hosted runners have all four.

## Contributing

Issues and pull requests are welcome. See the
[contributing guide](https://github.com/hybridforgelab/.github/blob/main/CONTRIBUTING.md). To work on the action:

```bash
bats tests/                                 # unit tests (curl is faked, no key needed)
shellcheck -x scripts/*.sh tests/bin/curl
actionlint
```

The end-to-end test (`.github/workflows/e2e.yml`) runs the action against the real API monthly, with the
`RAPIDAPI_KEY` secret.

## Licence

MIT. Shipshape itself is a paid API with a free plan, run by [Hybrid Forge Lab](https://hybridforgelab.com).
