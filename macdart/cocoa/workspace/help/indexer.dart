// MACDART help indexer — a searchable Dart V1 reference, built from the truth.
//
// Nothing here is transcribed, summarised or remembered: the index is parsed
// from the very files this VM was built from, so it cannot drift from the
// language you are actually running.
//
//   1. the SDK libraries      sdk/sdk/lib/{core,async,collection,…}
//      — every doc-commented declaration, with its signature and file:line.
//        Only DOCUMENTED declarations become entries (plus every class): help
//        is the documented API, and that keeps the index small and useful.
//   2. the language spec      sdk/docs/language/dartLangSpec.tex
//      — one entry per section/subsection, de-TeXed, grammar blocks kept.
//        This is the part that answers "what does sync* mean", which no
//        library doc ever will.
//   3. dart:cocoa             macdart/cocoa/cocoa.dart
//      — MACDART's own bridge, documented the same way.
//
// It runs in its OWN isolate because parsing ~9MB of source would stall the
// window, and the UI isolate is the one that must never stall. The index stays
// here; the UI holds only the rows it is showing.
//
//   ui  -> here   ['q', query]      ['get', id]
//   here -> ui    ['ready', n]  ['results', query, rows]  ['detail', id, text]
import 'dart:isolate';
import 'dart:io';

// kind, where (library or spec chapter), name, signature, doc, file, line
List _entries = <List>[];

main(List args, SendPort ui) {
  var rp = new ReceivePort();
  ui.send(<dynamic>['port', rp.sendPort]);
  var sdkLib = args[0], spec = args[1], cocoa = args[2];
  try {
    _indexLibraries(sdkLib);
    _indexCocoa(cocoa);
    _indexSpec(spec);
  } catch (e) {
    ui.send(<dynamic>['status', 'help: indexing failed — ' + e.toString()]);
  }
  ui.send(<dynamic>['ready', _entries.length]);
  rp.listen((m) {
    if (m is! List || m.isEmpty) return;
    if (m[0] == 'q') ui.send(<dynamic>['results', m[1], _search(m[1].toString())]);
    else if (m[0] == 'get') ui.send(<dynamic>['detail', m[1], _detail(m[1])]);
  });
}

// --- the SDK libraries ------------------------------------------------------
// Only the libraries this VM actually has. The browser/js ones ship in the same
// tree and would be a cruel thing to offer someone whose VM cannot load them.
const List<String> _kLibs = const <String>[
  'core', 'async', 'collection', 'convert', 'developer',
  'io', 'isolate', 'math', 'mirrors', 'typed_data', 'profiler'
];

void _indexLibraries(String root) {
  for (var lib in _kLibs) {
    var dir = new Directory(root + '/' + lib);
    if (!dir.existsSync()) continue;
    for (var f in dir.listSync()) {
      if (!f.path.endsWith('.dart')) continue;
      try { _indexSource(f.path, 'dart:' + lib); } catch (e) { }
    }
  }
}

void _indexCocoa(String path) {
  if (new File(path).existsSync()) {
    try { _indexSource(path, 'dart:cocoa'); } catch (e) { }
  }
}

final RegExp _classRe =
    new RegExp(r'^(?:abstract\s+)?class\s+(\w+)');
// A declaration worth indexing: something with a name, and either a parameter
// list, a fat arrow, an initialiser or a plain terminator.
final RegExp _declRe = new RegExp(
    r'^(?:external\s+|static\s+|final\s+|const\s+|factory\s+|abstract\s+|covariant\s+)*'
    r'(?:[\w<>,\[\]\.\s\$]+\s+)?'
    r'(?:get\s+|set\s+|operator\s+)?'
    r'([\w\.\$\[\]=<>+\-*/%~^&|!]+)\s*(?:\(|=>|=|;|\{)');

void _indexSource(String path, String lib) {
  var lines = new File(path).readAsLinesSync();
  var doc = <String>[];
  var cls;
  var i = 0;
  while (i < lines.length) {
    var raw = lines[i];
    var t = raw.trim();

    // --- doc comments, both spellings
    if (t.startsWith('///')) {
      doc.add(t.length > 3 ? t.substring(3).trim() : '');
      i++;
      continue;
    }
    if (t.startsWith('/**')) {
      var body = t.substring(3);
      if (body.contains('*/')) {
        doc.add(body.substring(0, body.indexOf('*/')).trim());
        i++;
      } else {
        if (body.trim().isNotEmpty) doc.add(body.trim());
        i++;
        while (i < lines.length) {
          var b = lines[i].trim();
          if (b.startsWith('*/')) { i++; break; }
          if (b.startsWith('*')) b = b.length > 1 ? b.substring(1) : '';
          if (b.contains('*/')) { doc.add(b.substring(0, b.indexOf('*/')).trim()); i++; break; }
          doc.add(b.trim());
          i++;
        }
      }
      continue;
    }

    if (t.isEmpty) { i++; continue; }
    if (t.startsWith('//')) { i++; continue; }
    if (t.startsWith('@')) { i++; continue; }      // annotation: doc still applies
    if (t.startsWith('}')) {
      if (raw.startsWith('}')) cls = null;         // a class ended at column 0
      i++; doc = <String>[];
      continue;
    }

    // --- a class
    var cm = _classRe.firstMatch(t);
    if (cm != null && !raw.startsWith(' ')) {
      cls = cm.group(1);
      _add('class', lib, cls, _signature(lines, i), doc, path, i + 1);
      doc = <String>[];
      i++;
      continue;
    }

    // --- a declaration, only if it is documented (help = the documented API)
    if (doc.isNotEmpty) {
      var dm = _declRe.firstMatch(t);
      if (dm != null) {
        var name = dm.group(1);
        if (name != null && name.isNotEmpty && !_kNoise.contains(name)) {
          var kind = raw.startsWith(' ') && cls != null ? 'member' : 'top-level';
          var shown = name;
          if (kind == 'member') {
            // A constructor's name IS the class name (or Class.named), so
            // prefixing it again gave "Future.Future" and
            // "HttpServer.HttpServer.listenOn". Show it the way you would
            // write it instead.
            if (name == cls || name.startsWith(cls + '.')) shown = 'new ' + name;
            else shown = cls + '.' + name;
          }
          _add(kind, lib, shown, _signature(lines, i), doc, path, i + 1);
        }
      }
    }
    doc = <String>[];
    i++;
  }
}

const List<String> _kNoise = const <String>[
  'if', 'for', 'while', 'switch', 'return', 'throw', 'assert', 'else', 'do',
  'try', 'catch', 'new', 'this', 'super', 'var', 'final', 'const'
];

/// The declaration as written, up to where the body starts — continuation
/// lines included, because a wrapped parameter list is still the signature.
///
/// Scanned with a depth counter rather than by looking for " {": a named
/// parameter group IS a brace inside the parameter list, and matching on it
/// truncated every such signature at the comma —
/// "listen(void onData(T event)," and no more.
String _signature(List<String> lines, int at) {
  var out = new StringBuffer();
  var depth = 0;
  // Long enough for the worst real one (Isolate.spawnUri wraps over ten lines);
  // past that a "signature" is something else going on.
  for (var k = at; k < lines.length && k < at + 16; k++) {
    var t = lines[k].trim();
    if (k > at) out.write(' ');
    for (var i = 0; i < t.length; i++) {
      var c = t[i];
      if (c == '(' || c == '[') depth++;
      else if (c == ')' || c == ']') { if (depth > 0) depth--; }
      else if (depth == 0) {
        if (c == ';' || c == '{') return _tidy(out.toString());
        if (c == '=' && i + 1 < t.length && t[i + 1] == '>') return _tidy(out.toString());
      }
      out.write(c);
    }
  }
  return _tidy(out.toString());
}

/// A wrapped declaration keeps the indentation it was wrapped with; on one
/// line that reads as gaps.
String _tidy(String s) => s.replaceAll(new RegExp(r'\s+'), ' ').trim();

void _add(String kind, String where, String name, String sig, List<String> doc,
          String file, int line) {
  // Library-private names are implementation, not API: _Future and friends
  // were outranking the class you actually meant.
  if (name.startsWith('_') || name.contains('._') || name.contains(' _')) return;
  _entries.add(<dynamic>[kind, where, name, sig, _clean(doc), file, line]);
}

String _clean(List<String> doc) {
  var out = doc.join('\n').trim();
  while (out.contains('\n\n\n')) out = out.replaceAll('\n\n\n', '\n\n');
  return out;
}

// --- the language spec ------------------------------------------------------
// LaTeX, but the useful parts survive a mechanical de-TeX: prose, grammar
// blocks and the section structure. Keyword macros are the neat case —
// \AWAIT{} and friends are all-caps and argument-less, so lowercasing the
// macro name gives back the keyword the spec is talking about.
final RegExp _secRe = new RegExp(r'^\\(sub)?(sub)?section\{\s*([^}]*)\}');
final RegExp _kwMacro = new RegExp(r'\\([A-Z][A-Z0-9]+)\{\}');
// The spec writes the modifiers bare — "\ASYNC* or \SYNC*" — so the braced
// rule alone deleted the keyword and left a lone asterisk. The lookahead keeps
// it off mixed-case macros like \LMHash.
final RegExp _kwBare = new RegExp(r'\\([A-Z][A-Z0-9]*)(?![A-Za-z])');
final RegExp _refMacro = new RegExp(r'\\ref\{([^{}]*)\}');
// Only these are noise worth deleting outright; everything else KEEPS its
// argument. Deleting unknown macros wholesale ate the inline code the prose is
// about — "\code{$e$..\metavar{suffix}}" left "has the form" and nothing else.
final RegExp _noiseMacro =
    new RegExp(r'\\(?:LMHash|LMLabel|label|index|cite|pageref)\{[^{}]*\}');
final RegExp _anyMacro = new RegExp(r'\\[A-Za-z]+\{([^{}]*)\}');
final RegExp _bareMacro = new RegExp(r'\\[A-Za-z]+\s?');

void _indexSpec(String path) {
  var f = new File(path);
  if (!f.existsSync()) return;
  var lines = f.readAsLinesSync();
  var title, chapter = 'Language';
  var body = <String>[];
  var startLine = 0;
  var flush = () {
    if (title == null) return;
    var text = _deTex(body);
    if (text.trim().isEmpty) return;
    _entries.add(<dynamic>['spec', chapter, title, '', text, path, startLine]);
  };
  for (var i = 0; i < lines.length; i++) {
    var m = _secRe.firstMatch(lines[i]);
    if (m != null) {
      flush();
      title = m.group(3).trim();
      if (m.group(1) == null) chapter = title;   // a \section starts a chapter
      body = <String>[];
      startLine = i + 1;
      continue;
    }
    if (title != null) body.add(lines[i]);
  }
  flush();
}

String _deTex(List<String> lines) {
  var out = new StringBuffer();
  var blank = false;
  for (var raw in lines) {
    var s = raw;
    if (s.trimLeft().startsWith('%')) continue;             // a spec-writer's note
    s = s.replaceAll(_noiseMacro, '').replaceAll('\\LMHash{}', '');
    if (s.contains('\\begin{grammar}')) { out.write('\n  grammar:\n'); continue; }
    if (s.contains('\\end{grammar}')) { out.write('\n'); continue; }
    if (s.contains('\\begin{') || s.contains('\\end{')) continue;
    s = s.replaceAllMapped(_kwMacro, (m) => m.group(1).toLowerCase());
    s = s.replaceAllMapped(_refMacro, (m) => '(see ' + m.group(1) + ')');
    s = s.replaceAllMapped(_kwBare, (m) => m.group(1).toLowerCase());
    // Unwrap repeatedly: the innermost macro has to go first for a nested one
    // to become unwrappable at all.
    for (var pass = 0; pass < 4 && s.contains('\\'); pass++) {
      s = s.replaceAllMapped(_anyMacro, (m) => m.group(1));
    }
    s = s.replaceAll('{\\bf ', '').replaceAll('{\\em ', '').replaceAll('{\\it ', '')
         .replaceAll('{\\escapegrammar ', '').replaceAll('{\\tt ', '');
    s = s.replaceAll('\\&', '&').replaceAll('\\_', '_').replaceAll('\\%', '%')
         .replaceAll('\\#', '#').replaceAll('\\{', '{').replaceAll('\\}', '}');
    s = s.replaceAll(_bareMacro, '');
    s = s.replaceAll('\$', '').replaceAll('~', ' ');
    s = s.replaceAll('}', '').replaceAll('{', '');
    var t = s.trimRight();
    if (t.trim().isEmpty) {
      if (blank) continue;
      blank = true;
      out.write('\n');
    } else {
      blank = false;
      out.write(t);
      out.write('\n');
    }
  }
  return out.toString().trim();
}

// --- search -----------------------------------------------------------------
// Ranked, because a search for "add" should not open with a paragraph of spec
// prose that happens to contain the word. Name matches beat doc matches; exact
// beats prefix beats contains.
List _search(String q) {
  var query = q.trim().toLowerCase();
  if (query.isEmpty) return <dynamic>[];
  var scored = <List>[];
  for (var i = 0; i < _entries.length; i++) {
    var e = _entries[i];
    var name = e[2].toString().toLowerCase();
    // "new Future" is how you write the constructor, but "future" is what you
    // type to look for it — rank it on the name, not the spelling.
    var bare = name.startsWith('new ') ? name.substring(4) : name;
    if (bare.contains('.')) bare = bare.substring(bare.lastIndexOf('.') + 1);
    var score = 0;
    if (name == query || bare == query) score = 100;
    else if (bare.startsWith(query)) score = 80;
    else if (name.contains(query)) score = 60;
    else if (e[3].toString().toLowerCase().contains(query)) score = 30;
    else if (e[4].toString().toLowerCase().contains(query)) score = 20;
    if (score == 0) continue;
    // A documented class beats a member beats a spec paragraph, all else equal.
    if (e[0] == 'class') score += 6;
    else if (e[0] == 'spec') score += (score >= 60) ? 8 : 0;
    scored.add(<dynamic>[score, i]);
  }
  scored.sort((a, b) {
    if (a[0] != b[0]) return b[0] - a[0];
    return _entries[a[1]][2].toString().length - _entries[b[1]][2].toString().length;
  });
  var rows = <List>[];
  for (var s in scored) {
    if (rows.length >= 200) break;
    var e = _entries[s[1]];
    rows.add(<dynamic>[s[1], e[0], e[1], e[2], _firstLine(e[4])]);
  }
  return rows;
}

String _firstLine(String doc) {
  var d = doc.trim();
  if (d.isEmpty) return '';
  var nl = d.indexOf('\n');
  var one = (nl < 0 ? d : d.substring(0, nl)).trim();
  return one.length > 110 ? one.substring(0, 110) + '…' : one;
}

/// The full entry, formatted for the detail pane.
String _detail(int id) {
  if (id < 0 || id >= _entries.length) return '';
  var e = _entries[id];
  var out = new StringBuffer();
  out.write(e[2]);
  out.write('\n');
  out.write(e[0] == 'spec' ? ('Dart language specification — ' + e[1])
                           : (e[0] + '  ·  ' + e[1]));
  out.write('\n');
  if (e[3].toString().isNotEmpty) { out.write('\n'); out.write(e[3]); out.write('\n'); }
  out.write('\n');
  out.write(e[4]);
  out.write('\n\n— ');
  out.write(e[5]);
  out.write(':');
  out.write(e[6].toString());
  out.write('\n');
  return out.toString();
}
