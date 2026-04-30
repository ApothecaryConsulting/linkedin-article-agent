FROM n8nio/n8n:latest

USER root

ARG TARGETARCH=amd64

RUN wget -q "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${TARGETARCH}.tgz" \
        -O /tmp/ngrok.tgz \
    && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin \
    && rm /tmp/ngrok.tgz

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
