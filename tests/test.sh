#!/bin/bash
# Checks an image built from this repo: `tests/test.sh <image> <postgres-dsn>`.
# The DSN must reach a Postgres from inside a container on the host network.
set -euo pipefail

IMAGE=$1
DSN=$2
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { docker run --rm --network host "$@"; }

echo "-- ZODB_POOL_TIMEOUT unset: the config is the base image's"
run "$IMAGE" bash -c '! grep -q pool-timeout /app/etc/relstorage.conf' \
  || fail "pool-timeout written without ZODB_POOL_TIMEOUT"

echo "-- ZODB_POOL_TIMEOUT set: pool-timeout in relstorage.conf and zope.conf"
run -e ZODB_POOL_TIMEOUT=60 "$IMAGE" bash -c '
  grep -qF "pool-timeout \$(ZODB_POOL_TIMEOUT)" /app/etc/relstorage.conf &&
  grep -qF "pool-timeout \$(ZODB_POOL_TIMEOUT)" /app/etc/zope.conf' \
  || fail "pool-timeout not written"

echo "-- a restart does not add it twice"
cid=$(docker create --network host -e ZODB_POOL_TIMEOUT=60 "$IMAGE" bash -c 'grep -c "pool-timeout" /app/etc/relstorage.conf')
docker start -a "$cid" >/dev/null
count=$(docker start -a "$cid")
docker rm "$cid" >/dev/null
[[ "$count" == "1" ]] || fail "pool-timeout written $count times after a restart"

echo "-- keepalives reach libpq, with the DSN unchanged"
params=$(run -e PG_KEEPALIVES_IDLE=30 -e PG_KEEPALIVES_INTERVAL=10 -e PG_KEEPALIVES_COUNT=3 \
  -e PGCONNECT_TIMEOUT=7 -e DSN="$DSN" "$IMAGE" /app/bin/python -c '
import os, psycopg2
p = psycopg2.connect(os.environ["DSN"]).get_dsn_parameters()
print(p["keepalives"], p["keepalives_idle"], p["keepalives_interval"], p["keepalives_count"], p["connect_timeout"])')
[[ "$params" == "1 30 10 3 7" ]] || fail "libpq parameters were: $params"

echo "-- a PGSERVICE of the site's own is not silently replaced"
if run -e PG_KEEPALIVES_IDLE=30 -e PGSERVICE=other "$IMAGE" true 2>/dev/null; then
  fail "started with a conflicting PGSERVICE"
fi

echo "-- Plone starts on RelStorage with all of it on"
cid=$(docker run -d --network host -e RELSTORAGE_DSN="$DSN" \
  -e ZODB_POOL_TIMEOUT=60 -e PG_KEEPALIVES_IDLE=30 -e PGCONNECT_TIMEOUT=7 "$IMAGE" start)
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null http://localhost:8080/; then up=1; break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]]; then break; fi
  sleep 2
done
if [[ "${up:-}" != "1" ]]; then
  docker logs "$cid" | tail -40
  docker rm -f "$cid" >/dev/null
  fail "Plone did not start"
fi
docker rm -f "$cid" >/dev/null

echo "all checks passed"
