#!/usr/bin/env bash
set -euo pipefail

on_term() {
    trap '' TERM
    bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
    printf '%s\n' "$!" >/srv/late-children.pids
    exit 0
}

trap on_term TERM
printf '%s\n' "$$" >/srv/late-root.pid
while :; do sleep 0.1; done
