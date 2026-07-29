// MACVM Smalltalk (.mst) loader — Sprint 2 of ST_PLAN.md. See st_loader.h.
//
// Structure mirrors runtime/vm/kernel_reader.cc:
//   ReadLibrary   -> the library + toplevel class scaffolding here,
//   ReadClass     -> RegisterClasses() sub-pass B (fields + super),
//   ReadProcedure -> the Function::New + set_kernel_function loop,
//   set_kernel_function(node) -> the dormant Sprint-2 marker (never invoked).
//
// The one structural difference from the kernel reader: ST superclasses are
// resolved by NAME (there is no kernel canonical-name table). Classes are
// therefore created in two sub-passes — all Class objects first (so a subclass
// can name a superclass defined later in the same file), then their supers,
// fields and functions — after which ClassFinalizer::ProcessPendingClasses()
// resolves the super chain and finalizes the declaration types.

#include "st_loader.h"

#include <stdio.h>
#include <string.h>

#include <map>
#include <vector>

#include "vm/class_finalizer.h"
#include "vm/isolate.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/symbols.h"
#include "vm/thread.h"

namespace st {

// Every loaded AST is retained for the isolate's lifetime: the Functions we
// register carry raw `kernel_function` pointers into these trees, so the trees
// must never be freed. (Sprint 3's compiler hook will read these markers.)
static std::vector<ProgramNode*> g_retained_programs;
// Monotonic counter giving each load a distinct library URL (Library::Register
// asserts the URL is not already present).
static int g_load_counter = 0;

namespace {

// One ST class as aggregated across its `subclass:` definition plus any later
// `extend` / external `>>` contributions in the same program.
struct MethodEntry {
  MethodNode* node;     // borrowed from the retained AST (marker target)
  bool is_static;       // class-side method -> registered as a static Function
};
struct ClassAgg {
  std::string name;
  std::string super;         // superclass name from the `subclass:` form
  bool has_super = false;    // a ClassDef supplied `super`; extends do not
  std::vector<std::string> ivars;
  std::vector<std::string> class_vars;  // <classVars: A B C> pragma names
  std::vector<MethodEntry> methods;
};

// Ordered set of aggregated classes (insertion order preserved for a stable,
// source-like summary), keyed by name.
class ClassTable {
 public:
  ClassAgg& GetOrAdd(const std::string& name) {
    auto it = index_.find(name);
    if (it != index_.end()) return entries_[it->second];
    index_[name] = entries_.size();
    entries_.emplace_back();
    entries_.back().name = name;
    return entries_.back();
  }
  std::vector<ClassAgg>& entries() { return entries_; }

 private:
  std::vector<ClassAgg> entries_;
  std::map<std::string, size_t> index_;
};

void AggregateMethods(ClassAgg* agg,
                      std::vector<std::unique_ptr<MethodNode>>* methods,
                      bool force_static) {
  for (auto& m : *methods) {
    agg->methods.push_back(
        MethodEntry{m.get(), force_static || m->is_class_side});
  }
}

void AggregateIvars(ClassAgg* agg,
                    std::vector<std::unique_ptr<VarDeclNode>>* ivars) {
  for (auto& decl : *ivars) {
    for (const std::string& n : decl->names) agg->ivars.push_back(n);
  }
}

// Sprint 11b: `<classVars: A B C>` — whitespace-separated names after the
// keyword become class variables (static Fields on the metaclass shadow,
// visible from both metalevels of the class and its subclasses).
void AggregateClassVars(ClassAgg* agg, const std::vector<Pragma>& pragmas) {
  for (const Pragma& p : pragmas) {
    const std::string& text = p.text;
    static const char kKey[] = "classVars: ";
    if (text.compare(0, sizeof(kKey) - 1, kKey) != 0) continue;
    std::string rest = text.substr(sizeof(kKey) - 1);
    std::string cur;
    for (size_t i = 0; i <= rest.size(); i++) {
      const char c = (i < rest.size()) ? rest[i] : ' ';
      if (c == ' ' || c == '\t' || c == '\n') {
        if (!cur.empty()) agg->class_vars.push_back(cur);
        cur.clear();
      } else {
        cur.push_back(c);
      }
    }
  }
}

// Walk the top-level items and fold them into the class table. Do-it statements
// and anything that is not a class/extension are ignored (Sprint 2 registers
// declarations only).
void Aggregate(ProgramNode* program, ClassTable* table) {
  for (auto& item : program->items) {
    Node* n = item.get();
    if (auto* cd = dynamic_cast<ClassDefNode*>(n)) {
      ClassAgg& agg = table->GetOrAdd(cd->name);
      if (!agg.has_super) {
        agg.super = cd->superclass;
        agg.has_super = true;
      }
      AggregateIvars(&agg, &cd->ivars);
      AggregateClassVars(&agg, cd->pragmas);
      AggregateMethods(&agg, &cd->methods, /*force_static=*/false);
    } else if (auto* ex = dynamic_cast<ExtendNode*>(n)) {
      ClassAgg& agg = table->GetOrAdd(ex->class_name);
      AggregateIvars(&agg, &ex->ivars);
      AggregateClassVars(&agg, ex->pragmas);
      AggregateMethods(&agg, &ex->methods, /*force_static=*/ex->is_class_side);
    } else if (auto* em = dynamic_cast<ExtMethodNode*>(n)) {
      ClassAgg& agg = table->GetOrAdd(em->class_name);
      agg.methods.push_back(
          MethodEntry{em->method.get(), em->method->is_class_side});
    }
  }
}

// Resolve an ST superclass name to a Dart super Type. The minimal bridge roots
// every class at dart:core's Object EXCEPT when the named superclass is another
// ST class — in the SAME load, or (Sprint 9) in ANY earlier st: library, so a
// user file's `Error subclass: MyErr` finds the prelude's Error. We do NOT
// bridge to arbitrary dart:core classes here: most (String, int, double, List,
// …) are sealed and cannot be extended, so `String subclass: Symbol` would
// fail finalization. The real base-class bridging — where an ST send is routed
// to a dart:core method — happens in the IL builder, not by literally
// subclassing a core type. The returned Type is intentionally UNFINALIZED for
// the in-load case; ProcessPendingClasses finalizes it.
dart::RawType* ResolveSuper(dart::Thread* thread,
                            const dart::Library& lib,
                            const std::string& name) {
  using namespace dart;
  Zone* zone = thread->zone();
  if (name.empty()) return Type::ObjectType();
  const String& sym = String::Handle(zone, Symbols::New(thread, name.c_str()));
  // LookupLocalClass (not LookupClass) — the latter follows the dart:core import
  // and would resolve `String`/`int`/… to the sealed core class.
  Class& super = Class::Handle(zone, lib.LookupLocalClass(sym));
  if (super.IsNull()) {
    super = FindStClassByName(thread, name.c_str());  // an earlier st: library
  }
  if (super.IsNull() || super.NumTypeParameters() > 0) {
    return Type::ObjectType();
  }
  return Type::New(super, Object::null_type_arguments(),
                   TokenPosition::kNoSource);
}

// Create one ST method's Function on `owner` (Sprint 3 shape: dynamic params,
// the AST-node marker, non-inlinable). Statics carry no implicit receiver.
dart::RawFunction* MakeStFunction(dart::Thread* thread,
                                  const dart::Class& owner,
                                  MethodNode* m,
                                  bool is_static) {
  using namespace dart;
  Zone* zone = thread->zone();
  // Registered under the canonical mangled name (':' -> '_'): valid as a Dart
  // method name and keeps `signal` vs `signal:` distinct on one class.
  const String& sel = String::Handle(
      zone, Symbols::New(thread, MangleSelector(m->selector).c_str()));
  const Function& fn = Function::Handle(
      zone, Function::New(sel, RawFunction::kRegularFunction, is_static,
                          /*is_const=*/false, /*is_abstract=*/false,
                          /*is_external=*/false, /*is_native=*/false, owner,
                          TokenPosition::kNoSource, Heap::kOld));
  fn.set_result_type(Object::dynamic_type());
  // Every ST method has an implicit parameter 0: instance methods take the
  // receiver (`this`); class-side methods take the RECEIVING CLASS (Sprint 11
  // — Smalltalk class-side `self` is the class the message was sent to, not
  // the defining class, so `IdleTask link:..` inheriting TaskControlBlock's
  // constructor allocates an IdleTask).
  const intptr_t num_params = 1 + static_cast<intptr_t>(m->args.size());
  fn.set_num_fixed_parameters(num_params);
  fn.SetNumOptionalParameters(0, /*are_positional=*/true);
  fn.set_parameter_types(
      Array::Handle(zone, Array::New(num_params, Heap::kOld)));
  fn.set_parameter_names(
      Array::Handle(zone, Array::New(num_params, Heap::kOld)));
  intptr_t p = 0;
  {
    fn.SetParameterTypeAt(p, Object::dynamic_type());
    fn.SetParameterNameAt(p, is_static ? String::Handle(
                                             zone, Symbols::New(thread, "self"))
                                       : String::Handle(zone,
                                                        Symbols::This().raw()));
    p++;
  }
  for (size_t a = 0; a < m->args.size(); a++, p++) {
    fn.SetParameterTypeAt(p, Object::dynamic_type());
    fn.SetParameterNameAt(
        p, String::Handle(zone, Symbols::New(thread, m->args[a].c_str())));
  }
  fn.set_kernel_function(reinterpret_cast<void*>(static_cast<Node*>(m)));
  fn.set_is_inlinable(false);
  return fn.raw();
}

}  // namespace

std::string MangleSelector(const std::string& selector) {
  std::string out = selector;
  for (size_t i = 0; i < out.size(); i++) {
    if (out[i] == ':') out[i] = '_';
  }
  return out;
}

// The shared cross-load resolver (st_loader.h): newest st: library first.
dart::RawClass* FindStClassByName(dart::Thread* thread, const char* name) {
  using namespace dart;
  Zone* zone = thread->zone();
  Isolate* isolate = thread->isolate();
  const GrowableObjectArray& libs = GrowableObjectArray::Handle(
      zone, isolate->object_store()->libraries());
  const String& cname = String::Handle(zone, Symbols::New(thread, name));
  Library& lib = Library::Handle(zone);
  String& url = String::Handle(zone);
  Class& cls = Class::Handle(zone);
  for (intptr_t i = libs.Length() - 1; i >= 0; i--) {
    lib ^= libs.At(i);
    url = lib.url();
    if (url.IsNull()) continue;
    if (strncmp(url.ToCString(), "st:", 3) != 0) continue;
    cls = lib.LookupLocalClass(cname);
    if (!cls.IsNull()) return cls.raw();
  }
  return Class::null();
}

bool Loader::Load(std::unique_ptr<ProgramNode> program_owned,
                  const std::string& source,
                  std::string* summary,
                  std::string* error,
                  const char* url_override,
                  bool* has_toplevel) {
  using namespace dart;

  // Retain the AST for the isolate's lifetime BEFORE stamping any marker into
  // it (a failed load still leaves valid marker targets rather than danglers).
  ProgramNode* program = program_owned.release();
  g_retained_programs.push_back(program);

  ClassTable table;
  Aggregate(program, &table);

  // Sprint 11b: bare top-level statements (MACVM "do-its" — e.g. the file's
  // own benchmark driver line) are collected IN ORDER into a synthesized
  // `STMain class >> main`, registered like any other class-side method.
  // ST_load invokes it after a successful load (do-its run at load time —
  // MACVM semantics). The synthesized nodes are appended to the retained
  // program, so markers stay valid for the isolate's lifetime.
  {
    std::vector<NodePtr> toplevel;
    for (auto& item : program->items) {
      Node* n = item.get();
      if (n == nullptr) continue;
      if (dynamic_cast<ClassDefNode*>(n) != nullptr) continue;
      if (dynamic_cast<ExtendNode*>(n) != nullptr) continue;
      if (dynamic_cast<ExtMethodNode*>(n) != nullptr) continue;
      toplevel.push_back(std::move(item));
    }
    if (!toplevel.empty()) {
      std::unique_ptr<MethodNode> main_m(new MethodNode());
      main_m->is_class_side = true;
      main_m->selector = "main";
      main_m->statements = std::move(toplevel);
      std::unique_ptr<ClassDefNode> cd(new ClassDefNode());
      cd->name = "STMain";
      cd->superclass = "Object";
      cd->methods.push_back(std::move(main_m));
      ClassAgg& agg = table.GetOrAdd("STMain");
      if (!agg.has_super) {
        agg.super = "Object";
        agg.has_super = true;
      }
      agg.methods.push_back(MethodEntry{cd->methods[0].get(), true});
      program->items.push_back(std::move(cd));
      if (has_toplevel != 0) *has_toplevel = true;
    }
  }

  std::vector<ClassAgg>& entries = table.entries();

  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  Isolate* isolate = thread->isolate();

  // --- the library (imports dart:core so ST classes can later call it) ------
  const String& url = String::Handle(
      zone, (url_override != 0)
                ? String::New(url_override, Heap::kOld)
                : String::NewFormatted("st:mst/%d", g_load_counter++));
  const String& src = String::Handle(zone, String::New(source.c_str()));
  Library& library = Library::Handle(zone, Library::New(url));
  // Import dart:core so ST classes can later resolve/call it (this replicates
  // Library::NewLibraryHelper(url, /*import_core_lib=*/true), whose helper is
  // private; the public Library::New does not import core).
  const Library& core_lib = Library::Handle(zone, Library::CoreLibrary());
  const Namespace& core_ns = Namespace::Handle(
      zone, Namespace::New(core_lib, Object::null_array(), Object::null_array()));
  library.AddImport(core_ns);
  library.SetLoadInProgress();
  library.Register(thread);

  // One Script backs every class/function in this load (a non-null script keeps
  // Function::IsOptimizable from mistaking these for test functions).
  const Script& script = Script::Handle(
      zone, Script::New(url, src, RawScript::kScriptTag));

  // Toplevel class holder (kernel_reader always makes one; library consumers
  // assume library.toplevel_class() is non-null).
  Class& toplevel = Class::Handle(
      zone, Class::New(library, Symbols::TopLevel(), script,
                       TokenPosition::kNoSource));
  toplevel.set_is_cycle_free();
  toplevel.SetFunctions(Object::empty_array());
  toplevel.SetFields(Object::empty_array());
  library.set_toplevel_class(toplevel);

  GrowableObjectArray& pending = GrowableObjectArray::Handle(
      zone, isolate->object_store()->pending_classes());

  // --- sub-pass A: create every Class (so supers resolve by name later) -----
  // Sprint 11, the METACLASS skeleton: each ST class Foo also gets a shadow
  // `Foo class` holding its CLASS-SIDE methods — real Smalltalk puts them on
  // the metaclass, and flattening both sides into one Dart class collides
  // when a selector exists on both (TaskState running, in the corpus). The
  // shadow's super chain mirrors the instance chain, so inherited class-side
  // methods dispatch correctly.
  std::vector<const Class*> klasses(entries.size());
  std::vector<const Class*> shadows(entries.size());
  for (size_t i = 0; i < entries.size(); i++) {
    const String& cname =
        String::Handle(zone, Symbols::New(thread, entries[i].name.c_str()));
    Class& k = Class::ZoneHandle(
        zone, Class::New(library, cname, script, TokenPosition::kNoSource));
    library.AddClass(k);
    klasses[i] = &k;
    const String& sname = String::Handle(
        zone, Symbols::New(thread, (entries[i].name + " class").c_str()));
    Class& s = Class::ZoneHandle(
        zone, Class::New(library, sname, script, TokenPosition::kNoSource));
    library.AddClass(s);
    shadows[i] = &s;
  }

  // --- sub-pass B: super types, fields, functions (with markers) ------------
  for (size_t i = 0; i < entries.size(); i++) {
    const Class& k = *klasses[i];
    const ClassAgg& e = entries[i];

    const Type& super_type = Type::Handle(
        zone, ResolveSuper(thread, library, e.has_super ? e.super
                                                        : std::string()));
    k.set_super_type(super_type);

    // Instance variables -> Fields (all typed `dynamic`; not laid out until a
    // future FinalizeClass, which Sprint 2 never triggers).
    const Array& fields = Array::Handle(zone, Array::New(e.ivars.size(),
                                                         Heap::kOld));
    for (size_t j = 0; j < e.ivars.size(); j++) {
      const String& fname =
          String::Handle(zone, Symbols::New(thread, e.ivars[j].c_str()));
      const Field& f = Field::Handle(
          zone, Field::New(fname, /*is_static=*/false, /*is_final=*/false,
                           /*is_const=*/false, /*is_reflectable=*/true, k,
                           Object::dynamic_type(), TokenPosition::kNoSource));
      fields.SetAt(j, f);
    }
    k.SetFields(fields);

    // Methods -> Functions (MakeStFunction: dynamic params, AST-node marker,
    // non-inlinable). INSTANCE methods live on Foo; CLASS-SIDE methods live on
    // the metaclass shadow `Foo class` — so a selector can exist on both sides
    // without colliding (the Smalltalk metalevel split).
    std::vector<MethodNode*> inst;
    std::vector<MethodNode*> stat;
    for (size_t j = 0; j < e.methods.size(); j++) {
      (e.methods[j].is_static ? stat : inst).push_back(e.methods[j].node);
    }
    const Array& funcs =
        Array::Handle(zone, Array::New(inst.size(), Heap::kOld));
    Function& fh = Function::Handle(zone);
    for (size_t j = 0; j < inst.size(); j++) {
      fh = MakeStFunction(thread, k, inst[j], /*is_static=*/false);
      funcs.SetAt(j, fh);
    }
    k.SetFunctions(funcs);

    const Class& shadow = *shadows[i];
    const String& super_shadow_name = String::Handle(
        zone, Symbols::New(thread, (e.has_super ? e.super + " class"
                                                : std::string()).c_str()));
    Class& super_shadow = Class::Handle(
        zone, e.has_super ? library.LookupLocalClass(super_shadow_name)
                          : Class::null());
    if (super_shadow.IsNull() && e.has_super) {
      super_shadow =
          FindStClassByName(thread, (e.super + " class").c_str());
    }
    shadow.set_super_type(Type::Handle(
        zone, (!super_shadow.IsNull() && super_shadow.NumTypeParameters() == 0)
                  ? Type::New(super_shadow, Object::null_type_arguments(),
                              TokenPosition::kNoSource)
                  : Type::ObjectType()));
    const Array& sfuncs =
        Array::Handle(zone, Array::New(stat.size(), Heap::kOld));
    for (size_t j = 0; j < stat.size(); j++) {
      fh = MakeStFunction(thread, shadow, stat[j], /*is_static=*/true);
      sfuncs.SetAt(j, fh);
    }
    shadow.SetFunctions(sfuncs);
    // Class variables (Sprint 11b): static Fields on the shadow, initialized
    // to nil NOW so a direct LoadStaticField never sees the lazy-init
    // sentinel. Visible from both metalevels via the builder's resolver.
    const Array& sfields = Array::Handle(
        zone, Array::New(static_cast<intptr_t>(e.class_vars.size()),
                         Heap::kOld));
    for (size_t j = 0; j < e.class_vars.size(); j++) {
      const String& fname =
          String::Handle(zone, Symbols::New(thread, e.class_vars[j].c_str()));
      const Field& f = Field::Handle(
          zone, Field::New(fname, /*is_static=*/true, /*is_final=*/false,
                           /*is_const=*/false, /*is_reflectable=*/true, shadow,
                           Object::dynamic_type(), TokenPosition::kNoSource));
      f.SetStaticValue(Object::null_instance(), /*save_initial=*/true);
      sfields.SetAt(j, f);
    }
    shadow.SetFields(sfields);

    // A concrete class must carry >=1 function or FinalizeClass asserts
    // (class_finalizer.cc:2667, "at least a constructor"). Method-less classes
    // (and shadows, which are never instantiated) are marked abstract.
    if (funcs.Length() == 0) k.set_is_abstract();
    shadow.set_is_abstract();

    pending.Add(k, Heap::kOld);
    pending.Add(shadow, Heap::kOld);
  }

  // --- finalize (resolve supers + declaration types; members on demand) -----
  // from_kernel=false: resolve the super chain and finalize declaration types
  // for every class, but DEFER member finalization. Eager member finalization
  // (from_kernel=true) trips a DEBUG assert (class_finalizer.cc:2667) on a
  // method-less ST base class — a concrete class must have >=1 function — so a
  // whole-corpus load would crash. Registration therefore stays lazy (all 86
  // MACVM world/*.mst load clean); the invoke path (st_natives.cc
  // ST_invokeStatic) member-finalizes just the ONE class it calls, via
  // ClassFinalizer::FinalizeClass, which bypasses the Dart Parser::ParseClass
  // that EnsureIsFinalized would otherwise crash on (no TokenStream on an ST
  // class).
  library.SetLoaded();
  if (!ClassFinalizer::ProcessPendingClasses(/*from_kernel=*/false)) {
    const Error& err = Error::Handle(zone, thread->sticky_error());
    *error = std::string("ERR: finalization failed: ") +
             (err.IsNull() ? "unknown" : err.ToErrorCString());
    thread->clear_sticky_error();
    // Drop this failed (still-unfinalized) batch so it is not re-finalized —
    // and re-reported — on the next load. ProcessPendingClasses only clears the
    // list on its success path, so a failed load would otherwise poison every
    // subsequent stLoad in the same isolate.
    isolate->object_store()->set_pending_classes(
        GrowableObjectArray::Handle(zone, GrowableObjectArray::New()));
    return false;
  }

  // --- summary: query the classes we just registered ------------------------
  std::string out;
  char line[512];
  snprintf(line, sizeof(line), "loaded %s (%zu classes)\n", url.ToCString(),
           entries.size());
  out += line;
  for (size_t i = 0; i < entries.size(); i++) {
    const Class& k = *klasses[i];
    const Array& funcs = Array::Handle(zone, k.functions());
    const Array& fields = Array::Handle(zone, k.fields());
    snprintf(line, sizeof(line), "  %s : %ld methods, %ld fields\n",
             entries[i].name.c_str(), static_cast<long>(funcs.Length()),
             static_cast<long>(fields.Length()));
    out += line;
  }
  *summary = out;
  return true;
}

}  // namespace st
