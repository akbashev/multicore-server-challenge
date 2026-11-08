#!/usr/bin/env bash
# Not for upstream: swift-epoll-akbashev-next's build with #201's bcrypt window (fixed at the first job, capped).
export BCRYPT_WAIT=capped
exec "$(cd "$(dirname "$0")" && pwd)/../swift-epoll-akbashev-next/start.sh"
