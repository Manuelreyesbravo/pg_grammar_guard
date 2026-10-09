#!/usr/bin/env bash
# A throwaway cluster for the script suites (test/pg_temp.sh), built from the
# binaries of the PostgreSQL this extension will be installed into (PG_CONFIG).
# Nothing is installed into that PostgreSQL: the extension is loaded from this
# repo through extension_control_path. Copied from pg_living_assertions.
#
#   test/cluster.sh init | start | psql [args...] | stop
set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$("$PG_CONFIG" --bindir)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA=${GRAMMAR_CLUSTER:-$ROOT/.testcluster}
PORT=${PGPORT:-5494}

# PostgreSQL looks for control files in the `extension/` SUBDIRECTORY of each
# extension_control_path element, the way $system means SHAREDIR/extension.
# This used to point at the repo root, which has no such subdirectory, so the
# element matched nothing and every suite silently ran against the copy
# installed in SHAREDIR -- whatever version was last `make install`ed, not the
# code in this repo. Found when 0.5.0 was written and the test still reported
# 0.4.1's behaviour. Links, not copies, so an edit is seen without re-init; made
# again on start so a new upgrade script is picked up too.
EXT=$DATA/ext
link_extension() {
    rm -rf "$EXT" && mkdir -p "$EXT/extension"
    ln -s "$ROOT"/pg_grammar_guard.control "$ROOT"/pg_grammar_guard--*.sql "$EXT/extension/"
    # pg_living_assertions from a checkout, ahead of the installed one, when LIVING_ASSERTIONS_DIR
    # names one: what this extension runs its watches through is part of what is tested.
    if [ -n "${LIVING_ASSERTIONS_DIR:-}" ]; then
        ln -s "$LIVING_ASSERTIONS_DIR"/pg_living_assertions.control "$LIVING_ASSERTIONS_DIR"/pg_living_assertions--*.sql "$EXT/extension/"
    fi
}

# The harness must be able to say it is testing the wrong thing.
repo_version() {
    sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$ROOT/pg_grammar_guard.control"
}

case "${1:-}" in
  init)
    "$BIN/pg_ctl" -D "$DATA" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
    "$BIN/initdb" -D "$DATA" --auth=trust -E UTF8 >/dev/null
    link_extension
    cat >>"$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '$DATA'
extension_control_path = '$EXT:\$system'
EOF
    echo "initialised $DATA on port $PORT"
    ;;
  start)
    link_extension
    "$BIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
    SEEN=$("$BIN/psql" -X -At -h "$DATA" -p "$PORT" -d postgres -c \
        "select default_version from pg_available_extensions where name = 'pg_grammar_guard'")
    if [ "$SEEN" != "$(repo_version)" ]; then
        echo "the server sees pg_grammar_guard $SEEN, the repo is $(repo_version): not testing this repo" >&2
        exit 1
    fi
    echo "started on port $PORT, loading pg_grammar_guard $SEEN from this repo"
    ;;
  stop)
    "$BIN/pg_ctl" -D "$DATA" -m "${2:-fast}" -w stop >/dev/null
    echo "stopped"
    ;;
  psql)
    shift
    exec "$BIN/psql" -X -h "$DATA" -p "$PORT" "$@"
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac
