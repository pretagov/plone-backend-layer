#!/bin/bash
# plone-backend-layer: settings plone/plone-backend has no env var for, applied
# at container start, then the image's own entrypoint.
#
# For a site whose Postgres suspends (Fly `auto_stop_machines = 'suspend'`,
# reached through the Fly proxy so a request can wake it). Long-lived pooled
# connections are what a suspend leaves dead; these keep them short and notice
# a dead one quickly. Each is opt-in: unset, nothing changes.
#
#   ZODB_POOL_TIMEOUT        seconds an idle ZODB connection (and its database
#                            connections) stays in the pool before it is closed
#   PG_KEEPALIVES_IDLE       libpq TCP keepalives, seconds idle before probing
#   PG_KEEPALIVES_INTERVAL   seconds between probes
#   PG_KEEPALIVES_COUNT      probes lost before the connection is dead
#   PGCONNECT_TIMEOUT        (libpq reads this itself; listed for completeness)
#
# Keepalives go into a libpq service file selected by PGSERVICE: libpq fills
# any parameter the DSN leaves out from it, so RELSTORAGE_DSN stays as it is.
#
# Every edit is anchored and checked: if the base image changes the line this
# looks for, the container fails to start rather than run without the setting.
set -euo pipefail

ETC=/app/etc

if [[ -n "${ZODB_POOL_TIMEOUT:-}" ]]; then
  anchor='cache-size $(ZODB_CACHE_SIZE)'
  for conf in "$ETC/relstorage.conf" "$ETC/zope.conf"; do
    if grep -qF 'pool-timeout $(ZODB_POOL_TIMEOUT)' "$conf"; then
      continue  # a restart: already applied
    fi
    if ! grep -qF "$anchor" "$conf"; then
      echo "plone-backend-layer: expected '$anchor' in $conf; the base image changed." >&2
      exit 1
    fi
    python3 - "$conf" "$anchor" <<'EDIT'
import pathlib, sys
path, anchor = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
line = next(l for l in text.splitlines() if anchor in l)
indent = line[: len(line) - len(line.lstrip())]
path.write_text(text.replace(anchor, f"{anchor}\n{indent}pool-timeout $(ZODB_POOL_TIMEOUT)", 1))
EDIT
  done
fi

if [[ -n "${PG_KEEPALIVES_IDLE:-}${PG_KEEPALIVES_INTERVAL:-}${PG_KEEPALIVES_COUNT:-}" ]]; then
  if [[ -n "${PGSERVICE:-}" ]]; then
    echo "plone-backend-layer: PGSERVICE is already set ($PGSERVICE); the keepalive settings use their own service. Unset one." >&2
    exit 1
  fi
  export PGSERVICEFILE="$ETC/pg_service.conf"
  export PGSERVICE=plone-backend-layer
  {
    echo "[plone-backend-layer]"
    echo "keepalives=1"
    [[ -n "${PG_KEEPALIVES_IDLE:-}" ]] && echo "keepalives_idle=$PG_KEEPALIVES_IDLE"
    [[ -n "${PG_KEEPALIVES_INTERVAL:-}" ]] && echo "keepalives_interval=$PG_KEEPALIVES_INTERVAL"
    [[ -n "${PG_KEEPALIVES_COUNT:-}" ]] && echo "keepalives_count=$PG_KEEPALIVES_COUNT"
  } > "$PGSERVICEFILE"
  chmod 0644 "$PGSERVICEFILE"
fi

exec /app/docker-entrypoint.plone.sh "$@"
