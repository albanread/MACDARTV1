# MACDART workspace GUI regression suite.
#
#   ./start-gui.sh -b
#   (cd ../MACVM && ./target/release/macvm rusttcl --world world \
#        ../MACDART/macdart/test/gui.tcl)
#
# Driven by MACVM's rusttcl over the framed control channel (workspace.dart,
# startControlChannel) — the same protocol its own cocoa GUI speaks, so no
# second interpreter had to be written. `gui send <line>` passes any control
# verb straight through; `gui doit` runs Dart in the language isolate.
#
# Dialect note: this Tcl has set/if/while/foreach/proc/expr/list/llength and
# `==` compares strings, but there is no `string` command — keep assertions to
# equality.

gui connect 7645

set passed 0
set failed 0

proc check {label got want} {
    global passed failed
    if {$got == $want} {
        set passed [expr {$passed + 1}]
        puts "  ok    $label"
    } else {
        set failed [expr {$failed + 1}]
        puts "  FAIL  $label"
        puts "          got:  $got"
        puts "          want: $want"
    }
}

puts "language isolate"
check "arithmetic"        [gui doit {6*7}] 42
check "class from image"  [gui doit {new Blorp().triple()}] 3
check "live object state" [gui doit {(){ var w = new Widget(); w.bump(); return w.bump(); }()}] 7

puts "tabs and controls"
check "switch tab"     [gui send {tab 1}] ok
gui sleep 300
check "toolbar button" [gui send {click Browser}] "clicked Browser"
gui sleep 300
check "menu item"      [gui send {menuclick View/Workspace}] "clicked View/Workspace"
gui sleep 300
check "menu bar shape" [gui send menus] "7: NSMenuItem | File | Edit | Code | View | Source | Debug"

puts "accept is syntax-checked"
gui send {tab 0}
gui send {settext class TclGood {\n  int n = 2;\n  int twice() => n * 2;\n}}
gui send {click ws:Accept}
gui sleep 3000
check "valid accepted"  [gui doit {new TclGood().twice()}] 4
gui send {settext class TclBad {\n  int f() { var x = ; }\n}}
gui send {click ws:Accept}
gui sleep 3000
check "broken refused"  [gui doit {(){ try { return new TclBad().f(); } catch (e) { return "refused"; } }()}] refused

puts "the UI rebuilds itself"
check "rebuild layout"  [gui send uirebuild] ok
gui sleep 800
check "alive after"     [gui send ping] pong
check "controls rewired" [gui send {click Browser}] "clicked Browser"

puts "a failing action must not kill the app"
gui send {menuclick Debug/Raise a Test Error}
gui sleep 500
check "survived"        [gui send ping] pong

puts "cleanup"
gui send {remove TclGood}
gui sleep 1500

puts ""
puts "passed $passed, failed $failed"
