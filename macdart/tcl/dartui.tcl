# MACDART control plane in Tcl — VM introspection AND GUI control, one socket.
#
#   TCLLIBPATH=~/claudeprojects/tcl/tcllib-1.21/modules \
#   ~/claudeprojects/tcl/local/bin/tclsh8.6 <script that sources this>
#
# The Observatory is not a library to link against: it is the VM's own
# vm-service, a JSON-RPC 2.0 server hosted over WebSocket when the VM is
# launched with --observe. This is a client for the server already running.
#
#   obs <method> ?k v …?   built-in RPC    getVM, getStack, _getCpuProfile, …
#   ui  <control line>     GUI control     via the ext.dartui.send extension
#   on  <stream>           subscribe       Debug, GC, Extension, …
#   events                 drain pushed events
#
# Two things this build forces, both found by testing rather than assumed:
#
#  1. WebSocket is the ONLY transport. The vm-service does have an HTTP RPC
#     path, but runtime/bin/vmservice/server.dart answers every non-/ws URL with
#     "This VM was built without the Observatory UI." and closes BEFORE reaching
#     it, because we link observatory_assets_empty.cc. So that branch is dead
#     here and a GET-based client cannot work.
#  2. The framing is implemented below rather than with tcllib's `websocket`.
#     That package drives the handshake through ::http::geturl, whose -command
#     never fires on a 101 upgrade with the http 2.9.8 shipped in this Tcl, so
#     the connection opens and then silently never completes. RFC 6455 for our
#     purposes is a handshake plus masked text frames — small enough to own,
#     and it removes a dependency that was already fighting us.

package require json

namespace eval dartui {
    variable sock ""
    variable seq 0
    variable uiIsolate ""
    variable events {}

    # -- RFC 6455, the part we need ------------------------------------------
    proc wsOpen {host port path} {
        set s [socket $host $port]
        fconfigure $s -translation binary -blocking 1
        set nonce ""
        for {set i 0} {$i < 16} {incr i} {
            append nonce [binary format c [expr {int(rand() * 256)}]]
        }
        set key [binary encode base64 $nonce]
        puts -nonewline $s "GET $path HTTP/1.1\r\nHost: $host:$port\r\n"
        puts -nonewline $s "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        puts -nonewline $s "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n"
        flush $s
        set status [gets $s]
        if {![string match "HTTP/1.1 101*" [string trim $status]]} {
            close $s
            error "dartui: no WebSocket upgrade (server said: [string trim $status])"
        }
        while {[gets $s line] >= 0} { if {[string trim $line] eq ""} break }
        return $s
    }

    # A client frame MUST be masked (RFC 6455 §5.3); servers never mask.
    proc wsSend {s text} {
        set payload [encoding convertto utf-8 $text]
        set n [string length $payload]
        set hdr [binary format c 0x81]
        if {$n < 126} {
            append hdr [binary format c [expr {0x80 | $n}]]
        } elseif {$n < 65536} {
            append hdr [binary format cS [expr {0x80 | 126}] $n]
        } else {
            append hdr [binary format cW [expr {0x80 | 127}] $n]
        }
        set mask ""
        for {set i 0} {$i < 4} {incr i} {
            append mask [binary format c [expr {int(rand() * 256)}]]
        }
        binary scan $mask cu4 mb
        binary scan $payload cu* pb
        set out {}
        set i 0
        foreach b $pb {
            lappend out [expr {$b ^ [lindex $mb [expr {$i % 4}]]}]
            incr i
        }
        puts -nonewline $s $hdr
        puts -nonewline $s $mask
        puts -nonewline $s [binary format cu* $out]
        flush $s
    }

    proc wsRecv {s} {
        set h [read $s 2]
        if {[string length $h] < 2} { error "dartui: connection closed" }
        binary scan $h cucu b0 b1
        set opcode [expr {$b0 & 0x0f}]
        set len [expr {$b1 & 0x7f}]
        if {$len == 126} {
            binary scan [read $s 2] Su len
        } elseif {$len == 127} {
            binary scan [read $s 8] Wu len
        }
        set payload ""
        while {[string length $payload] < $len} {
            append payload [read $s [expr {$len - [string length $payload]}]]
        }
        if {$opcode == 8} { error "dartui: server closed the connection" }
        return [encoding convertfrom utf-8 $payload]
    }

    # -- JSON-RPC -------------------------------------------------------------
    proc jsonStr {s} {
        set out ""
        foreach ch [split $s ""] {
            switch -- $ch {
                "\"" { append out {\"} }
                "\\" { append out {\\} }
                "\n" { append out {\n} }
                "\r" { append out {\r} }
                "\t" { append out {\t} }
                default { append out $ch }
            }
        }
        return "\"$out\""
    }

    proc connect {{url "ws://127.0.0.1:8181/ws"}} {
        variable sock
        if {![regexp {^ws://([^:/]+):([0-9]+)(/.*)$} $url -> host port path]} {
            error "dartui: cannot parse $url"
        }
        set sock [wsOpen $host $port $path]
        return $url
    }

    # The banner is the source of truth: a build with auth codes prints
    # http://127.0.0.1:8181/<TOKEN>/ and the socket becomes …/<TOKEN>/ws.
    # This build prints no token, but deriving it costs one regex.
    proc urlFromBanner {line} {
        if {[regexp {https?://[^\s]+} $line url]} {
            regsub {^http} $url "ws" url
            if {![string match */ $url]} { append url / }
            return ${url}ws
        }
        return ""
    }

    proc rpc {method {params {}}} {
        variable sock
        variable seq
        variable events
        set id [incr seq]
        set p {}
        # Numbers must go over as JSON numbers: evaluateInFrame rejects a
        # frameIndex sent as "0" with Invalid params.
        foreach {k v} $params {
            if {[string is integer -strict $v]} {
                lappend p "[jsonStr $k]:$v"
            } else {
                lappend p "[jsonStr $k]:[jsonStr $v]"
            }
        }
        set req "\{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":[jsonStr $method],\"params\":\{[join $p ,]\}\}"
        wsSend $sock $req
        # Replies and pushed events share the socket; keep anything that is not
        # our answer so `events` can hand it back.
        while {1} {
            set d [::json::json2dict [wsRecv $sock]]
            if {[dict exists $d id] && [dict get $d id] == $id} {
                if {[dict exists $d error]} {
                    error "dartui: $method: [dict get [dict get $d error] message]"
                }
                return [dict get $d result]
            }
            lappend events $d
        }
    }

    # Service extensions are registered PER ISOLATE, so an extension call must
    # name the isolate that registered it. Re-resolve after a respawn.
    proc resolveUi {} {
        variable uiIsolate
        set vm [rpc getVM]
        foreach iso [dict get $vm isolates] {
            set id [dict get $iso id]
            if {[catch {rpc getIsolate [list isolateId $id]} info]} { continue }
            if {![dict exists $info extensionRPCs]} { continue }
            foreach e [dict get $info extensionRPCs] {
                if {$e eq "ext.dartui.send"} {
                    set uiIsolate $id
                    return $id
                }
            }
        }
        error "dartui: no isolate registered ext.dartui.send — is this dartui, with --observe?"
    }
}

proc connect {{url "ws://127.0.0.1:8181/ws"}} { return [::dartui::connect $url] }
proc obs {method args} { return [::dartui::rpc $method $args] }

proc ui {args} {
    if {$::dartui::uiIsolate eq ""} { ::dartui::resolveUi }
    set r [::dartui::rpc ext.dartui.send \
               [list isolateId $::dartui::uiIsolate line [join $args " "]]]
    return [dict get $r reply]
}

proc on {stream} { ::dartui::rpc streamListen [list streamId $stream] ; return $stream }

proc events {} {
    set e $::dartui::events
    set ::dartui::events {}
    return $e
}
