// DeltaBlue — the classic incremental constraint-solver benchmark, ported
// faithfully from MACVM's Smalltalk (world/41a_bench_workloads.mst). Same
// benchmark, run on both VMs, for a direct comparison.
// (A library the dashboard imports; no demo-title header.)
//
// Ported LITERALLY from the Smalltalk, preserving two details that differ
// from the well-known historical JS/Java/Dart-SDK DeltaBlue lineage (found
// by reading MACVM's actual source rather than assuming equivalence):
//   - worklists are FIFO queues here (Smalltalk's removeFirst), not the
//     LIFO stacks (removeLast) the JS-derived ports use;
//   - incrementalRemove re-adds unsatisfied constraints in plain list
//     order, not sorted strongest-strength-first.
// Getting either wrong would still "work" (the propagation still converges)
// but would not be MACVM's algorithm — and for a timing comparison the
// workload must be identical, not just similar. dests are also kept 1-based
// in the projection-test formulas (matching the Smalltalk loop variable
// exactly, just offset into a 0-based Dart List) so checkResult is the
// exact number MACVM's own dashboard checks: 224874.
library deltablue;

class Strength {
  final String symbolicValue;
  final int arithmeticValue;
  const Strength(this.symbolicValue, this.arithmeticValue);
  bool sameAs(Strength s) => arithmeticValue == s.arithmeticValue;
  bool stronger(Strength s) => arithmeticValue < s.arithmeticValue;
  bool weaker(Strength s) => arithmeticValue > s.arithmeticValue;
  Strength weakest(Strength s) => weaker(s) ? this : s;
}
const Strength kRequired = const Strength('required', 0);
const Strength kStrongPreferred = const Strength('strongPreferred', 1);
const Strength kPreferred = const Strength('preferred', 2);
const Strength kStrongDefault = const Strength('strongDefault', 3);
const Strength kNormal = const Strength('normal', 4);
const Strength kWeakDefault = const Strength('weakDefault', 5);
const Strength kWeakest = const Strength('weakest', 6);

class Variable {
  int value;
  List<AbstractConstraint> constraints = <AbstractConstraint>[];
  AbstractConstraint determinedBy;
  Strength walkStrength = kWeakest;
  bool stay = true;
  int mark = 0;
  Variable([this.value = 0]);

  void addConstraint(AbstractConstraint c) { constraints.add(c); }
  void removeConstraint(AbstractConstraint c) {
    var keep = <AbstractConstraint>[];
    for (var x in constraints) { if (x != c) keep.add(x); }
    constraints = keep;
    if (determinedBy == c) determinedBy = null;
  }
}

class Plan {
  final List<AbstractConstraint> list = <AbstractConstraint>[];
  void addLast(AbstractConstraint c) { list.add(c); }
  void execute() { for (var c in list) c.execute(); }
}

/// The solver: adds/removes constraints one at a time, maintaining the
/// walkabout-strength dataflow graph, and extracts executable Plans.
class Planner {
  static Planner current;
  static void reset() { current = new Planner(); }

  int currentMark = 0;
  int newMark() { currentMark++; return currentMark; }

  void incrementalAdd(AbstractConstraint c) {
    var mark = newMark();
    var overridden = c.satisfy(mark);
    while (overridden != null) { overridden = overridden.satisfy(mark); }
  }

  void incrementalRemove(AbstractConstraint c) {
    var out = c.output();
    c.markUnsatisfied();
    c.removeFromGraph();
    var unsatisfied = removePropagateFrom(out);
    for (var u in unsatisfied) incrementalAdd(u);   // plain list order (see file header)
  }

  bool addPropagate(AbstractConstraint c, int mark) {
    var todo = <AbstractConstraint>[c];
    while (todo.isNotEmpty) {
      var d = todo.removeAt(0);                      // FIFO (see file header)
      if (d.output().mark == mark) { incrementalRemove(c); return false; }
      d.recalculate();
      addConstraintsConsuming(d.output(), todo);
    }
    return true;
  }

  List<AbstractConstraint> removePropagateFrom(Variable out) {
    out.determinedBy = null;
    out.walkStrength = kWeakest;
    out.stay = true;
    var unsatisfied = <AbstractConstraint>[];
    var todo = <Variable>[out];
    while (todo.isNotEmpty) {
      var v = todo.removeAt(0);                       // FIFO
      for (var c in v.constraints) { if (!c.isSatisfied()) unsatisfied.add(c); }
      constraintsConsumingDo(v, (c) { c.recalculate(); todo.add(c.output()); });
    }
    return unsatisfied;
  }

  Plan extractPlanFromConstraints(List<AbstractConstraint> constraints) {
    var sources = <AbstractConstraint>[];
    for (var c in constraints) { if (c.isInput && c.isSatisfied()) sources.add(c); }
    return makePlan(sources);
  }

  Plan makePlan(List<AbstractConstraint> sources) {
    var mark = newMark();
    var plan = new Plan();
    var todo = new List<AbstractConstraint>.from(sources);
    while (todo.isNotEmpty) {
      var c = todo.removeAt(0);                       // FIFO
      if (c.output().mark != mark && c.inputsKnown(mark)) {
        plan.addLast(c);
        c.output().mark = mark;
        addConstraintsConsuming(c.output(), todo);
      }
    }
    return plan;
  }

  void constraintsConsumingDo(Variable v, void body(AbstractConstraint c)) {
    var determining = v.determinedBy;
    for (var c in v.constraints) {
      if (c != determining && c.isSatisfied()) body(c);
    }
  }
  void addConstraintsConsuming(Variable v, List<AbstractConstraint> coll) {
    constraintsConsumingDo(v, (c) { coll.add(c); });
  }
}

abstract class AbstractConstraint {
  Strength strength;
  bool get isInput => false;

  bool isSatisfied();
  void markUnsatisfied();
  void addToGraph();
  void removeFromGraph();
  void chooseMethod(int mark);
  List<Variable> inputs();
  Variable output();
  void execute();
  void recalculate();

  void addConstraint() { addToGraph(); Planner.current.incrementalAdd(this); }
  void destroyConstraint() {
    if (isSatisfied()) Planner.current.incrementalRemove(this);
    else removeFromGraph();
  }

  /// Answers the constraint this one overrode, or null.
  AbstractConstraint satisfy(int mark) {
    chooseMethod(mark);
    if (!isSatisfied()) {
      if (strength.sameAs(kRequired)) {
        throw new StateError('Could not satisfy a required constraint');
      }
      return null;
    }
    markInputs(mark);
    var out = output();
    var overridden = out.determinedBy;
    if (overridden != null) overridden.markUnsatisfied();
    out.determinedBy = this;
    if (!Planner.current.addPropagate(this, mark)) {
      throw new StateError('Cycle encountered');
    }
    out.mark = mark;
    return overridden;
  }

  void markInputs(int mark) { for (var v in inputs()) v.mark = mark; }
  bool inputsKnown(int mark) {
    for (var v in inputs()) {
      if (!(v.mark == mark || v.stay || v.determinedBy == null)) return false;
    }
    return true;
  }
}

class UnaryConstraint extends AbstractConstraint {
  Variable myOutput;
  bool satisfied = false;
  UnaryConstraint(Variable v, Strength str) {
    strength = str;
    myOutput = v;
    satisfied = false;
    addConstraint();
  }
  bool isSatisfied() => satisfied;
  Variable output() => myOutput;
  void addToGraph() { myOutput.addConstraint(this); satisfied = false; }
  void removeFromGraph() {
    if (myOutput != null) myOutput.removeConstraint(this);
    satisfied = false;
  }
  void chooseMethod(int mark) {
    satisfied = myOutput.mark != mark && strength.stronger(myOutput.walkStrength);
  }
  List<Variable> inputs() => const <Variable>[];
  void markUnsatisfied() { satisfied = false; }
  void recalculate() {
    myOutput.walkStrength = strength;
    myOutput.stay = !isInput;
    if (myOutput.stay) execute();
  }
}
class StayConstraint extends UnaryConstraint {
  StayConstraint(Variable v, Strength str) : super(v, str);
  void execute() {}
}
class EditConstraint extends UnaryConstraint {
  EditConstraint(Variable v, Strength str) : super(v, str);
  bool get isInput => true;
  void execute() {}
}

class BinaryConstraint extends AbstractConstraint {
  Variable v1, v2;
  String direction;          // 'forward' | 'backward' | null(unsatisfied)

  BinaryConstraint(Variable a, Variable b, Strength str) {
    strength = str; v1 = a; v2 = b; direction = null; addConstraint();
  }
  bool isSatisfied() => direction != null;
  void addToGraph() { v1.addConstraint(this); v2.addConstraint(this); direction = null; }
  void removeFromGraph() {
    if (v1 != null) v1.removeConstraint(this);
    if (v2 != null) v2.removeConstraint(this);
    direction = null;
  }
  void chooseMethod(int mark) {
    if (v1.mark == mark) {
      direction = (v2.mark != mark && strength.stronger(v2.walkStrength)) ? 'forward' : null;
      return;
    }
    if (v2.mark == mark) {
      direction = (v1.mark != mark && strength.stronger(v1.walkStrength)) ? 'backward' : null;
      return;
    }
    if (v1.walkStrength.weaker(v2.walkStrength)) {
      direction = strength.stronger(v1.walkStrength) ? 'backward' : null;
    } else {
      direction = strength.stronger(v2.walkStrength) ? 'forward' : null;
    }
  }
  List<Variable> inputs() => <Variable>[direction == 'forward' ? v1 : v2];
  void markUnsatisfied() { direction = null; }
  Variable output() => direction == 'forward' ? v2 : v1;
  void recalculate() {
    Variable inn, out;
    if (direction == 'forward') { inn = v1; out = v2; } else { inn = v2; out = v1; }
    out.walkStrength = strength.weakest(inn.walkStrength);
    out.stay = inn.stay;
    if (out.stay) execute();
  }
}
class EqualityConstraint extends BinaryConstraint {
  EqualityConstraint(Variable a, Variable b, Strength str) : super(a, b, str);
  void execute() {
    if (direction == 'forward') v2.value = v1.value; else v1.value = v2.value;
  }
}
class ScaleConstraint extends BinaryConstraint {
  Variable scale, offset;
  ScaleConstraint(Variable src, this.scale, this.offset, Variable dst, Strength str)
      : super(src, dst, str);
  void addToGraph() { super.addToGraph(); scale.addConstraint(this); offset.addConstraint(this); }
  void removeFromGraph() {
    super.removeFromGraph();
    if (scale != null) scale.removeConstraint(this);
    if (offset != null) offset.removeConstraint(this);
  }
  List<Variable> inputs() {
    var l = <Variable>[direction == 'forward' ? v1 : v2];
    l.add(scale);
    l.add(offset);
    return l;
  }
  void execute() {
    if (direction == 'forward') {
      v2.value = v1.value * scale.value + offset.value;
    } else {
      v1.value = (v2.value - offset.value) ~/ scale.value;
    }
  }
  void recalculate() {
    Variable inn, out;
    if (direction == 'forward') { inn = v1; out = v2; } else { inn = v2; out = v1; }
    out.walkStrength = strength.weakest(inn.walkStrength);
    out.stay = inn.stay && scale.stay && offset.stay;
    if (out.stay) execute();
  }
}

/// The standard chainTest:/projectionTest: workloads (n=100 both), the
/// canonical asserts ported as-is. chainTest answers the chain's final
/// value (99); projectionTest answers the last dst plus the sum of the
/// checked dests — 224874 total is what checkResult verifies.
int chainTest(int n) {
  Planner.reset();
  Variable prev, v, first, last;
  for (var i = 1; i <= n + 1; i++) {
    v = new Variable();
    if (prev != null) new EqualityConstraint(prev, v, kRequired);
    if (i == 1) first = v;
    if (i == n + 1) last = v;
    prev = v;
  }
  new StayConstraint(last, kStrongDefault);
  var editC = new EditConstraint(first, kPreferred);
  var plan = Planner.current.extractPlanFromConstraints(<AbstractConstraint>[editC]);
  for (var i = 0; i <= 99; i++) {
    first.value = i;
    plan.execute();
    if (last.value != i) throw new StateError('Chain test failed');
  }
  return last.value;
}

void _change(Variable v, int newValue) {
  var editC = new EditConstraint(v, kPreferred);
  var plan = Planner.current.extractPlanFromConstraints(<AbstractConstraint>[editC]);
  for (var i = 0; i < 10; i++) { v.value = newValue; plan.execute(); }
  editC.destroyConstraint();
}

int projectionTest(int n) {
  Planner.reset();
  var dests = <Variable>[];               // 0-based storage; formulas use 1-based i, matching
  var scale = new Variable(10);           // the Smalltalk source's own loop variable exactly
  var offset = new Variable(1000);
  Variable src, dst;
  for (var i = 1; i <= n; i++) {
    src = new Variable(i);
    dst = new Variable(i);
    dests.add(dst);
    new StayConstraint(src, kNormal);
    new ScaleConstraint(src, scale, offset, dst, kRequired);
  }
  _change(src, 17);
  if (dst.value != 1170) throw new StateError('Projection test 1 failed');
  _change(dst, 1050);
  if (src.value != 5) throw new StateError('Projection test 2 failed');
  _change(scale, 5);
  for (var i = 1; i <= n - 1; i++) {
    if (dests[i - 1].value != i * 5 + 1000) throw new StateError('Projection test 3 failed');
  }
  _change(offset, 2000);
  var total = 0;
  for (var i = 1; i <= n - 1; i++) {
    if (dests[i - 1].value != i * 5 + 2000) throw new StateError('Projection test 4 failed');
    total += dests[i - 1].value;
  }
  return total + dst.value;
}

/// One full run; the canonical checkResult is 224874.
int deltaBlueRunOne() => chainTest(100) + projectionTest(100);
bool deltaBlueCheck(int r) => r == 224874;
