#!/usr/bin/env bash
# What the mysql_tests block's image sets up (devenv/docker/blocks/mysql_tests): root's
# password rootpass (MYSQL_ROOT_PASSWORD, which the image also grants to root@'%'), database
# grafana_tests with user grafana/password (MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD), and
# setup.sql's grafana_ds_tests for grafana. Idempotent: the service's postStart, on every
# start of a kept data directory too (root has its password by then).
set -euo pipefail
port="${1:?usage: mysql-setup.sh <port>}"
root=(mysql -h 127.0.0.1 -P "${port}" -u root)
if ! "${root[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
    root+=(-prootpass)
fi
"${root[@]}" <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY 'rootpass';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'rootpass';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS grafana_tests;
CREATE DATABASE IF NOT EXISTS grafana_ds_tests;
CREATE USER IF NOT EXISTS 'grafana'@'%' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON grafana_tests.* TO 'grafana'@'%';
GRANT ALL PRIVILEGES ON grafana_ds_tests.* TO 'grafana'@'%';
SQL
