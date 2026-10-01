#!/usr/bin/env bash
# Runs once on first start of the Postgres volume: one database and one least-privilege login per owning service.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<SQL
CREATE ROLE steward_app LOGIN PASSWORD '${STEWARD_DB_PASSWORD}';
CREATE ROLE history_app LOGIN PASSWORD '${HISTORY_DB_PASSWORD}';
CREATE ROLE notifications_app LOGIN PASSWORD '${NOTIFICATIONS_DB_PASSWORD}';
CREATE ROLE config_app LOGIN PASSWORD '${CONFIG_DB_PASSWORD}';
CREATE DATABASE sb_steward OWNER steward_app;
CREATE DATABASE sb_history OWNER history_app;
CREATE DATABASE sb_notifications OWNER notifications_app;
CREATE DATABASE sb_config OWNER config_app;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname sb_steward -c 'CREATE EXTENSION IF NOT EXISTS vector;'
