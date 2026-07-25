// MACDART dart:cocoa native resolver. Parallels bin/io_natives.h — the Builtin
// native lookup chain falls through to CocoaNativeLookup for dart:cocoa.
#ifndef MACDART_COCOA_NATIVES_H_
#define MACDART_COCOA_NATIVES_H_

#include "include/dart_api.h"

namespace dart {
namespace bin {

Dart_NativeFunction CocoaNativeLookup(Dart_Handle name,
                                      int argument_count,
                                      bool* auto_setup_scope);
const uint8_t* CocoaNativeSymbol(Dart_NativeFunction nf);

}  // namespace bin
}  // namespace dart

#endif  // MACDART_COCOA_NATIVES_H_
