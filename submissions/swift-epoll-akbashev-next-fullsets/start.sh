#!/usr/bin/env bash
# Not for upstream: swift-epoll-akbashev-next's build with the merged entry's bcrypt wait (full lane sets, no cap).
export BCRYPT_WAIT=full
exec "$(cd "$(dirname "$0")" && pwd)/../swift-epoll-akbashev-next/start.sh"
