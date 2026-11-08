#!/usr/bin/env bash
# Not for upstream: swift-epoll-akbashev-next's build with every bcrypt worker at normal priority.
export BCRYPT_NICE=0
exec "$(cd "$(dirname "$0")" && pwd)/../swift-epoll-akbashev-next/start.sh"
