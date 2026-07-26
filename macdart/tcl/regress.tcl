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
check "menu bar shape"    [ui menus] "7: NSMenuItem | File | Edit | Code | View | Source | Debug"

section "accept is compile-checked"
ui tab 0
ui settext {class TclOk {\n  int n = 2;\n  int twice() => n * 2;\n}}
ui click ws:Accept
after 4000
check "valid accepted"    [ui doit {new TclOk().twice()}] 4
ui settext {class TclBad {\n  int f() { var x = ; }\n}}
ui click ws:Accept
after 4000
check "broken refused"    [ui doit {(){ try { new TclBad(); return "leaked"; } catch (e) { return "refused"; } }()}] refused

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

section "cleanup"
ui remove TclOk
after 1500

puts "\npassed $passed, failed $failed"
if {$failed > 0} { exit 1 }
