#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
git -C "$root_dir" config core.hooksPath .githooks
print "已启用本地推送前构建。"
