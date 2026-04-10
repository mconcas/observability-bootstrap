-- Runs inside the MariaDB container on first start (initdb.d).
-- Creates the three InfoLogger DB users.
-- Keep passwords in sync with the infologger-server environment variables.

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
