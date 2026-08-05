// MACVM Smalltalk (.mst) IL builder — Sprint 3 of ST_PLAN.md. THE headline.
//
// Turns one ST method's AST (an st::MethodNode, recovered from the dormant
// `kernel_function` marker the Sprint-2 loader stamped onto its VM Function)
// into a dart::FlowGraph* — the exact IL shape the stock 1.24.3 parser / kernel
// front-end produce, so the shared SSA optimizer + ARM64 back-end JIT it
// unchanged. Modeled on runtime/vm/kernel_to_il.cc (BuildGraphOfFunction + the
// emission primitives) per docs/dart-vm-frontend-guide.md.
//
// This is a VM-internal translation unit (it #includes the engine headers and
// calls FlowGraph / Instruction / ParsedFunction / LocalScope), compiled into
// the dart_cocoa static lib next to the other st_*.cc. The compiler.cc hook
// (patches/macdart-port.patch) routes ST-marked functions here.

#ifndef MACDART_ST_ST_FLOW_GRAPH_BUILDER_H_
#define MACDART_ST_ST_FLOW_GRAPH_BUILDER_H_

#include <stdint.h>

// Forward declarations only — the header is included by compiler.cc (namespace
// dart) and must not drag in the AST or engine headers.
namespace dart {
class FlowGraph;
class ParsedFunction;
class ICData;
template <typename T>
class ZoneGrowableArray;
}  // namespace dart

namespace st {

// The single entry point (front-end guide §5): build the FlowGraph for the
// ST-marked function held by `pf`. Recovers the st::MethodNode from
// pf->function().kernel_function(), does scope prep + AllocateVariables, then
// emits the body via a Fragment combinator. Returns a non-NULL, closed,
// stack-balanced FlowGraph ready for ComputeSSA.
dart::FlowGraph* BuildGraph(
    dart::ParsedFunction* pf,
    const dart::ZoneGrowableArray<const dart::ICData*>& ic_data_array,
    intptr_t osr_id);

}  // namespace st

#endif  // MACDART_ST_ST_FLOW_GRAPH_BUILDER_H_
