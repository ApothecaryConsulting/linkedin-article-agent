#!/bin/sh
set -e

if [ -n "$NGROK_AUTHTOKEN" ]; then
    if [ -n "$NGROK_DOMAIN" ]; then
        ngrok http --domain="$NGROK_DOMAIN" "${N8N_PORT:-5678}" &
    else
        ngrok http "${N8N_PORT:-5678}" &
    fi
fi

exec n8n
