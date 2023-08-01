#!/usr/bin/env sh
set -e

if [ ! -f "/app/tiddlywiki.info" ]; then
    tiddlywiki /app --init server
fi

tiddlywiki /app --listen host=0.0.0.0 username="${USERNAME:-ligus}" password="${PASSWORD-19920320}"
