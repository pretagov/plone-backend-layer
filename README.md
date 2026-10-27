# plone-backend-layer

`plone/plone-backend`, plus the settings it has no environment variable for.
Same image otherwise — same entrypoint, same `CMD`, same commands — so a site
switches by changing one line:

```dockerfile
FROM ghcr.io/pretagov/plone-backend-layer:6.2.2
```

Images are published for each Plone version listed in
`.github/workflows/build.yml`. Add a version there to get its image.

## A database that suspends

On Fly, a Postgres app can suspend when idle (`auto_stop_machines = 'suspend'`)
and be woken by the next connection — but only connections through the Fly
proxy (`<app>.flycast`) wake it, so the site must keep connecting that way.

What breaks is long-lived connections. A pooled connection held across a
suspend is dead on the other side; Postgres's own `idle_session_timeout` kills
idle ones too. The cure is the one SQLAlchemy users reach for with
`pool_pre_ping` and `pool_recycle`: keep connections short, and notice a dead
one quickly.

Set these in the site's `fly.toml` `[env]` (all opt-in; unset changes nothing):

| Variable | What it sets | Suggested |
|---|---|---|
| `ZODB_POOL_TIMEOUT` | `pool-timeout` on the main ZODB: an idle connection, and its database connections, is closed after this many seconds. Keep it below Postgres's `idle_session_timeout`. | `60` |
| `PG_KEEPALIVES_IDLE` | libpq TCP keepalive: seconds idle before probing | `30` |
| `PG_KEEPALIVES_INTERVAL` | seconds between probes | `10` |
| `PG_KEEPALIVES_COUNT` | probes lost before the connection is dead | `3` |
| `PGCONNECT_TIMEOUT` | libpq's own variable: seconds to wait for a connection | `10` |

The keepalives are written to a libpq service file selected with `PGSERVICE`;
libpq fills any parameter the DSN does not give from it, so the
`RELSTORAGE_DSN` secret stays as it is.

Note the trade: ZODB keeps its object cache per connection, so a connection
closed by `pool-timeout` takes its cache with it, and the first requests after
a quiet spell refill it.

## How it works

`docker-entrypoint.sh` here replaces the image's own, which is kept as
`docker-entrypoint.plone.sh` and run last. Anything that calls
`./docker-entrypoint.sh` directly (a site's start or release script) gets the
layer too. Each edit is anchored and checked: if a new base image changes the
line it looks for, the container fails to start rather than run without the
setting.

`tests/test.sh` runs in CI against a real Postgres for every version.
