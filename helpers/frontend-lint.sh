#!/usr/bin/env bash
# The frontend checks of upstream's frontend-lint.yml for the changed files: prettier
# (`yarn run prettier:check`'s extensions) and eslint (`yarn run lint`), with the
# repository's configs, from the repository root.
#
#   helpers/frontend-lint.sh <changed file>...
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

prettier=()
eslint=()
while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    case "${file}" in
        *.ts | *.tsx | *.js | *.cjs) prettier+=("${file}"); eslint+=("${file}") ;;
        *.mjs | *.jsx) eslint+=("${file}") ;;
        *.scss | *.md | *.mdx | *.json) prettier+=("${file}") ;;
    esac
done < <(repo_paths "$@")
[[ ${#prettier[@]} -gt 0 ]] && yarn prettier --check --log-level=warn --ignore-unknown "${prettier[@]}"
[[ ${#eslint[@]} -gt 0 ]] && yarn eslint --no-error-on-unmatched-pattern "${eslint[@]}"
echo "✅ ${#prettier[@]} file(s) formatted, ${#eslint[@]} linted"
