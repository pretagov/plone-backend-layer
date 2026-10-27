# plone/plone-backend, plus the settings it has no env var for
# (docker-entrypoint.sh). Same image otherwise: same ENTRYPOINT path, same CMD,
# same commands — a site switches by changing its FROM line.
ARG PLONE_VERSION
FROM plone/plone-backend:${PLONE_VERSION}

# The original keeps running every command; the layer runs first and hands
# over. Wrapping it in place means anything that calls ./docker-entrypoint.sh
# directly (a site's own start or release script) gets the layer too.
RUN mv /app/docker-entrypoint.sh /app/docker-entrypoint.plone.sh
COPY --chmod=0755 docker-entrypoint.sh /app/docker-entrypoint.sh
