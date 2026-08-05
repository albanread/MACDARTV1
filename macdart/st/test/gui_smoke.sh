#!/usr/bin/env bash
# gui_smoke.sh — the scripted GUI pass that headless tiers cannot reach
# (ST_PORTING_PLAN.md §2 D6). This is the check that would have caught the
# `classNamed: #Symbol` browser regression automatically: it BUILDS the ST
# browser over the control plane and fails if that returns an error.
#
#   ./gui_smoke.sh            drive the already-running workspace (port 8181)
#   ./gui_smoke.sh --launch   start one via start-st-gui.sh first (needs a display)
#
# Exits nonzero on any failed check. Talks to the live UI over ext.dartui.send.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CTL="$ROOT/macdart/tcl/stgui_ctl.py"
PORT=8181
LOG=/tmp/macdart-gui.log
launched=0

ctl() { python3 "$CTL" --port "$PORT" --timeout 20 "$@" 2>&1; }
fails=0
ok()   { printf "  \033[32mok\033[0m    %-22s %s\n" "$1" "$2"; }
bad()  { printf "  \033[31mFAIL\033[0m  %-22s %s\n" "$1" "$2"; fails=$((fails+1)); }
skip() { printf "  \033[33mskip\033[0m  %-22s %s\n" "$1" "$2"; }
# check NAME  EXPECT-substring  ACTUAL
chk()  { case "$3" in *"$2"*) ok "$1" "$3";; *) bad "$1" "got: $3";; esac; }

if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  if [ "${1:-}" = "--launch" ]; then
    echo "gui_smoke: launching workspace…"
    ( cd "$ROOT" && ./start-st-gui.sh ) >/dev/null 2>&1 || { echo "launch failed — see $LOG" >&2; exit 1; }
    launched=1
  else
    echo "gui_smoke: nothing on :$PORT — start the workspace or pass --launch" >&2
    exit 2
  fi
fi

echo "== GUI smoke =="
chk ping                pong        "$(ctl ping)"

# Is the world actually in this image? A no-world instance can't exercise the
# browser/Fraction — that's a SETUP gap (run with --launch), not a regression,
# so gate those checks instead of failing them.
world=0
[ -n "$(ctl lang classsrc String | grep -vE '^$' | head -1)" ] && world=1
if [ "$world" = 1 ]; then
  # THE regression catcher: building the ST browser must answer a handle. The
  # classNamed:#Symbol break returned "on_(StSymbol)" here; distinguish that
  # real failure from a missing-world setup skip.
  brz="$(ctl lang stbrowser "868 420")"
  case "$brz" in
    *"world is not in this image"*) skip "browser build" "no world (setup)" ;;
    ERR*|*NoSuchMethod*|*StSymbol*|*"released or nil"*) bad "browser build" "$brz" ;;
    *) ok "browser build" "handle/ok" ;;
  esac
  chk "browser classSource" "String"  "$(ctl lang classsrc String | head -1)"
  chk "doit fraction"       "1/2"      "$(ctl doit 'st> (1/3) + (1/6)')"

  # The browser slices source into methods with its own scanner (language.dart,
  # _stMemberIndex) — a SECOND reader of the grammar st_parser.cc owns. When the
  # two drift the pane quietly shows half a method, or none. These three are the
  # shapes that broke; browser_index.py is the exhaustive form of this check
  # (whole world vs st_dump, 2453 methods).
  chk "method body, annotated" "a <= b" \
      "$(ctl lang methodsrc 'Magnitude class defaultSort' | tr '\n' ' ')"
  chk "one-liner methods listed" "classSourceFor:" \
      "$(ctl lang selectors STHostService | tr '\n' ' ')"
  chk "binary selectors listed" "i <=" \
      "$(ctl lang selectors Magnitude | tr '\n' ' ')"
else
  skip "world in image" "absent — run with --launch; browser/Fraction checks skipped"
fi

# engine-level (world-independent) — these must hold on any instance
chk "doit writestream"   "hi there"  "$(ctl doit "st> ((WriteStream on: String new) nextPutAll: 'hi there'; contents)")"
chk "doit equality"      "true false false true" \
     "$(ctl doit 'st> (Array with: ($a == $a) with: ($a = '"'"'a'"'"') with: (#foo = '"'"'foo'"'"') with: ((1/2) = (1/2)))')"

# ST games on the Metal pane (GAMEPANE_PLAN.md §8): launch, let a few frames
# tick, snapshot the pane's honest texture, stop. Needs the world in the image.
if [ "$world" = 1 ]; then
  # Galaxigans is a FILED-IN game: `demorun` is the path a player takes from the
  # Games menu — read demos/galaxigans.mst, install its five classes into the
  # running image, launch the one with a class-side launch. It is also the only
  # game that opens a non-default pane (640x360, which it declares itself) and
  # the only user of the ST text overlay.
  chk "filed-in galaxigans" "started"  "$(ctl demorun galaxigans)"
  sleep 2
  case "$(ctl gpstat)" in
    *640*360*) ok "galaxigans pane" "640x360" ;;
    *) bad "galaxigans pane" "$(ctl gpstat)" ;;
  esac
  ctl demostop >/dev/null 2>&1
  chk "stgame breakout"   "ok"        "$(ctl stgame Breakout)"
  sleep 2
  st1="$(ctl gpstat)"; sleep 1; st2="$(ctl gpstat)"
  if [ -n "$st1" ] && [ -n "$st2" ] && [ "$st1" != "$st2" ]; then
    ok "stgame frames tick" "$st2"
  else
    bad "stgame frames tick" "gpstat frozen: $st1 / $st2"
  fi
  rm -f /tmp/stgame.png
  chk "stgame gpsnap"     "ok"        "$(ctl gpsnap /tmp/stgame.png)"
  if [ -s /tmp/stgame.png ]; then ok "stgame snapshot" "$(wc -c </tmp/stgame.png | tr -d ' ') bytes"
  else bad "stgame snapshot" "missing/empty /tmp/stgame.png"; fi
  # The frame stepper: park the loop, take frames by hand, resume. The two
  # things that can silently break it are (a) a step that does not actually
  # advance a frame, and (b) a park that stops answering the UI's invitation —
  # the next tick is scheduled from inside the paint, so an unanswered one ends
  # the pull loop and `gprun` would resume a game nobody is inviting. Both are
  # checked: frozen while parked, and moving again after gprun.
  p1="$(ctl gppause)"; s1="$(ctl gpstep)"; s2="$(ctl gpstep)"
  f1="$(echo "$p1" | sed -n 's/.*frame \([0-9]*\).*/\1/p')"
  f3="$(echo "$s2" | sed -n 's/.*frame \([0-9]*\).*/\1/p')"
  if [ -n "$f1" ] && [ -n "$f3" ] && [ "$f3" = "$((f1 + 2))" ]; then
    ok "gpstep one frame each" "$s1 -> $s2"
  else bad "gpstep one frame each" "$p1 / $s1 / $s2"; fi
  w1="$(ctl gpwhere)"; sleep 1; w2="$(ctl gpwhere)"
  if [ "$w1" = "$w2" ]; then ok "parked stays parked" "$w2"
  else bad "parked stays parked" "drifted: $w1 -> $w2"; fi
  chk "gpkeys inject"     "keys: 16"  "$(ctl gpkeys 16)"
  ctl gpkeys - >/dev/null
  # Editing ANY class while a game plays used to end it: an accept reloads the
  # whole world, and the frame loop's step block used to live in GamePane's
  # class variables, which come back nil. The block is Dart-side now
  # (world/80_gamepane_wiring.mst), so the game must play straight through one.
  # The probe's own answer proves the accept really reloaded, so a silently
  # failed accept cannot pass this by leaving the game undisturbed.
  ctl gprun >/dev/null
  ctl doit "st> STHostService new acceptEditorClass: 'Object subclass: GxReloadProbe [ GxReloadProbe class >> ping [ ^42 ] ]'" >/dev/null 2>&1
  chk "accept landed (world reloaded)" "42" "$(ctl doit 'st> GxReloadProbe ping')"
  e1="$(ctl gpwhere)"; sleep 1; e2="$(ctl gpwhere)"
  if [ "$e1" != "$e2" ] && [ "${e2#running}" != "$e2" ]; then
    ok "game survives a Browser accept" "$e2"
  else bad "game survives a Browser accept" "froze at $e2"; fi
  ctl gprun >/dev/null; r1="$(ctl gpwhere)"; sleep 1; r2="$(ctl gpwhere)"
  if [ "$r1" != "$r2" ]; then ok "gprun resumes the pull loop" "$r2"
  else bad "gprun resumes the pull loop" "still frozen at $r2"; fi
  chk "stgame stop"       "ok"        "$(ctl demostop)"
else
  skip "stgame breakout" "no world in this image"
fi

# ST apps in the Apps player: install the .mst from apps/, run it, read the
# widget tree back (the exact-fraction result proves build: ran end to end).
if [ "$world" = 1 ]; then
  chk "appinstall fractions" "running FractionsApp" "$(ctl appinstall Fractions)"
  chk "apps lists it"        "FractionsApp"         "$(ctl apps)"
  at="$(ctl apptree)"
  case "$at" in
    *"1/3 + 1/6  =  1/2"*) ok "st app computes" "exact 1/2 shown" ;;
    *) bad "st app computes" "$at" ;;
  esac
  chk "appstop"              "ok"                   "$(ctl appstop)"
else
  skip "st app" "no world in this image"
fi

# scan the live log for anything that smells like a broken pane
if [ -f "$LOG" ] && grep -qiE "NoSuchMethod|StSymbol|Cocoa: send to a released|Smalltalk browser: ERR|Unhandled exception" "$LOG"; then
  bad "log clean" "$(grep -iE 'NoSuchMethod|StSymbol|browser: ERR' "$LOG" | tail -1)"
else
  ok "log clean" "no pane errors"
fi

[ "$launched" = 1 ] && echo "gui_smoke: workspace left running (started by --launch)"
echo "== $([ $fails = 0 ] && echo 'GUI GREEN' || echo "$fails GUI CHECK(S) RED") =="
exit $([ $fails = 0 ] && echo 0 || echo 1)
