#!/usr/bin/env bash
# e2e:build, what every Playwright shard runs against, built once (the job's `outputs`;
# upstream's build-backend and build-frontend jobs): grafana-server (bin/grafana), the
# frontend bundle (public/build), the test plugins (e2e-playwright/test-plugins/*/dist) and
# the catalog plugins start-server links (data/plugins-bundled, a download).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

make build-go
yarn build
yarn e2e:plugin:build
make build-catalog-plugins-data
