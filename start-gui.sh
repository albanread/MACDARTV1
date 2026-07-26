#!/usr/bin/env bash
#
# Launch the MACDART workspace GUI (see WORKSPACE_PLAN.md).
#
#   ./start-gui.sh                 run it in the foreground (Ctrl-C or Cmd-Q quits)
#   ./start-gui.sh -b              run it detached, logging to /tmp
#   ./start-gui.sh -r              rebuild dartui first
#   ./start-gui.sh -f              start from a fresh image (the old one is kept)
#
# `dartui` is the GUI host: the `dart` binary plus a thread-0 AppKit host, so the
# UI isolate runs where AppKit is legal. It takes the workspace script as its
# entry point; workspace.dart and language.dart are plain runtime scripts, so
# editing them needs no rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DARTUI="$ROOT/macdart/build/dartui"
UI_SCRIPT="$ROOT/macdart/cocoa/workspace/workspace.dart"
IMAGE="$HOME/.macdart/workspace.sqlite"
PORT=7644                       # the workspace's loopback control socket
LOG=/tmp/macdart-gui.log

background=0 rebuild=0 fresh=0
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--background) background=1 ;;
    -r|--rebuild)    rebuild=1 ;;
    -f|--fresh)      fresh=1 ;;
    -h|--help)       sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "start-gui.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$rebuild" = 1 ]; then
  if [ ! -f "$ROOT/macdart/build/build.ninja" ]; then
    echo "start-gui.sh: $ROOT/macdart/build is not configured; run cmake there first" >&2
    exit 1
  fi
  echo "building dartui…"
  ninja -C "$ROOT/macdart/build" dartui
fi

if [ ! -x "$DARTUI" ]; then
  echo "start-gui.sh: no dartui at $DARTUI" >&2
  echo "  build it with: ./start-gui.sh --rebuild" >&2
  exit 1
fi

# A second instance cannot bind the control socket, so stop before we confuse
# two windows sharing one image.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "start-gui.sh: something is already listening on 127.0.0.1:$PORT" >&2
  echo "  the workspace is probably already running — quit it first (Cmd-Q), or:" >&2
  echo "    printf 'quit\\n' | nc -w1 127.0.0.1 $PORT" >&2
  exit 1
fi

# The image is the source of truth for your classes; never delete it silently.
if [ "$fresh" = 1 ] && [ -f "$IMAGE" ]; then
  stamp="$IMAGE.$(date +%Y%m%d-%H%M%S).bak"
  mv "$IMAGE" "$stamp"
  echo "kept the previous image as $stamp"
fi

# Analyze shells out to a dart binary beside dartui for a full --compile_all
# check; without one it reports that it is unavailable rather than guessing.
if [ ! -x "$ROOT/macdart/build-release/dart" ] && [ ! -x "$ROOT/macdart/build/dart" ]; then
  echo "note: no dart binary found for the Editor's Analyze button" >&2
fi

echo "image:   $IMAGE"
echo "control: 127.0.0.1:$PORT   (e.g. printf 'snap /tmp/x.png\\n' | nc -w1 127.0.0.1 $PORT)"

if [ "$background" = 1 ]; then
  nohup "$DARTUI" "$UI_SCRIPT" >"$LOG" 2>&1 </dev/null &
  echo "started in the background (pid $!), logging to $LOG"
else
  exec "$DARTUI" "$UI_SCRIPT"
fi
