# MACDART workspace regression suite — real Tcl, one control plane.
#
#   ./start-gui.sh -b
#   TCLLIBPATH=~/claudeprojects/tcl/tcllib-1.21/modules \
#   ~/claudeprojects/tcl/local/bin/tclsh8.6 macdart/tcl/regress.tcl
#
# Introspection and GUI control come over the SAME vm-service socket: `obs` is a
# built-in RPC, `ui` is the ext.dartui.send service extension.

source [file join [file dirname [info script]] dartui.tcl]

set passed 0
set failed 0

proc check {label got want} {
    global passed failed
    if {$got eq $want} {
        incr passed
        puts "  ok    $label"
    } else {
        incr failed
        puts "  FAIL  $label"
        puts "          got:  $got"
        puts "          want: $want"
    }
}

proc section {name} { puts "\n$name" }

connect
::dartui::resolveUi

section "vm introspection"
set vm [obs getVM]
# At least the UI and language isolates. Not an exact count: this suite
# restarts the language isolate, and a replaced one can still be listed.
check "isolates present"  [expr {[llength [dict get $vm isolates]] >= 2}] 1
set ver [obs getVersion]
check "service protocol"  [dict get $ver major] 3
set fl [obs getFlagList]
check "flags available"   [expr {[llength [dict get $fl flags]] > 100}] 1
set ap [obs _getAllocationProfile isolateId $::dartui::uiIsolate]
check "allocation profile" [expr {[llength [dict get $ap members]] > 0}] 1

section "language isolate"
check "arithmetic"        [ui doit 6*7] 42
check "class from image"  [ui doit {new Blorp().triple()}] 3

section "gui control (same socket)"
check "switch tab"        [ui tab 1] ok
after 300
check "toolbar button"    [ui click Browser] "clicked Browser"
check "menu bar shape"    [ui menus] "9: NSMenuItem | File | Edit | Code | Demos | Apps | View | Source | Debug"

section "accept is compile-checked"
# The image OUTLIVES the suite, so a class that leaked in once would make these
# checks fail for ever after — which is exactly what happened when the compile
# gate silently disabled itself. Start from a known-absent state instead of
# assuming one, and clean up at the end.
foreach junk {TclBad ScriptBad Nope} { catch {ui remove $junk} }
ui settle
ui tab 0
ui settext {class TclOk {\n  int n = 2;\n  int twice() => n * 2;\n}}
ui click ws:Accept
ui settle
check "valid accepted"    [ui doit {new TclOk().twice()}] 4
ui settext {class TclBad {\n  int f() { var x = ; }\n}}
ui click ws:Accept
ui settle
check "broken refused"    [ui doit {(){ try { new TclBad(); return "leaked"; } catch (e) { return "refused"; } }()}] refused

section "scripted accept is gated like the buttons"
# The accept verb was once the unguarded door into the image.
check "script broken refused" \
    [expr {[string match ERR:* [ui accept {class ScriptBad { int f() { var x = ; } }}]]}] 1
check "and never reached it"  \
    [expr {[string match ERR:* [ui doit {new ScriptBad()}]]}] 1
check "script valid accepted" \
    [expr {[string match accepted* [ui accept {class ScriptOk { int n = 3; int t() => n * 2; }}]]}] 1
check "and it runs"           [ui doit {new ScriptOk().t()}] 6
# accepted as a one-liner, stored multi-line so a breakpoint can resolve in it
check "stored multi-line"     [expr {[llength [split [ui classsrc ScriptOk] \n]] > 1}] 1
ui remove ScriptOk
after 1500

section "the ui rebuilds itself"
check "rebuild layout"    [ui uirebuild] ok
after 800
check "alive after"       [ui ping] pong
check "controls rewired"  [ui click Browser] "clicked Browser"

section "a failing action must not kill the app"
ui menuclick Debug/Raise a Test Error
after 500
check "survived"          [ui ping] pong

section "events arrive on the same wire"
on Extension
ui menuclick Debug/Restart Language Isolate
after 4000
ui ping
check "gui event pushed"  [expr {[llength [events]] > 0}] 1
check "image reloaded"    [ui doit {new Blorp().triple()}] 3

section "debugger (language isolate, from the UI isolate)"
ui settext {class DbgT {\n  int n = 0;\n  int step() {\n    n = n + 1;\n    return n;\n  }\n}}
ui click ws:Accept
ui settle
check "debug class live"  [ui doit {new DbgT().step()}] 1
set iso [ui dbgattach]
check "attached"          [expr {[string match isolates/* $iso]}] 1
# the VM's own line numbering, read back from the source pane the debugger shows
# Scope the search to DbgT: `n = n + 1;` also appears in Counter, which is
# stored as a one-liner and has no body line to break on.
set line 0
set n 0
set inClass 0
foreach l [split [ui dbgsource] \n] {
    incr n
    if {[string match {*class DbgT*} $l]} { set inClass 1 }
    if {$inClass && [string match {*n = n + 1;*} $l] && $line == 0} { set line $n }
}
check "found body line"   [expr {$line > 0}] 1
check "breakpoint resolved" [expr {[string match *resolved=true* [ui dbgbreak $line]]}] 1
check "not paused yet"    [ui dbgstate] running

# stop on the breakpoint and inspect the frame
check "bg trigger" [uibg doit new DbgT().step()] started
after 3000
check "paused"            [expr {[string match paused* [ui dbgstate]]}] 1
check "gui alive stopped" [ui ping] pong
check "locals bound"      [expr {[string match *this=* [ui dbgvars]]}] 1
check "eval in frame"     [expr {[string match *=>*2* [ui dbgeval {n + 2}]]}] 1
# A breakpoint must survive an edit: accepting anything rewrites the scratch
# file the VM breaks in, and its line numbers move.
# committing code into a STOPPED isolate must be refused, not queued — the
# queued form fired invisibly on Continue and once deadlocked this very suite
check "accept refused while paused" \
    [expr {[string match ERR:* [ui accept {class Nope { int q = 1; }}]]}] 1
ui dbgstep
after 800
check "resumed"           [ui dbgstate] running
# an edit AFTER resume rewrites the scratch; the anchored breakpoint must survive
ui accept {class Pad { int p1() => 1; int p2() => 2; int p3() => 3; }}
after 3000
uibg doit new DbgT().step()
after 3000
check "breakpoint survived an edit" [expr {[string match paused* [ui dbgstate]]}] 1
ui dbgstep
after 800
# A SYNCHRONOUS doit that stops at the breakpoint must be answered at once —
# its real reply cannot exist until Continue, and holding the RPC open for that
# parks the client against its read deadline on the one connection (the
# original hang, third edition). The result goes to the transcript instead.
set t0 [clock milliseconds]
set r [ui doit new DbgT().step()]
set waited [expr {[clock milliseconds] - $t0}]
check "sync doit answers while stopping" \
    [expr {[string match "stopped in the debugger*" $r] && $waited < 5000}] 1
after 500
check "and it is paused"  [expr {[string match paused* [ui dbgstate]]}] 1
# Restarting the language isolate while it sits at a breakpoint must not leave
# a ghost pause behind: the pause died with its isolate. This once wedged the
# workspace — everything refused with "press Continue first" over a corpse.
ui menuclick {Debug/Restart Language Isolate}
after 4000
check "restart clears the pause" [ui dbgstate] running
check "and doits work at once"   [ui doit 2+2] 4
ui dbgclear
ui remove Pad
after 1500

section "demos (isolates drawing through the ui isolate)"
check "demos listed"      [expr {[llength [split [ui demos] \n]] >= 4}] 1
# pixmap.dart has no "// Demo:" header: a library demos import, not a program
check "libraries not listed" [expr {![string match -nocase *pixmap* [ui demos]]}] 1
check "demo starts"       [expr {[string match started* [ui demorun bounce]]}] 1
after 1500
set ds [ui demostatus]
set n 0
regexp {(\d+) frames} $ds -> n
check "frames flowing"    [expr {[string match running* $ds] && $n > 0}] 1
check "gui alive under a demo" [ui ping] pong
ui snap /tmp/dartui_demo.png
check "demo stops"        [ui demostop] ok
check "idle after stop"   [ui demostatus] idle
# the parallel one: four workers zoom ~4s (paced for the screen), then a clean
# finish lets its isolate exit — poll rather than guess the duration
ui demorun mandelbrot
set zoomDone 0
for {set i 0} {$i < 30} {incr i} {
    after 500
    if {[string match finished* [ui demostatus]]} { set zoomDone 1; break }
}
check "mandelbrot finished" \
    [expr {$zoomDone && [string match {*pixmaps from 4 worker isolates*} [ui log]]}] 1
check "its isolate exited"  [expr {[string match finished* [ui demostatus]]}] 1
ui demostop

section "user apps (image classes driving real controls)"
# An app is an ordinary image class with a build(ui) method. It runs in the
# LANGUAGE isolate and never touches AppKit; the UI isolate materialises its
# widgets and sends events back.
ui accept {class Ticker { var n = 0; build(ui) { ui.title('Ticker'); ui.label('v', text: n.toString(), frame: [8.0, 8.0, 140.0, 20.0]); ui.button('inc', title: 'Add 1', frame: [8.0, 34.0, 90.0, 28.0], onClick: (_) { n = n + 1; ui.set('v', text: n.toString()); }); } }}
ui settle
check "listed as an app"   [expr {[string match *Ticker* [ui apps]]}] 1
check "runs"               [ui apprun Ticker] "running Ticker"
check "widgets materialised" [llength [split [ui apptree] \n]] 2
ui appclick inc
ui appclick inc
ui appclick inc
check "clicks reach the app" [ui appget v] 3
check "gui alive under an app" [ui ping] pong

# The payoff: edit the layout of a RUNNING app. Hot reload morphs the live
# instance, so the new build() draws over preserved state.
ui accept {class Ticker { var n = 0; build(ui) { ui.title('Ticker'); ui.label('v', text: n.toString(), frame: [8.0, 8.0, 140.0, 20.0]); ui.label('note', text: 'edited live', frame: [8.0, 70.0, 200.0, 20.0]); ui.button('inc', title: 'Bump', frame: [8.0, 34.0, 90.0, 28.0], onClick: (_) { n = n + 1; ui.set('v', text: n.toString()); }); } }}
ui settle
check "layout changed live"  [expr {[string match *edited* [ui apptree]]}] 1
check "button relabelled"    [ui appget inc] Bump
check "state survived the edit" [ui appget v] 3
ui appclick inc
check "and it keeps counting" [ui appget v] 4

# Teardown 1: a UI layout rebuild tears the view tree down under the app. The
# widgets must come back AND still fire — disposeCallbacks() invalidates every
# callback ticket, so replaying the spec has to rewire them, not just redraw.
ui uirebuild
after 1200
check "widgets replayed"     [llength [split [ui apptree] \n]] 3
ui appclick inc
check "and still wired up"   [ui appget v] 5

# Teardown 2: the app instance dies with its isolate. No ghost pane.
ui menuclick {Debug/Restart Language Isolate}
after 4000
check "cleared on respawn"   [ui appstatus] idle
check "pane emptied"         [ui apptree] "(no app running)"
check "runs again"           [ui apprun Ticker] "running Ticker"
check "with a fresh instance" [ui appget v] 0
ui appstop
check "stopped"              [ui appstatus] idle
ui remove Ticker
ui settle

# The shipped examples must actually install and work — a broken one in apps/
# should fail here, not in front of someone trying it.
ui menuclick {Apps/Install Calculator}
ui settle
check "example installed and running" [ui appstatus] "running Calculator"
foreach k {k7 k+ k8 k=} { ui appclick $k }
check "calculator adds up"   [ui appget d] 15
ui appclick k*
ui appclick k3
ui appclick k=
check "and multiplies"       [ui appget d] 45
# The pane is a surface, not a fixed canvas. An app lays out in top-left
# coordinates, so growing the window has to RE-RUN build(): autoresizing masks
# cannot know what a layout means, and without this the widgets kept their
# AppKit frames and slid away from the top edge.
ui resize 900 640
after 1200
set appSmall [lindex [split [ui apptree] \n] 0]
ui resize 1300 860
after 1800
check "app re-lays out when the pane grows" \
    [expr {$appSmall ne [lindex [split [ui apptree] \n] 0]}] 1
ui resize 900 640
after 1800
check "and comes back when it shrinks" [lindex [split [ui apptree] \n] 0] $appSmall

# Edit opens the RUNNING app's own source in the Editor, and committing it there
# goes through the same gate as everything else — so the round trip a user
# actually does (edit the layout, save, watch it change) is covered end to end.
check "edit opens the app"   [ui appedit] "editing Calculator"
check "editor holds its source" \
    [expr {[string match {*class Calculator*} [ui edtext]]}] 1
# A class whose source opens with a doc comment is still a class. It used to be
# classified as a 'variable', which removed every documented class — including
# all the apps/ examples — from the class list without saying so.
ui settle
check "a documented class is listed" \
    [expr {[string match {*Calculator*} [ui edclasses]]}] 1
set edited [string map {"'C'" "'AC'"} [ui edtext]]
ui edsettext [string map [list "\n" "\\n"] $edited]
ui click "Save to Image"
ui settle
after 800
check "committed from the editor" [expr {[string match {*AC*} [ui apptree]]}] 1
check "and the total survived"    [ui appget d] 45
ui appstop

section "searchable Dart V1 help"
# The index is parsed from the SDK this VM was built from, the language spec and
# dart:cocoa — so these checks also assert the sources are still where we think.
check "index built"        [expr {[ui helpcount] > 1500}] 1
check "finds a class"      [expr {[string match {*dart:async*Future*} [ui helpsearch Future]]}] 1
check "finds a member"     [expr {[string match {*String.substring*} [ui helpsearch substring]]}] 1
check "finds the spec"     [expr {[string match {*spec*Await Expressions*} [ui helpsearch await]]}] 1
check "finds dart:cocoa"   [expr {[string match {*dart:cocoa*wsEval*} [ui helpsearch wsEval]]}] 1
# a keyword the libraries can never explain — only the spec can
check "finds a keyword"    [expr {[string match {*spec*Yield*} [ui helpsearch {async*}]]}] 1
check "hides private impl" [expr {![string match {*_Future*} [ui helpsearch Future]]}] 1
ui helpsearch {String.substring}
ui helpsel 0
check "detail has the signature" \
    [expr {[string match {*String substring(int startIndex*} [ui helptext]]}] 1
check "detail cites its source" \
    [expr {[string match {*sdk/lib/core/string.dart:*} [ui helptext]]}] 1
check "gui alive after search" [ui ping] pong

# TYPING must search, not just the verbs. An NSTextField sends
# controlTextDidChange: to its delegate and never textDidChange: — wiring only
# the latter left every keystroke unheard while the socket verbs worked fine,
# which is this project's classic socket-works/mouse-fails signature. Driven
# through the field editor, the object AppKit routes real keystrokes through.
proc helpType {text} {
    set iso $::dartui::uiIsolate
    set info [obs getIsolate isolateId $iso]
    set lib [dict get [dict get $info rootLib] id]
    obs evaluate targetId $lib isolateId $iso expression \
        "(){ gWindow.makeFirstResponder(gHelpField);\
             var fe = gWindow.fieldEditor(true, forObject: gHelpField);\
             fe.setString(''); fe.insertText('$text'); return 'ok'; }()"
}
ui tab 2
helpType substring
after 1200
check "typing in the box searches" \
    [expr {[string match {*String.substring*} [ui helptext]]}] 1
check "alive after typing"     [ui ping] pong

section "cleanup"
ui remove TclOk
ui remove DbgT
# Defensive: if the gate ever lets one of these through, the next run starts
# clean rather than inheriting a permanently failing check.
foreach junk {TclBad ScriptBad Nope GateProbe} { catch {ui remove $junk} }
after 1500

puts "\npassed $passed, failed $failed"
if {$failed > 0} { exit 1 }
