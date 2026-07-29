// MACVM Smalltalk (.mst) embedder native — Sprint 2 of ST_PLAN.md.
//
// One native, `ST_load(String src) -> String`, exposed to Dart as `stLoad`
// (declared in macdart/cocoa/cocoa.dart, wired through the dart:cocoa native
// resolver in cocoa_natives.mm). It runs the standalone reader (st::Lexer +
// st::Parser) and then st::Loader inside the CURRENT isolate, registering the
// parsed classes/methods/fields into the live VM object model. It returns a
// human-readable summary of what was registered, or an "ERR: ..." string on any
// lex/parse/finalize failure (it never throws). This is Sprint 2's verification
// surface: it inspects registration metadata only and never invokes an ST
// method (their bodies are not compiled until Sprint 3).

#include <stdio.h>

#include <memory>
#include <string>
#include <vector>

#include "include/dart_api.h"

#include "vm/dart_api_impl.h"  // DARTSCOPE / TransitionNativeToVM / HANDLESCOPE
#include "vm/thread.h"

#include "st_lexer.h"
#include "st_loader.h"
#include "st_parser.h"

namespace dart {
namespace bin {

void ST_load(Dart_NativeArguments args) {
  // --- 1) read the source argument (public API; native execution state) -----
  Dart_Handle src_h = Dart_GetNativeArgument(args, 0);
  const char* src_c = NULL;
  Dart_Handle err = Dart_StringToCString(src_h, &src_c);
  if (Dart_IsError(err) || src_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewStringFromCString("ERR: bad source argument"));
    return;
  }
  std::string source(src_c);

  // --- 2) lex + parse (pure C++17 reader, no VM state needed) ---------------
  ::st::Lexer lexer(source);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: lex %d:%d: %s", lex_err.line, lex_err.col,
             lex_err.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  ::st::Parser parser(std::move(tokens));
  ::st::ParseError perr;
  std::unique_ptr<::st::ProgramNode> program = parser.ParseProgram(&perr);
  if (program == nullptr || !perr.ok) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: parse %d:%d: %s", perr.line, perr.col,
             perr.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }

  // --- 3) register into the live object model (transition to VM state) ------
  std::string summary;
  std::string load_err;
  bool ok = false;
  {
    Thread* thread = Thread::Current();
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    ok = ::st::Loader::Load(std::move(program), source, &summary, &load_err);
  }

  if (!ok) {
    Dart_SetReturnValue(args, Dart_NewStringFromCString(load_err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(summary.c_str()));
}

}  // namespace bin
}  // namespace dart
