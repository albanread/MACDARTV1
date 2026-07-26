#!/usr/bin/env bash
#
# Launch the MACDART workspace GUI (see WORKSPACE_PLAN.md).
#
#   ./start-gui.sh                 run it in the foreground (Ctrl-C or Cmd-Q quits)
#   ./start-gui.sh -b              run it detached, logging to /tmp
#   ./start-gui.sh -r              rebuild dartui first
#   ./start-gui.sh -f              start from a fresh image (the old one is kept)
#   ./start-gui.sh --restore       put the last-good UI source back, then run
#   ./start-gui.sh -s              supervise: restart it if it dies unexpectedly
#   ./start-gui.sh --no-observe    leave the vm-service (Observatory) off
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
LAST_GOOD="$HOME/.macdart/workspace.last-good.dart"

background=0 rebuild=0 fresh=0 restore=0 supervise=0
observe=1 obsport=8181
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--background) background=1 ;;
    -r|--rebuild)    rebuild=1 ;;
    -f|--fresh)      fresh=1 ;;
    --restore)       restore=1 ;;
    -s|--supervise)  supervise=1 ;;
    --no-observe)    observe=0 ;;
    --observe=*)     obsport="${1#--observe=}" ;;
    -h|--help)       sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "start-gui.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# The way back from a UI edit that will not even boot. The workspace keeps a copy
# of the source that last started it cleanly; this puts that copy back. The
# broken version is kept alongside, so nothing you wrote is thrown away.
if [ "$restore" = 1 ]; then
  if [ ! -f "$LAST_GOOD" ]; then
    echo "start-gui.sh: no recovery copy at $LAST_GOOD" >&2
    echo "  one is written a few seconds after each clean start" >&2
    exit 1
  fi
  broken="$UI_SCRIPT.broken.$(date +%Y%m%d-%H%M%S)"
  cp "$UI_SCRIPT" "$broken"
  cp "$LAST_GOOD" "$UI_SCRIPT"
  echo "restored $LAST_GOOD -> $UI_SCRIPT"
  echo "kept the version that was there as $broken"
fi

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

ARGS=()
if [ "$observe" = 1 ]; then
  # --enable-vm-service, NOT --observe: --observe also sets
  # --pause-isolates-on-exit and --pause-isolates-on-unhandled-exceptions, and
  # both are wrong here. The watchdog respawns the language isolate as normal
  # operation, and pause-on-exit left the dead ones parked and still listed by
  # getVM (a client resolving "the language isolate" could pick a corpse); an
  # unhandled exception in a do-it is how errors are REPORTED here, not a reason
  # to freeze the isolate with no debugger attached.
  ARGS+=("--enable-vm-service=$obsport")
  echo "observatory / control plane: ws://127.0.0.1:$obsport/ws"
  echo '  (macdart/tcl/dartui.tcl - obs for VM introspection, ui for the GUI)' 
fi

echo "image:   $IMAGE"
echo "control: 127.0.0.1:$PORT   (e.g. printf 'snap /tmp/x.png\\n' | nc -w1 127.0.0.1 $PORT)"

# Keep it running across an unexpected death, but never in a tight loop: a fault
# that reproduces the moment the UI is back would just spin, hiding itself.
# Three failures inside a minute is that, and exit 70 (the host's "the UI never
# started") is not worth retrying at all — the source on disk is broken.
if [ "$supervise" = 1 ]; then
  fails=0
  window=$(date +%s)
  while true; do
    "$DARTUI" "${ARGS[@]}" "$UI_SCRIPT" || rc=$?
    rc=${rc:-0}
    [ "$rc" = 0 ] && { echo "workspace exited cleanly"; exit 0; }
    if [ "$rc" = 70 ]; then
      echo "start-gui.sh: the UI source does not load — not retrying." >&2
      echo "  recover it with: ./start-gui.sh --restore" >&2
      exit 1
    fi
    now=$(date +%s)
    [ $((now - window)) -gt 60 ] && { fails=0; window=$now; }
    fails=$((fails + 1))
    if [ "$fails" -ge 3 ]; then
      echo "start-gui.sh: died $fails times in under a minute (last exit $rc)." >&2
      echo "  not restarting again. Try: ./start-gui.sh --restore" >&2
      exit 1
    fi
    echo "workspace died (exit $rc) — restarting [$fails/3]…" >&2
    rc=0
    sleep 1
  done
fi

if [ "$background" = 1 ]; then
  nohup "$DARTUI" "${ARGS[@]}" "$UI_SCRIPT" >"$LOG" 2>&1 </dev/null &
  echo "started in the background (pid $!), logging to $LOG"
else
  exec "$DARTUI" "${ARGS[@]}" "$UI_SCRIPT"
fi
