package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Grafana's toolchain as its Makefile and GitHub Actions use it: Go from go.mod (CGO off,
// as every backend CI job runs), Node from .nvmrc and Yarn from `packageManager`. Go linters
// and generators are pinned in .citools and built with `go tool`, by the Makefile.
// tests/env_conformance.rs checks the pins against an upstream checkout.
profiles: dev: schema.#Profile & {
	name: "grafana-dev"
	tools: [
		// go.mod, go.work and the Makefile's GO_VERSION: 1.27.3.
		pkgs.go & {version: "1.27.3"},
		// .nvmrc: v24.22.1. Major 24: the snapshot that ships go 1.27.3 has node 24.21.0,
		// and enve locks one nixpkgs release.
		pkgs.nodejs & {version: "24"},
		// `packageManager: yarn@4.18.1`. The repository also commits that release
		// (.yarnrc.yml `yarnPath`), which this yarn hands over to, so corepack never runs.
		{pname: "yarn-berry", version: "4.18.1"},
		// The Makefile stamps builds with git; scripts/ci/backend-tests/*.sh are bash 4
		// (`readarray`) on find, awk and grep: macOS ships bash 3.2 and BSD tools.
		pkgs.git,
		"gnumake",
		"bash",
		"coreutils",
		"findutils",
		"gnugrep",
		"gnused",
		"gawk",
		"diffutils",
		// helpers/go-test.sh's database lock, which the kernel releases when a killed job dies.
		"flock",
		// helpers/playwright.sh polls /api/health with curl; backend/CI scripts invoke jq, curl, and python3.
		"curl",
		"jq",
		"python3",
		// pr-test-integration.yml: `make devenv sources=postgres_tests` (postgres:17.4-alpine)
		// and `sources=mysql_tests mysql_version=8.0.43`. MySQL 8.4 (LTS), not 8.0: nixpkgs
		// dropped mysql80 (last in 26.05pre) before it shipped go 1.27 (26.11pre).
		pkgs.postgresql_17,
		pkgs.mysql & {version: "8.4"},
		// Playwright's headless shell from the store (PLAYWRIGHT_BROWSERS_PATH) at the
		// revision `playwright-core` 1.56.1 expects.
		pkgs.#PlaywrightBrowsers & {version: "1.56.1", features: ["chromium-headless-shell"]},
	]
	services: {
		// devenv/docker/blocks/postgres_tests: superuser grafanatest/grafanatest with its
		// database, `max_connections=200`, data on tmpfs, plus setup.sql's grafanadstest that
		// only grafanatest may connect to. Port 5442, not 5432: the suites read POSTGRES_PORT,
		// and other checkouts' services may hold the default. That is the default instance's
		// (`enve up` by hand): enact runs each run's services in an instance of its own, on free
		// ports, so commands, hooks and values read `$PORT` / `${ENVE_SERVICE_<NAME>_PORT}`.
		// The preset's C collation is upstream's: the alpine image's musl sorts by byte too.
		postgres: {
			package:    pkgs.postgresql_17
			extensions: [{pname: "pgvector", attr: "postgresql17Packages.pgvector"}]
			port:       5442
			command:    "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c max_connections=200 -c fsync=off -c full_page_writes=off -c synchronous_commit=off"
			// The preset creates neither user nor database (initdb -U postgres).
			lifecycle: postStart: "helpers/postgres-setup.sh $PORT"
		}
		// devenv/docker/blocks/mysql_tests: root/rootpass, database grafana_tests with user
		// grafana/password, and setup.sql's grafana_ds_tests; durability off as its compose
		// runs it, and no fsync at all: every test migrates its own tables, and each CREATE
		// TABLE's own tablespace file costs fsyncs, on a VM disk ~6 ms each (Linux VM disks ran the
		// suite 20-40x slower than macOS). One shared tablespace, never synced, runs DDL as
		// fast as tmpfs. Port 3316 for the reason above (MYSQL_PORT).
		mysql: {
			port:    3316
			command: "mysqld --no-defaults --datadir=\"$DATA_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1 --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-flush-method=nosync --innodb-file-per-table=0 --skip-log-bin"
			lifecycle: postStart: "helpers/mysql-setup.sh $PORT"
		}
	}
	environment: {
		// go.mod names its exact Go: build with the pinned one, never download another.
		GOTOOLCHAIN: "local"
		// backend-unit-tests.yml and pr-test-integration.yml: `CGO_ENABLED=0 go test`.
		CGO_ENABLED: "0"
		TZ:          "UTC"
		// Where the suites find the services (pkg/services/sqlstore/sqlstore_testinfra.go,
		// pkg/services/sqlstore/sqlutil, pkg/util/testutil/pgtest,
		// pkg/storage/unified/search/vector/integration_test.go). Credentials and database
		// names stay upstream's defaults. GRAFANA_TEST_DB is a job's choice, not set here.
		POSTGRES_HOST:    "127.0.0.1"
		POSTGRES_PORT:    "${ENVE_SERVICE_POSTGRES_PORT}"
		PGVECTOR_TEST_DB: "host=127.0.0.1 port=${ENVE_SERVICE_POSTGRES_PORT} dbname=grafana_vectors user=grafanatest password=grafanatest sslmode=disable"
		MYSQL_HOST:       "127.0.0.1"
		MYSQL_PORT:       "${ENVE_SERVICE_MYSQL_PORT}"
		// Node 24 still bundles corepack: never prompt headless.
		COREPACK_ENABLE_DOWNLOAD_PROMPT: "0"
	}
}
