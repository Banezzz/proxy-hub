#!/usr/bin/env bash
set -euo pipefail

trap '' TERM
printf '%s\n' "$$" >/srv/resistant.pid
while :; do
    printf 'tick\n' >>/srv/resistant.log
    sleep 0.1
done
