#!/usr/bin/env bash
# The Go checks of upstream's go-lint.yml for the changed files: `gofmt -s`, then
# golangci-lint at the version .citools/src/golangci-lint pins (`go tool`, built with the
# environment's Go: a linter built with an older Go refuses go.mod's) with upstream's
# .golangci.yml, on the changed files' packages.
#
#   helpers/go-lint.sh <changed file>...
#
# go.work's modules other than the root are linted by directory (`./pkg/apiserver/...`
# is not part of `./...`), so each package is named by its directory. Files of modules
# go.work leaves out, of modules holding a .nolint file (pkg/build/wire) and generators
# (`//go:build ignore`) are skipped, as upstream's go-lint does.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Upstream lints `go list -m`'s modules but those holding a .nolint file.
nolint="$(for m in $(go_workspace_modules); do if [[ -f "${m}/.nolint" ]]; then printf '%s ' "${m}"; fi; done)"
skipped=" $(go_foreign_modules) ${nolint}"
files=()
while IFS= read -r file; do
    [[ "${file}" == *.go && -f "${file}" ]] || continue
    [[ "${file}" == */testdata/* ]] && continue
    outside=""
    for dir in ${skipped}; do [[ "${file}" == "${dir}/"* ]] && outside=1; done
    [[ -n "${outside}" ]] && continue
    head -n 3 "${file}" | grep -qE '^//go:build .*ignore' && continue
    files+=("${file}")
done < <(repo_paths "$@")
[[ ${#files[@]} -gt 0 ]] || { echo "No Go file to lint"; exit 0; }

unformatted="$(gofmt -s -l "${files[@]}")"
if [[ -n "${unformatted}" ]]; then
    echo "Not gofmt -s formatted (run 'gofmt -s -w'):" >&2
    echo "${unformatted}" >&2
    exit 1
fi

# shellcheck disable=SC2207
dirs=($(for f in "${files[@]}"; do echo "./$(dirname "${f}")"; done | sort -u))
tool=github.com/golangci/golangci-lint/v2/cmd/golangci-lint
# The Makefile asks twice: the first `go tool -n` may name a temporary build directory.
lint="$(cd .citools/src/golangci-lint && GOWORK=off go tool -n "${tool}" >/dev/null && GOWORK=off go tool -n "${tool}")"
echo "🔎 golangci-lint: ${#dirs[@]} package(s)"
exec "${lint}" run --config .golangci.yml "${dirs[@]}"
