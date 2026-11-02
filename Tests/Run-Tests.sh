#!/usr/bin/env bash
# Applies the schema to a throwaway database on a plain Postgres and runs the
# behaviour tests. Usage:
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=... ./Tests/Run-Tests.sh
#
# Standard libpq environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD)
# are used. The role needs CREATEDB and CREATEROLE. The database is dropped
# when the run ends. Do not point this at a real Supabase project.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="patterns_test_$$"

cleanup() {
    psql -q -d postgres -c "drop database if exists ${DB}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql -q -v ON_ERROR_STOP=1 -d postgres -c "create database ${DB}"

run() {
    psql -q -v ON_ERROR_STOP=1 -d "${DB}" -f "$1"
}

run "${ROOT}/Tests/00-Supabase-Stubs-For-Local-Testing.sql"
for f in "${ROOT}"/Sql/*.sql; do
    echo "applying $(basename "$f")"
    run "$f"
done

psql -v ON_ERROR_STOP=1 -d "${DB}" -f "${ROOT}/Tests/Run-Tests.sql" 2>&1 \
    | sed -e 's/^psql:[^ ]* //' -e 's/^NOTICE:  //'
