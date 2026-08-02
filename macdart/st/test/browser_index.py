#!/usr/bin/env python3
"""Does the Browser show every method, whole?

The class browser does not read the VM: it slices the SOURCE held in the image
into methods (language.dart, _stMemberIndex) and shows the slices. That slicer
is a hand-written scanner over text, and the authority on what a method actually
is lives elsewhere — st_parser.cc, the same reader the loader uses. Two readers
of one grammar drift, and when they drift the browser silently shows half a
method, or none.

So: parse the world corpus with the REAL parser (./st_dump), ask the running
workspace what its browser would show for the same classes, and compare.

  1. every method the parser finds must be listed by the browser
  2. the browser must list nothing the parser does not find
  3. every method's displayed source must PARSE BACK to exactly that method —
     which is what catches a slice truncated to its header line

Usage (the workspace must be running: ./start-gui.sh -b):

    python3 macdart/st/test/browser_index.py [--verbose]

Exit code is 1 when anything is wrong, 0 when clean. A full run is a few
minutes: 167 classes over the control plane, plus one st_dump per method.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ST = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(ST))
WORLD = os.path.join(ST, 'world')
ST_DUMP = os.path.join(ST, 'st_dump')
TCLSH = os.path.expanduser('~/claudeprojects/tcl/local/bin/tclsh8.6')
TCLLIB = os.path.expanduser('~/claudeprojects/tcl/tcllib-1.21/modules')
DARTUI_TCL = os.path.join(ROOT, 'macdart', 'tcl', 'dartui.tcl')

VERBOSE = '--verbose' in sys.argv


# --- the oracle: the real parser --------------------------------------------

def sexp(text):
    """S-expressions -> nested lists. st_dump's output, nothing more."""
    toks = re.findall(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+', text)
    stack, cur = [], []
    for t in toks:
        if t == '(':
            stack.append(cur)
            cur = []
        elif t == ')':
            done, cur = cur, stack.pop()
            cur.append(done)
        else:
            cur.append(t)
    return cur


def methods_of(node, out, cls=None):
    """Walk st_dump's AST, collecting (class, side, selector).

    Two shapes carry methods: `(classdef :name N … (method …))` for a class
    definition, and `(ext-method :class N [:class-side] (method …))` for the
    `Foo >> sel [ … ]` / `Foo class >> sel [ … ]` reopen forms the world uses
    to extend a class after the fact.
    """
    if not isinstance(node, list):
        return
    head = node[0] if node and isinstance(node[0], str) else None
    if head in ('classdef', 'ext-method', 'extend'):
        name = _tagged(node, ':name') or _tagged(node, ':class') or cls
        cls = name
    if head == 'method' and cls:
        sel = _sel_of(node)
        if sel:
            out.add((cls, 'c' if ':class-side' in node else 'i', sel))
        return
    for x in node:
        methods_of(x, out, cls)


def _sel_of(method_node):
    for i, x in enumerate(method_node):
        if x == ':selector' and i + 1 < len(method_node):
            return method_node[i + 1]
    return None


def _tagged(node, tag):
    for i, x in enumerate(node):
        if x == tag and i + 1 < len(node) and isinstance(node[i + 1], str) \
                and not node[i + 1].startswith(':'):
            return node[i + 1]
    return None


def parse_corpus():
    """{class: {(side, selector)}} from every world/*.mst the parser accepts."""
    by_class = {}
    files = sorted(f for f in os.listdir(WORLD) if f.endswith('.mst'))
    for f in files:
        path = os.path.join(WORLD, f)
        r = subprocess.run([ST_DUMP, path], capture_output=True, text=True,
                       errors='replace')
        if r.returncode != 0:
            print('  ! %s does not parse: %s' % (f, r.stderr.strip()[:120]))
            continue
        found = set()
        methods_of(sexp(r.stdout), found)
        for cls, side, sel in found:
            by_class.setdefault(cls, set()).add((side, sel))
    return by_class


# --- the subject: what the running browser would show ------------------------

def ui(script):
    """Run a Tcl script against the live workspace, return its stdout."""
    body = ('source %s\nconnect\n::dartui::resolveUi\n' % DARTUI_TCL) + script
    env = dict(os.environ, TCLLIBPATH=TCLLIB)
    r = subprocess.run([TCLSH, '-'], input=body, capture_output=True,
                       text=True, env=env, errors='replace')
    if r.returncode != 0:
        sys.exit('the workspace is not answering — start it with '
                 './start-gui.sh -b\n' + r.stderr.strip()[:400])
    return r.stdout


def image_members(classes):
    """{class: {(side, selector)}} exactly as the browser's selector pane lists.

    Through `selectors`, not `members`: the latter answers a Dart list whose
    toString cannot be read back once a selector is `,` — which is a real
    selector on Array, String and ByteArray.
    """
    script = []
    for c in classes:
        script.append('puts "@@ %s"' % c)
        script.append('puts [ui lang selectors {%s}]' % c)
    text = ui('\n'.join(script))
    by_class, cur = {}, None
    for line in text.splitlines():
        if line.startswith('@@ '):
            cur = line[3:].strip()
            by_class[cur] = set()
        elif cur is not None and line.strip() and not line.startswith('ERR'):
            parts = line.strip().split(' ', 1)
            if len(parts) == 2 and parts[0] in ('i', 'c'):
                by_class[cur].add((parts[0], parts[1]))
    return by_class


def method_sources(classes):
    """{(class, side, selector): source} through the browser's own host verb.

    One round trip per CLASS, not per method: 2453 separate calls is enough
    traffic to trip the control plane's 30-second deadline, and a client that
    times out mid-stream desynchronises — every method after it then reads as
    "the browser returned nothing", which is indistinguishable from the bug
    this test exists to find.
    """
    out = {}
    GS = '\x1d'
    for i, cls in enumerate(classes):
        text = ui('if {[catch {ui lang methodsrc {%s}} r]} '
                  '{ puts "TCLERR $r" } else { puts $r }' % cls)
        key, buf = None, []
        # split('\n'), NOT splitlines(): Python counts GS itself as a line
        # break, so splitlines() eats the very delimiter being looked for and
        # every method reads as empty.
        for line in text.split('\n'):
            if line.startswith(GS):
                if key:
                    out[key] = '\n'.join(buf)
                parts = line[1:].split(' ', 1)
                key = (cls, parts[0], parts[1] if len(parts) > 1 else '')
                buf = []
            elif key is not None:
                buf.append(line)
        if key:
            out[key] = '\n'.join(buf)
        if (i + 1) % 25 == 0:
            print('    %d/%d classes' % (i + 1, len(classes)))
    return out


# --- check 3: a displayed method must parse back to itself -------------------

RECEIVER = re.compile(r'^\s*\w+\s+(class\s+)?>>')


def reparses(cls, side, sel, src):
    """Feed the displayed slice back to the parser: it must be one whole method.

    A slice that names its receiver (`Array >> reject: aBlock [ … ]`) is a
    top-level reopen chunk and parses as it stands; a bare pattern (`do: b [ … ]`)
    is only a method inside a class body, so it gets a shell.
    """
    if not src.strip() or src.startswith('ERR') or src.startswith('TCLERR'):
        return False, 'empty'
    shell = src if RECEIVER.match(src) \
        else 'Object subclass: BrowserProbe [\n%s\n]\n' % src
    r = subprocess.run([ST_DUMP], input=shell, capture_output=True,
                       text=True, errors='replace')   # no arg = read stdin
    if r.returncode != 0:
        return False, r.stderr.strip().splitlines()[0][:100] if r.stderr else 'parse failed'
    found = set()
    methods_of(sexp(r.stdout), found)
    sels = {(s, x) for (_c, s, x) in found}
    if (side, sel) not in sels:
        return False, 'parsed as %s, not %s>>%s' % (sorted(sels), side, sel)
    if len(sels) != 1:
        return False, 'slice carries %d methods' % len(sels)
    return True, ''


def main():
    if not os.path.exists(ST_DUMP):
        sys.exit('build the reader first:  macdart/st/build.sh')

    print('parsing the world corpus with st_dump …')
    oracle = parse_corpus()
    print('  %d classes, %d methods' %
          (len(oracle), sum(len(v) for v in oracle.values())))

    classes = sorted(oracle)
    print('asking the running workspace for its browser index …')
    listed = image_members(classes)

    missing, phantom, checked = [], [], []
    for cls in classes:
        want = oracle[cls]
        got = listed.get(cls, set())
        for side, sel in sorted(want):
            if (side, sel) in got:
                checked.append((cls, side, sel))
            elif any(s == sel for _sd, s in got):
                # Right selector, wrong side — still a defect, and a confusing
                # one: the pane hides it behind the instance/class toggle.
                missing.append((cls, side, sel, 'wrong side'))
            else:
                missing.append((cls, side, sel))
        for side, sel in sorted(got):
            if (side, sel) not in want and not any(s == sel for _sd, s in want):
                phantom.append((cls, side, sel))

    print('checking every listed method re-parses to itself …')
    srcs = method_sources(classes)
    truncated = []
    for key in checked:
        src = srcs.get(key, '')
        ok, why = reparses(key[0], key[1], key[2], src)
        if not ok:
            truncated.append((key, why, src.splitlines()[:2]))

    print('\n--- report ---')
    print('methods the parser finds:      %d' % sum(len(v) for v in oracle.values()))
    print('missing from the browser:      %d' % len(missing))
    print('listed but not in the source:  %d' % len(phantom))
    print('displayed source incomplete:   %d' % len(truncated))

    def show(title, rows, n=15):
        if not rows:
            return
        print('\n%s' % title)
        for r in rows[:n]:
            print('  %s' % (r,))
        if len(rows) > n:
            print('  … and %d more' % (len(rows) - n))

    show('MISSING (parser found it, browser does not list it):', missing,
         40 if VERBOSE else 15)
    show('PHANTOM (browser lists it, parser does not):', phantom)
    show('INCOMPLETE (listed, but the source shown is not that method):',
         truncated, 40 if VERBOSE else 15)

    bad = len(missing) + len(phantom) + len(truncated)
    print('\n%s' % ('CLEAN' if bad == 0 else '%d defects' % bad))
    return 1 if bad else 0


def sig_to_selector(sig):
    """"at: k put: v" -> "at:put:" — language.dart's _sigToSelector, in Python."""
    sig = sig.strip()
    if not sig:
        return ''
    if ':' in sig:
        return ''.join(p + ':' for p in
                       [w[:-1] for w in sig.split() if w.endswith(':')])
    parts = sig.split()
    return parts[0] if parts else ''


if __name__ == '__main__':
    sys.exit(main())
