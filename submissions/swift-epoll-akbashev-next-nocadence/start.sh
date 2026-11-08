#!/usr/bin/env bash
# Not for upstream: swift-epoll-akbashev-next's build with the fixed pass length off.
export PASS_US=0
exec "$(cd "$(dirname "$0")" && pwd)/../swift-epoll-akbashev-next/start.sh"
