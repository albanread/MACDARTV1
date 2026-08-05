#!/usr/bin/env bash
#
# Launch the MACDART workspace as a SMALLTALK workspace: start the GUI, then
# make sure the ST world lives in its image — importing the vendored
# macdart/st/world on first run (86 classes become browsable, editable,
# persistent decls; see ST_PLAN.md Sprint 12). Subsequent runs find the world
# already in the image and skip straight to ready.
#
#   ./start-st-gui.sh              start (imports the world on first run)
#   ./start-st-gui.sh -r           rebuild dartui first
#   ./start-st-gui.sh -f           fresh image (world re-imports; old image kept)
#   ./start-st-gui.sh --world DIR  import from DIR instead of macdart/st/world
#   ./start-st-gui.sh --reimport   force a re-import even if the world is present
#
# Other options (-s, --observe=PORT, --app, --game, ...) pass through to
# start-gui.sh. The GUI is started DETACHED (the import needs this script to
# keep running); logs land in /tmp/macdart-gui.log as usual. --no-observe is
# refused: the vm-service IS the channel the import travels over.
#
# Talk to it afterwards:
#   python3 macdart/tcl/stgui_ctl.py doit "st> (1/3) + (1/6)"     -> 1/2
# or type  st> 3 + 4  straight into the workspace pane.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$ROOT/macdart/tcl/stgui_ctl.py"
WORLD="$ROOT/macdart/st/world"
PORT=8181
REIMPORT=0
PASS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --world)     WORLD="${2:?--world needs a directory}"; shift ;;
    --world=*)   WORLD="${1#--world=}" ;;
    --reimport)  REIMPORT=1 ;;
    --observe=*) PORT="${1#--observe=}"; PASS+=("$1") ;;
    --no-observe)
      echo "start-st-gui.sh: --no-observe is not possible here — the world" >&2
      echo "  import travels over the vm-service control plane" >&2
      exit 2 ;;
    -b|--background) ;;   # implied; the GUI always starts detached
    -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASS+=("$1") ;;
  esac
  shift
done

if [ ! -d "$WORLD" ] || [ ! -f "$WORLD/01_object.mst" ]; then
  echo "start-st-gui.sh: no Smalltalk world at $WORLD" >&2
  exit 1
fi

# start-gui.sh refuses a second instance itself; surface that check's result
# without burying it in our log redirection.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "start-st-gui.sh: something is already listening on 127.0.0.1:$PORT" >&2
  echo "  the workspace is probably already running (quit it, or just talk" >&2
  echo "  to it: python3 macdart/tcl/stgui_ctl.py ping)" >&2
  exit 1
fi

LOG=/tmp/macdart-gui.log
nohup "$ROOT/start-gui.sh" ${PASS[@]+"${PASS[@]}"} >"$LOG" 2>&1 </dev/null &
echo "workspace starting (logs: $LOG)…"

# Wait for the control plane — the language isolate boots the image first,
# which can take a moment when the world is already in it.
ready=0
for i in $(seq 1 60); do
  if [ "$(python3 "$CTL" --port "$PORT" --timeout 5 ping 2>/dev/null)" = "pong" ]; then
    ready=1; break
  fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "start-st-gui.sh: the workspace did not come up — see $LOG" >&2
  exit 1
fi

# The world is CURRENT when the image signature matches the vendored files
# (count-bytes). A bare presence check left images stale across updates.
WANT_SIG="$(ls "$WORLD"/*.mst 2>/dev/null | wc -l | tr -d ' ')-$(cat "$WORLD"/*.mst 2>/dev/null | wc -c | tr -d ' ')"
HAVE_SIG="$(sqlite3 "$HOME/.macdart/workspace.sqlite" "SELECT value FROM meta WHERE key='stworld_sig'" 2>/dev/null || true)"
if [ "$HAVE_SIG" = "$WANT_SIG" ] && [ "$REIMPORT" != 1 ]; then
  echo "st: world already in the image (current: $WANT_SIG)"
else
  if [ -n "$HAVE_SIG" ]; then echo "st: image world is stale ($HAVE_SIG -> $WANT_SIG) - re-importing"; fi
  echo "st: importing the world from ${WORLD} ..."
  result="$(python3 "$CTL" --port "$PORT" --timeout 300 stimport "$WORLD")"
  case "$result" in
    ERR*|"") echo "start-st-gui.sh: import failed: $result" >&2
             echo "  the GUI is still running — see $LOG" >&2
             exit 1 ;;
    *)       echo "st: $result" ;;
  esac
fi

echo "ready — try it:"
echo "  in the workspace pane:  st> (1/3) + (1/6)"
echo "  from a shell:           python3 macdart/tcl/stgui_ctl.py doit \"st> 3 + 4\""
