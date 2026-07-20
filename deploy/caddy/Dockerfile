FROM caddy:2-alpine

RUN setcap -r /usr/bin/caddy \
    && test -z "$(getcap /usr/bin/caddy)" \
    && mkdir -p /data /config \
    && chown -R 10001:10001 /data /config

USER 10001:10001
