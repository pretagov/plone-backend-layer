# plone-backend-layer

Settings `plone/plone-backend` has no environment variable for, added by one
script — `docker-entrypoint.sh` — that wraps the image's own entrypoint. A site
keeps `FROM plone/plone-backend` and adds the script in its own Dockerfile,
pinned to a commit of this repo and checked by hash:

```dockerfile
FROM plone/plone-backend:6.2.2
# plone-backend-layer (https://github.com/pretagov/plone-backend-layer): env vars
# for settings the image lacks. Pinned: move the commit and hash together.
ADD --checksum=sha256:<sha256 of the file> \
    https://raw.githubusercontent.com/pretagov/plone-backend-layer/<commit>/docker-entrypoint.sh \
    /app/docker-entrypoint.layer.sh
RUN mv /app/docker-entrypoint.sh /app/docker-entrypoint.plone.sh \
 && mv /app/docker-entrypoint.layer.sh /app/docker-entrypoint.sh \
 && chmod 0755 /app/docker-entrypoint.sh
```

The hash for a commit:

```sh
curl -fsSL https://raw.githubusercontent.com/pretagov/plone-backend-layer/<commit>/docker-entrypoint.sh | shasum -a 256
```

Nothing is published to a registry: the build fetches the file, and the build
cache keeps it. The `Dockerfile` here does the same wiring for CI.

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
| --- | --- | --- |
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

The script runs first and hands over to the image's own entrypoint, kept as
`docker-entrypoint.plone.sh`. Wrapping it in place means anything that calls
`./docker-entrypoint.sh` directly (a site's start or release script) gets the
layer too. Each edit is anchored and checked: if a new base image changes the
line it looks for, the container fails to start rather than run without the
setting.

`tests/test.sh` runs in CI against a real Postgres for every Plone version in
`.github/workflows/build.yml`. A plone-backend change upstream to read these
variables itself would make this repo unnecessary.
