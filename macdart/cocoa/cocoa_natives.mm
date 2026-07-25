// MACDART dart:cocoa natives (Phase 1). Objective-C++, compiled -fno-objc-arc
// (manual retain/release — the VM owns the reference count, not ARC).
//
// Phase 1 uses direct typed objc_msgSend casts for the known selectors (the
// approach validated in cocoa/objc_shim.m's test). The general dynamic send
// through the fixed-shape shim + the noSuchMethod ergonomic layer come in later
// phases; see MACDART/COCOA_PLAN.md.
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>
#include <unistd.h>

#include "include/dart_api.h"
#include "cocoa_natives.h"

namespace dart {
namespace bin {

static int64_t IntArg(Dart_NativeArguments args, int i) {
  int64_t v = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, i), &v);
  return v;
}

// getpid() — the POSIX FFI smoke test.
static void Cocoa_getpid(Dart_NativeArguments args) {
  Dart_SetReturnValue(args, Dart_NewInteger(getpid()));
}

// [NSString stringWithUTF8String:s] -> retained id, returned as an int handle.
static void Cocoa_nsStringFromCString(Dart_NativeArguments args) {
  const char* cstr = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &cstr);
  id (*send)(id, SEL, const char*) = (id (*)(id, SEL, const char*))objc_msgSend;
  id str = send((id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"), cstr);
  if (str != nil) [str retain];  // own one strong ref (MRC)
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)str));
}

// -[NSString length]
static void Cocoa_nsStringLength(Dart_NativeArguments args) {
  id obj = (id)IntArg(args, 0);
  NSUInteger (*send)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
  NSUInteger len = send(obj, sel_registerName("length"));
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)len));
}

// -[NSString UTF8String] -> Dart String
static void Cocoa_nsStringUtf8(Dart_NativeArguments args) {
  id obj = (id)IntArg(args, 0);
  const char* (*send)(id, SEL) = (const char* (*)(id, SEL))objc_msgSend;
  const char* c = send(obj, sel_registerName("UTF8String"));
  Dart_SetReturnValue(args, Dart_NewStringFromCString(c != NULL ? c : ""));
}

// --- resolver ---------------------------------------------------------------
#define COCOA_NATIVE_LIST(V)                                                   \
  V(Cocoa_getpid, 0)                                                           \
  V(Cocoa_nsStringFromCString, 1)                                              \
  V(Cocoa_nsStringLength, 1)                                                   \
  V(Cocoa_nsStringUtf8, 1)

static struct CocoaEntry {
  const char* name_;
  Dart_NativeFunction function_;
  int argument_count_;
} CocoaEntries[] = {
#define COCOA_ENTRY(name, argc) {#name, name, argc},
    COCOA_NATIVE_LIST(COCOA_ENTRY)
#undef COCOA_ENTRY
};

Dart_NativeFunction CocoaNativeLookup(Dart_Handle name,
                                      int argument_count,
                                      bool* auto_setup_scope) {
  const char* function_name = NULL;
  if (Dart_IsError(Dart_StringToCString(name, &function_name))) return NULL;
  if (auto_setup_scope != NULL) *auto_setup_scope = true;
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    struct CocoaEntry* entry = &CocoaEntries[i];
    if (strcmp(function_name, entry->name_) == 0 &&
        entry->argument_count_ == argument_count) {
      return entry->function_;
    }
  }
  return NULL;
}

const uint8_t* CocoaNativeSymbol(Dart_NativeFunction nf) {
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    if (CocoaEntries[i].function_ == nf) {
      return reinterpret_cast<const uint8_t*>(CocoaEntries[i].name_);
    }
  }
  return NULL;
}

}  // namespace bin
}  // namespace dart
