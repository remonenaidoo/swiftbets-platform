#!/usr/bin/env bash
# One database and one least-privilege login per owning service. Idempotent: runs at volume init and on every compose up.
set -euo pipefail

role() { echo "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$1') THEN CREATE ROLE $1 LOGIN PASSWORD '$2'; END IF; END \$\$;"; }
database() { echo "SELECT 'CREATE DATABASE $1 OWNER $2' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$1')\\gexec"; }

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" <<SQL
$(role steward_app "${STEWARD_DB_PASSWORD}")
$(role history_app "${HISTORY_DB_PASSWORD}")
$(role notifications_app "${NOTIFICATIONS_DB_PASSWORD}")
$(role config_app "${CONFIG_DB_PASSWORD}")
$(role catalog_app "${CATALOG_DB_PASSWORD}")
$(role casino_catalog_app "${CASINO_CATALOG_DB_PASSWORD}")
$(role risk_app "${RISK_DB_PASSWORD}")
$(database sb_steward steward_app)
$(database sb_history history_app)
$(database sb_notifications notifications_app)
$(database sb_config config_app)
$(database sb_catalog catalog_app)
$(database sb_casino casino_catalog_app)
$(database sb_risk risk_app)
SQL

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname sb_steward -c 'CREATE EXTENSION IF NOT EXISTS vector;'
