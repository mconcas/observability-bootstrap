#!/bin/bash
# Runs inside the MariaDB container on first start (initdb.d).
# Creates the three InfoLogger DB users with the passwords that the
# InfoLogger server container expects via its environment variables.
# Keep the passwords in sync with docker-compose.yml.

set -e

mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" "${MARIADB_DATABASE}" <<'SQL'
-- Server user: inserts messages + reads for online subscription
CREATE USER IF NOT EXISTS 'infoLoggerServer'@'%' IDENTIFIED BY 'ilgserver';
GRANT SELECT, INSERT, UPDATE ON INFOLOGGER.* TO 'infoLoggerServer'@'%';

-- Admin user: full access (used by admindb to create/archive/drop tables)
CREATE USER IF NOT EXISTS 'infoLoggerAdmin'@'%' IDENTIFIED BY 'ilgadmin';
GRANT ALL PRIVILEGES ON INFOLOGGER.* TO 'infoLoggerAdmin'@'%';

-- Browser / bridge user: read-only
CREATE USER IF NOT EXISTS 'infoBrowser'@'%' IDENTIFIED BY 'ilgbrowser';
GRANT SELECT ON INFOLOGGER.* TO 'infoBrowser'@'%';

FLUSH PRIVILEGES;
SQL

echo "InfoLogger DB users created."
