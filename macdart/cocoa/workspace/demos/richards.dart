// Richards — the classic OS task-scheduler benchmark, ported faithfully from
// MACVM's Smalltalk (world/41a_bench_workloads.mst, itself the standard
// Richards workload traceable to Martin Richards' original BCPL/Smalltalk
// benchmark). Same benchmark, run on both VMs, for a direct comparison.
// (A library the dashboard imports; no demo-title header.)
//
// Task identities are the classic 1-6 constants (idler/worker/handlerA/
// handlerB/deviceA/deviceB) used directly as 1-based array indices — kept
// 1-based here too (taskTable sized 7, index 0 unused) rather than
// renumbered to 0-based, so the port cannot introduce an off-by-one that a
// renumbering would risk. checkResult is index-convention-independent (it
// encodes two scalar counters, not a per-element check), so 2324609297 is
// the same, universally-quoted number across every language's Richards port.
library richards;

const int kIdlerId = 1, kWorkerId = 2, kHandlerA = 3, kHandlerB = 4;
const int kDeviceA = 5, kDeviceB = 6;
const int kDevicePacketKind = 1, kWorkPacketKind = 2;

/// Append [packet] to the linked list headed by [queueHead]; answer the
/// (possibly unchanged) head.
Packet appendPacket(Packet packet, Packet queueHead) {
  packet.link = null;
  if (queueHead == null) return packet;
  var mouse = queueHead;
  var link = mouse.link;
  while (link != null) { mouse = link; link = mouse.link; }
  mouse.link = packet;
  return queueHead;
}

class Packet {
  Packet link;
  int identity;
  final int kind;
  int datum = 1;
  final List<int> data = new List<int>(5);   // 1-based, index 0 unused
  Packet(this.link, this.identity, this.kind) {
    for (var i = 1; i <= 4; i++) data[i] = 0;
  }
}

class TaskState {
  bool packetPending = false, taskWaiting = false, taskHolding = false;

  void setRunning() { packetPending = false; taskWaiting = false; taskHolding = false; }
  void setWaiting() { packetPending = false; taskHolding = false; taskWaiting = true; }
  void setWaitingWithPacket() { taskHolding = false; taskWaiting = true; packetPending = true; }
  void setPacketPending() { packetPending = true; taskWaiting = false; taskHolding = false; }

  bool get isRunning => !packetPending && !taskWaiting && !taskHolding;
  bool get isTaskHoldingOrWaiting => taskHolding || (!packetPending && taskWaiting);
  bool get isWaitingWithPacket => packetPending && taskWaiting && !taskHolding;

  static TaskState running() { var s = new TaskState(); s.setRunning(); return s; }
  static TaskState waiting() { var s = new TaskState(); s.setWaiting(); return s; }
  static TaskState waitingWithPacket() {
    var s = new TaskState(); s.setWaitingWithPacket(); return s;
  }
}

class DeviceTaskDataRecord { Packet pending; }
class HandlerTaskDataRecord {
  Packet workIn, deviceIn;
  void workInAdd(RichardsBenchmark s, Packet p) { workIn = appendPacket(p, workIn); }
  void deviceInAdd(RichardsBenchmark s, Packet p) { deviceIn = appendPacket(p, deviceIn); }
}
class IdleTaskDataRecord { int control = 1; int count = 10000; }
class WorkerTaskDataRecord { int destination = kHandlerA; int count = 0; }

/// One schedulable task: a linked-list node with identity, priority, an
/// input queue and scheduling state; [processWork] is the per-kind override.
class TaskControlBlock extends TaskState {
  TaskControlBlock link;
  final int identity, priority;
  Packet input;
  dynamic handle;                 // the *TaskDataRecord
  RichardsBenchmark scheduler;
  final int kind;                 // 0 idle, 1 worker, 2 handler, 3 device

  TaskControlBlock(this.link, this.identity, this.priority, Packet work,
                   TaskState state, this.scheduler, this.handle, this.kind) {
    input = work;
    packetPending = state.packetPending;
    taskWaiting = state.taskWaiting;
    taskHolding = state.taskHolding;
  }

  TaskControlBlock addInputCheckPriority(Packet packet, TaskControlBlock oldTask) {
    if (input == null) {
      input = packet;
      packetPending = true;
      if (priority > oldTask.priority) return this;
    } else {
      input = appendPacket(packet, input);
    }
    return oldTask;
  }

  TaskControlBlock runTask() {
    Packet message;
    if (isWaitingWithPacket) {
      message = input;
      input = message.link;
      if (input == null) setRunning(); else setPacketPending();
    } else {
      message = null;
    }
    return processWork(message);
  }

  TaskControlBlock processWork(Packet work) {
    switch (kind) {
      case 0: {                                       // IdleTask
        var data = handle as IdleTaskDataRecord;
        data.count--;
        if (data.count == 0) return scheduler.holdSelf();
        var control = data.control;
        if ((control & 1) == 0) {
          data.control = control >> 1;
          return scheduler.release(kDeviceA);
        } else {
          data.control = (control >> 1) ^ 53256;
          return scheduler.release(kDeviceB);
        }
      }
      case 1: {                                       // WorkerTask
        var data = handle as WorkerTaskDataRecord;
        if (work == null) return scheduler.markWaiting();
        data.destination = (data.destination == kHandlerA) ? kHandlerB : kHandlerA;
        work.identity = data.destination;
        work.datum = 1;
        for (var i = 1; i <= 4; i++) {
          data.count++;
          if (data.count > 26) data.count = 1;
          work.data[i] = 65 + data.count - 1;
        }
        return scheduler.queuePacket(work);
      }
      case 2: {                                       // HandlerTask
        var data = handle as HandlerTaskDataRecord;
        if (work != null) {
          if (work.kind == kWorkPacketKind) data.workInAdd(scheduler, work);
          else data.deviceInAdd(scheduler, work);
        }
        var workPacket = data.workIn;
        if (workPacket == null) return scheduler.markWaiting();
        var count = workPacket.datum;
        if (count > 4) {
          data.workIn = workPacket.link;
          return scheduler.queuePacket(workPacket);
        }
        var devicePacket = data.deviceIn;
        if (devicePacket == null) return scheduler.markWaiting();
        data.deviceIn = devicePacket.link;
        devicePacket.datum = workPacket.data[count];
        workPacket.datum = count + 1;
        return scheduler.queuePacket(devicePacket);
      }
      default: {                                      // DeviceTask
        var data = handle as DeviceTaskDataRecord;
        if (work == null) {
          var functionWork = data.pending;
          if (functionWork == null) return scheduler.markWaiting();
          data.pending = null;
          return scheduler.queuePacket(functionWork);
        } else {
          data.pending = work;
          return scheduler.holdSelf();
        }
      }
    }
  }
}

/// The scheduler: builds the canonical task set, runs it to completion, and
/// answers `queuePacketCount * 100000 + holdCount`.
class RichardsBenchmark {
  TaskControlBlock taskList, currentTask;
  int currentTaskIdentity = 0;
  final List<TaskControlBlock> taskTable = new List<TaskControlBlock>(7);   // 1-based
  int queuePacketCount = 0, holdCount = 0;

  void addTask(TaskControlBlock t, int identity) {
    taskList = t;
    taskTable[identity] = t;
  }
  void createIdler(int identity, int priority, Packet work, TaskState state) {
    addTask(new TaskControlBlock(taskList, identity, priority, work, state,
                                 this, new IdleTaskDataRecord(), 0), identity);
  }
  void createWorker(int identity, int priority, Packet work, TaskState state) {
    addTask(new TaskControlBlock(taskList, identity, priority, work, state,
                                 this, new WorkerTaskDataRecord(), 1), identity);
  }
  void createHandler(int identity, int priority, Packet work, TaskState state) {
    addTask(new TaskControlBlock(taskList, identity, priority, work, state,
                                 this, new HandlerTaskDataRecord(), 2), identity);
  }
  void createDevice(int identity, int priority, Packet work, TaskState state) {
    addTask(new TaskControlBlock(taskList, identity, priority, work, state,
                                 this, new DeviceTaskDataRecord(), 3), identity);
  }

  TaskControlBlock findTask(int identity) {
    var t = taskTable[identity];
    if (t == null) throw new StateError('findTask failed');
    return t;
  }
  TaskControlBlock holdSelf() {
    holdCount++;
    currentTask.taskHolding = true;
    return currentTask.link;
  }
  TaskControlBlock queuePacket(Packet packet) {
    var t = findTask(packet.identity);
    if (t == null) return null;
    queuePacketCount++;
    packet.link = null;
    packet.identity = currentTaskIdentity;
    return t.addInputCheckPriority(packet, currentTask);
  }
  TaskControlBlock release(int identity) {
    var t = findTask(identity);
    if (t == null) return null;
    t.taskHolding = false;
    if (t.priority > currentTask.priority) return t;
    return currentTask;
  }
  TaskControlBlock markWaiting() {
    currentTask.taskWaiting = true;
    return currentTask;
  }

  void schedule() {
    currentTask = taskList;
    while (currentTask != null) {
      if (currentTask.isTaskHoldingOrWaiting) {
        currentTask = currentTask.link;
      } else {
        currentTaskIdentity = currentTask.identity;
        currentTask = currentTask.runTask();
      }
    }
  }

  int start() {
    createIdler(kIdlerId, 0, null, TaskState.running());

    var workQ = new Packet(null, kWorkerId, kWorkPacketKind);
    workQ = new Packet(workQ, kWorkerId, kWorkPacketKind);
    createWorker(kWorkerId, 1000, workQ, TaskState.waitingWithPacket());

    workQ = new Packet(null, kDeviceA, kDevicePacketKind);
    workQ = new Packet(workQ, kDeviceA, kDevicePacketKind);
    workQ = new Packet(workQ, kDeviceA, kDevicePacketKind);
    createHandler(kHandlerA, 2000, workQ, TaskState.waitingWithPacket());

    workQ = new Packet(null, kDeviceB, kDevicePacketKind);
    workQ = new Packet(workQ, kDeviceB, kDevicePacketKind);
    workQ = new Packet(workQ, kDeviceB, kDevicePacketKind);
    createHandler(kHandlerB, 3000, workQ, TaskState.waitingWithPacket());

    createDevice(kDeviceA, 4000, null, TaskState.waiting());
    createDevice(kDeviceB, 5000, null, TaskState.waiting());

    schedule();
    return queuePacketCount * 100000 + holdCount;
  }
}

/// One fresh scheduler run; the canonical checkResult is 2324609297
/// (queuePacketCount=23246, holdCount=9297) — the same number every
/// language's port of this benchmark reports.
int richardsRunOne() => new RichardsBenchmark().start();
bool richardsCheck(int r) => r == 2324609297;
