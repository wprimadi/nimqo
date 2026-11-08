#!/bin/sh
# Builds the app and launches it through Launch Services, which brings the
# window to the front. Quit with Cmd+Q. If
# NIMQO is already open, it is brought forward instead of starting again.
# Logs (zsh has its own `log`): /usr/bin/log stream --predicate 'subsystem BEGINSWITH "app.nimqo"'
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/scripts/build-app.sh"
open "$root/app/build/Build/Products/Debug/NIMQO.app"
