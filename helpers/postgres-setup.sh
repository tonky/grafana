#!/usr/bin/env bash
# What the postgres_tests and pgvector blocks' images set up
# (devenv/docker/blocks/postgres_tests, devenv/docker/blocks/pgvector):
# superuser grafanatest/grafanatest owning its database (POSTGRES_USER, POSTGRES_PASSWORD),
# setup.sql's grafanadstest (which only grafanatest may connect to), and grafana_vectors
# with the pgvector (`vector`) extension enabled. Idempotent: the service's postStart, on
# every start of a kept data directory too.
set -euo pipefail
port="${1:?usage: postgres-setup.sh <port>}"
psql -h 127.0.0.1 -p "${port}" -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
SELECT 'CREATE ROLE grafanatest SUPERUSER LOGIN PASSWORD ''grafanatest'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafanatest')\gexec
SELECT 'CREATE DATABASE grafanatest OWNER grafanatest'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'grafanatest')\gexec
SELECT 'CREATE DATABASE grafanadstest OWNER grafanatest'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'grafanadstest')\gexec
SELECT 'CREATE DATABASE grafana_vectors OWNER grafanatest'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'grafana_vectors')\gexec
REVOKE CONNECT ON DATABASE grafanadstest FROM PUBLIC;
GRANT CONNECT ON DATABASE grafanadstest TO grafanatest;
SQL
psql -h 127.0.0.1 -p "${port}" -U postgres -d grafanatest -v ON_ERROR_STOP=1 -q \
	-c 'CREATE EXTENSION IF NOT EXISTS vector;'
psql -h 127.0.0.1 -p "${port}" -U postgres -d grafana_vectors -v ON_ERROR_STOP=1 -q \
	-c 'CREATE EXTENSION IF NOT EXISTS vector;'
