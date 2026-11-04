#!/bin/sh
# Builds the app and launches it through Launch Services, which brings the
# window to the front, passing NIMQO_TEST_PEER along. Quit with Cmd+Q. If
# NIMQO is already open, it is brought forward instead of starting again.
# Logs (zsh has its own `log`): /usr/bin/log stream --predicate 'subsystem BEGINSWITH "app.nimqo"'
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/scripts/build-app.sh"
set --
if [ -n "${NIMQO_TEST_PEER:-}" ]; then
    set -- --env "NIMQO_TEST_PEER=$NIMQO_TEST_PEER"
fi
open "$@" "$root/app/build/Build/Products/Debug/NIMQO.app"
