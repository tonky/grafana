package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Toolchain from Makefile and GitHub Actions: Go from go.mod (CGO off), Node from .nvmrc
// (major 24: the nixpkgs snapshot with go 1.27.3 ships node 24.21.0, not .nvmrc's 24.22.1),
// Yarn from packageManager (handed over to .yarnrc.yml yarnPath so corepack never runs),
// PostgreSQL 17 + pgvector, MySQL 8.4 LTS (nixpkgs dropped mysql80 before go 1.27), and
// Playwright's headless shell from the store. Checked by tests/conformance/env_conformance.rs.
profiles: dev: schema.#Profile & {
	name: "grafana-dev"
	tools: [
		pkgs.go & {version: "1.27.3"},
		pkgs.nodejs & {version: "24"},
		{pname: "yarn-berry", version: "4.18.1"},
		pkgs.git, "gnumake", "bash", "coreutils", "findutils", "gnugrep", "gnused", "gawk", "diffutils",
		"flock", "curl", "jq", "python3",
		pkgs.postgresql_17,
		pkgs.mysql & {version: "8.4"},
		pkgs.#PlaywrightBrowsers & {version: "1.56.1", features: ["chromium-headless-shell"]},
	]
	services: {
		// devenv/docker/blocks/postgres_tests + pgvector; port 5442 default, per-run $PORT in enact.
		postgres: {
			package:    pkgs.postgresql_17
			extensions: [{pname: "pgvector", attr: "postgresql17Packages.pgvector"}]
			port:       5442
			command:    "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c max_connections=200 -c fsync=off -c full_page_writes=off -c synchronous_commit=off"
			lifecycle: postStart: "helpers/postgres-setup.sh $PORT"
		}
		// devenv/docker/blocks/mysql_tests; shared tablespace + nosync avoids per-table DDL fsyncs.
		mysql: {
			port:      3316
			command:   "mysqld --no-defaults --datadir=\"$DATA_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1 --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-flush-method=nosync --innodb-file-per-table=0 --skip-log-bin"
			lifecycle: postStart: "helpers/mysql-setup.sh $PORT"
		}
	}
	environment: {
		GOTOOLCHAIN:                     "local"
		CGO_ENABLED:                     "0"
		TZ:                              "UTC"
		POSTGRES_HOST:                   "127.0.0.1"
		POSTGRES_PORT:                   "${ENVE_SERVICE_POSTGRES_PORT}"
		PGVECTOR_TEST_DB:                "host=127.0.0.1 port=${ENVE_SERVICE_POSTGRES_PORT} dbname=grafana_vectors user=grafanatest password=grafanatest sslmode=disable"
		MYSQL_HOST:                      "127.0.0.1"
		MYSQL_PORT:                      "${ENVE_SERVICE_MYSQL_PORT}"
		COREPACK_ENABLE_DOWNLOAD_PROMPT: "0"
	}
}
