Object subclass: #CogBench
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

!CogBench class methodsFor: 'bench'!
benchArith
	| s |
	s := 0.
	1 to: 1500000 do: [:i | s := s + (i * i) - (i * 3) ].
	^s!
fib: n
	n < 2 ifTrue: [ ^n ].
	^(self fib: n - 1) + (self fib: n - 2)!
benchFib
	^self fib: 32!
sieveOnce
	| flags count size |
	size := 8190.
	flags := Array new: size.
	1 to: size do: [:x | flags at: x put: true ].
	count := 0.
	1 to: size do: [:i |
		(flags at: i) ifTrue: [
			| prime k |
			prime := i + i + 1.
			k := i + prime.
			[ k <= size ] whileTrue: [ flags at: k put: false. k := k + prime ].
			count := count + 1 ] ].
	^count!
benchSieve
	| count |
	count := 0.
	4 timesRepeat: [ count := self sieveOnce ].
	^count!
benchDict
	| d sum |
	d := Dictionary new.
	1 to: 8000 do: [:i | d at: i put: i * i ].
	sum := 0.
	1 to: 8000 do: [:i | sum := sum + (d at: i) ].
	^sum!
benchAlloc
	| last |
	last := nil.
	1 to: 200000 do: [:i | last := Association key: i value: last ].
	^last key!
median: coll
	| s |
	s := coll asSortedCollection asArray.
	^s at: (s size + 1) // 2!
check: name got: got want: want
	got = want ifFalse: [
		Stdio stdout nextPutAll: name; nextPutAll: ' WRONG RESULT '; print: got; lf; flush.
		Smalltalk exitFailure ]!
run: name block: aBlock check: want
	"Microsecond clock, reported in ms: Windows quantizes the millisecond
	 clock to the 15.6 ms timer tick, which rendered every sub-33 ms Cog
	 number as 0, 15/16, or 31/33 (2026-07-22 pinned sessions)."
	| times cold t0 r |
	t0 := Time microsecondClockValue.
	10 timesRepeat: [ r := aBlock value ].
	self check: name got: r want: want.
	cold := Time microsecondClockValue - t0.
	times := OrderedCollection new.
	6 timesRepeat: [
		t0 := Time microsecondClockValue.
		10 timesRepeat: [ r := aBlock value ].
		times add: Time microsecondClockValue - t0 ].
	self check: name got: r want: want.
	Stdio stdout nextPutAll: name; nextPutAll: ' cold_us='; print: cold;
		nextPutAll: ' warm_us='; print: (self median: times); lf; flush!
runAll
	self run: 'arith    ' block: [ self benchArith ] check: 1124997749998000000.
	self run: 'fib      ' block: [ self benchFib ] check: 2178309.
	self run: 'sieve    ' block: [ self benchSieve ] check: 1899.
	self run: 'dict     ' block: [ self benchDict ] check: 170698668000.
	self run: 'alloc    ' block: [ self benchAlloc ] check: 200000.! !




Object subclass: #RBObject
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #Packet
	instanceVariableNames: 'link identity kind datum data'
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #TaskState
	instanceVariableNames: 'packetPendingIV taskWaiting taskHolding'
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #DeviceTaskDataRecord
	instanceVariableNames: 'pending'
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #HandlerTaskDataRecord
	instanceVariableNames: 'workIn deviceIn'
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #IdleTaskDataRecord
	instanceVariableNames: 'control count'
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #WorkerTaskDataRecord
	instanceVariableNames: 'destination count'
	classVariableNames: ''
	package: 'CogBench'!

TaskState subclass: #TaskControlBlock
	instanceVariableNames: 'link identity priority input handle scheduler'
	classVariableNames: ''
	package: 'CogBench'!

TaskControlBlock subclass: #IdleTask
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

TaskControlBlock subclass: #WorkerTask
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

TaskControlBlock subclass: #HandlerTask
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

TaskControlBlock subclass: #DeviceTask
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

RBObject subclass: #RichardsBenchmark
	instanceVariableNames: 'taskList currentTask currentTaskIdentity taskTable queuePacketCount holdCount'
	classVariableNames: ''
	package: 'CogBench'!

Object subclass: #Strength
	instanceVariableNames: 'symbolicValue arithmeticValue'
	classVariableNames: 'Table Required StrongPreferred Preferred StrongDefault Normal WeakDefault Weakest'
	package: 'CogBench'!

Object subclass: #DBVariable
	instanceVariableNames: 'value constraints determinedBy walkStrength stay mark'
	classVariableNames: ''
	package: 'CogBench'!

OrderedCollection subclass: #Plan
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

Object subclass: #Planner
	instanceVariableNames: 'currentMark'
	classVariableNames: 'Current'
	package: 'CogBench'!

Object subclass: #AbstractConstraint
	instanceVariableNames: 'strength'
	classVariableNames: ''
	package: 'CogBench'!

AbstractConstraint subclass: #UnaryConstraint
	instanceVariableNames: 'output satisfied'
	classVariableNames: ''
	package: 'CogBench'!

UnaryConstraint subclass: #StayConstraint
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

UnaryConstraint subclass: #EditConstraint
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

AbstractConstraint subclass: #BinaryConstraint
	instanceVariableNames: 'v1 v2 direction'
	classVariableNames: ''
	package: 'CogBench'!

BinaryConstraint subclass: #EqualityConstraint
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

BinaryConstraint subclass: #ScaleConstraint
	instanceVariableNames: 'scale offset'
	classVariableNames: ''
	package: 'CogBench'!

Object subclass: #DeltaBlue
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'CogBench'!

!RBObject methodsFor: 'bench'!
idlerId
 ^1 !
workerId
 ^2 !
handlerA
 ^3 !
handlerB
 ^4 !
deviceA
 ^5 !
deviceB
 ^6 !
devicePacketKind
 ^1 !
workPacketKind
 ^2 !
append: packet head: queueHead
        | mouse link |
        packet link: nil.
        queueHead == nil ifTrue: [ ^packet ].
        mouse := queueHead.
        link := mouse link.
        [ link == nil ] whileFalse: [ mouse := link. link := mouse link ].
        mouse link: packet.
        ^queueHead
    !
 !

!Packet methodsFor: 'bench'!
initLink: aLink identity: anIdentity kind: aKind
        link := aLink.
        identity := anIdentity.
        kind := aKind.
        datum := 1.
        data := Array new: 4.
        1 to: 4 do: [:i | data at: i put: 0 ].
        ^self
    !
link
 ^link !
link: x
 link := x !
identity
 ^identity !
identity: x
 identity := x !
kind
 ^kind !
datum
 ^datum !
datum: x
 datum := x !
data
 ^data !
 !

!Packet class methodsFor: 'bench'!
link: aLink identity: anIdentity kind: aKind
        ^self new initLink: aLink identity: anIdentity kind: aKind
    !
 !

!TaskState methodsFor: 'bench'!
isPacketPending
 ^packetPendingIV !
isTaskWaiting
 ^taskWaiting !
isTaskHolding
 ^taskHolding !
packetPending: aBool
 packetPendingIV := aBool !
taskWaiting: aBool
 taskWaiting := aBool !
taskHolding: aBool
 taskHolding := aBool !
packetPending
        packetPendingIV := true.
        taskWaiting := false.
        taskHolding := false.
        ^self
    !
running
        packetPendingIV := false.
        taskWaiting := false.
        taskHolding := false.
        ^self
    !
waiting
        packetPendingIV := false.
        taskHolding := false.
        taskWaiting := true.
        ^self
    !
waitingWithPacket
        taskHolding := false.
        taskWaiting := true.
        packetPendingIV := true.
        ^self
    !
isRunning
        ^packetPendingIV not and: [ taskWaiting not and: [ taskHolding not ] ]
    !
isTaskHoldingOrWaiting
        ^taskHolding or: [ packetPendingIV not and: [ taskWaiting ] ]
    !
isWaiting
        ^packetPendingIV not and: [ taskWaiting and: [ taskHolding not ] ]
    !
isWaitingWithPacket
        ^packetPendingIV and: [ taskWaiting and: [ taskHolding not ] ]
    !
 !

!TaskState class methodsFor: 'bench'!
running
 ^self new running !
waiting
 ^self new waiting !
waitingWithPacket
 ^self new waitingWithPacket !
 !

!DeviceTaskDataRecord methodsFor: 'bench'!
init
 pending := nil. ^self !
pending
 ^pending !
pending: aPacket
 pending := aPacket !
 !

!DeviceTaskDataRecord class methodsFor: 'bench'!
create
 ^self new init !
 !

!HandlerTaskDataRecord methodsFor: 'bench'!
init
 workIn := nil. deviceIn := nil. ^self !
workIn
 ^workIn !
workIn: aPacket
 workIn := aPacket !
deviceIn
 ^deviceIn !
deviceIn: aPacket
 deviceIn := aPacket !
workInAdd: aPacket
 workIn := self append: aPacket head: workIn !
deviceInAdd: aPacket
 deviceIn := self append: aPacket head: deviceIn !
 !

!HandlerTaskDataRecord class methodsFor: 'bench'!
create
 ^self new init !
 !

!IdleTaskDataRecord methodsFor: 'bench'!
init
 control := 1. count := 10000. ^self !
control
 ^control !
control: v
 control := v !
count
 ^count !
count: v
 count := v !
 !

!IdleTaskDataRecord class methodsFor: 'bench'!
create
 ^self new init !
 !

!WorkerTaskDataRecord methodsFor: 'bench'!
init
 destination := self handlerA. count := 0. ^self !
destination
 ^destination !
destination: v
 destination := v !
count
 ^count !
count: v
 count := v !
 !

!WorkerTaskDataRecord class methodsFor: 'bench'!
create
 ^self new init !
 !

!TaskControlBlock methodsFor: 'bench'!
initLink: aLink identity: anIdentity priority: aPriority work: aWorkQueue state: aState scheduler: aScheduler data: aData
        link := aLink.
        identity := anIdentity.
        priority := aPriority.
        input := aWorkQueue.
        self packetPending: aState isPacketPending.
        self taskWaiting: aState isTaskWaiting.
        self taskHolding: aState isTaskHolding.
        scheduler := aScheduler.
        handle := aData.
        ^self
    !
link
 ^link !
identity
 ^identity !
priority
 ^priority !
addInput: packet checkPriority: oldTask
        input == nil
            ifTrue: [
                input := packet.
                self packetPending: true.
                priority > oldTask priority ifTrue: [ ^self ] ]
            ifFalse: [ input := self append: packet head: input ].
        ^oldTask
    !
runTask
        | message |
        self isWaitingWithPacket
            ifTrue: [
                message := input.
                input := message link.
                input == nil
                    ifTrue: [ self running ]
                    ifFalse: [ self packetPending ] ]
            ifFalse: [ message := nil ].
        ^self processWork: message
    !
processWork: work
        self error: 'TaskControlBlock subclasses must override processWork:'
    !
 !

!TaskControlBlock class methodsFor: 'bench'!
link: aLink identity: anIdentity priority: aPriority work: aWorkQueue state: aState scheduler: aScheduler data: aData
        ^self new initLink: aLink identity: anIdentity priority: aPriority
              work: aWorkQueue state: aState scheduler: aScheduler data: aData
    !
 !

!IdleTask methodsFor: 'bench'!
processWork: work
        | data control |
        data := handle.
        data count: data count - 1.
        data count = 0 ifTrue: [ ^scheduler holdSelf ].
        control := data control.
        (control bitAnd: 1) = 0
            ifTrue: [
                data control: control // 2.
                ^scheduler release: self deviceA ]
            ifFalse: [
                data control: ((control // 2) bitXor: 53256).
                ^scheduler release: self deviceB ]
    !
 !

!WorkerTask methodsFor: 'bench'!
processWork: work
        | data |
        data := handle.
        work == nil ifTrue: [ ^scheduler markWaiting ].
        data destination: (data destination = self handlerA
            ifTrue: [ self handlerB ]
            ifFalse: [ self handlerA ]).
        work identity: data destination.
        work datum: 1.
        1 to: 4 do: [:i |
            data count: data count + 1.
            data count > 26 ifTrue: [ data count: 1 ].
            work data at: i put: 65 + data count - 1 ].
        ^scheduler queuePacket: work
    !
 !

!HandlerTask methodsFor: 'bench'!
processWork: work
        | data workPacket count devicePacket |
        data := handle.
        work == nil ifFalse: [
            work kind = self workPacketKind
                ifTrue: [ data workInAdd: work ]
                ifFalse: [ data deviceInAdd: work ] ].
        workPacket := data workIn.
        workPacket == nil ifTrue: [ ^scheduler markWaiting ].
        count := workPacket datum.
        count > 4 ifTrue: [
            data workIn: workPacket link.
            ^scheduler queuePacket: workPacket ].
        devicePacket := data deviceIn.
        devicePacket == nil ifTrue: [ ^scheduler markWaiting ].
        data deviceIn: devicePacket link.
        devicePacket datum: (workPacket data at: count).
        workPacket datum: count + 1.
        ^scheduler queuePacket: devicePacket
    !
 !

!DeviceTask methodsFor: 'bench'!
processWork: work
        | data functionWork |
        data := handle.
        work == nil
            ifTrue: [
                functionWork := data pending.
                functionWork == nil ifTrue: [ ^scheduler markWaiting ].
                data pending: nil.
                ^scheduler queuePacket: functionWork ]
            ifFalse: [
                data pending: work.
                ^scheduler holdSelf ]
    !
 !

!RichardsBenchmark methodsFor: 'bench'!
init
        taskList := nil.
        currentTask := nil.
        currentTaskIdentity := 0.
        taskTable := Array new: 6.
        queuePacketCount := 0.
        holdCount := 0.
        ^self
    !
addTask: aTask identity: identity
        taskList := aTask.
        taskTable at: identity put: aTask.
    !
createIdler: identity priority: priority work: work state: state
        self addTask: (IdleTask link: taskList identity: identity
                priority: priority work: work state: state
                scheduler: self data: IdleTaskDataRecord create)
            identity: identity
    !
createWorker: identity priority: priority work: work state: state
        self addTask: (WorkerTask link: taskList identity: identity
                priority: priority work: work state: state
                scheduler: self data: WorkerTaskDataRecord create)
            identity: identity
    !
createHandler: identity priority: priority work: work state: state
        self addTask: (HandlerTask link: taskList identity: identity
                priority: priority work: work state: state
                scheduler: self data: HandlerTaskDataRecord create)
            identity: identity
    !
createDevice: identity priority: priority work: work state: state
        self addTask: (DeviceTask link: taskList identity: identity
                priority: priority work: work state: state
                scheduler: self data: DeviceTaskDataRecord create)
            identity: identity
    !
createPacket: link identity: identity kind: kind
        ^Packet link: link identity: identity kind: kind
    !
findTask: identity
        | t |
        t := taskTable at: identity.
        t == nil ifTrue: [ self error: 'findTask failed' ].
        ^t
    !
holdSelf
        holdCount := holdCount + 1.
        currentTask taskHolding: true.
        ^currentTask link
    !
queuePacket: packet
        | t |
        t := self findTask: packet identity.
        t == nil ifTrue: [ ^nil ].
        queuePacketCount := queuePacketCount + 1.
        packet link: nil.
        packet identity: currentTaskIdentity.
        ^t addInput: packet checkPriority: currentTask
    !
release: identity
        | t |
        t := self findTask: identity.
        t == nil ifTrue: [ ^nil ].
        t taskHolding: false.
        t priority > currentTask priority ifTrue: [ ^t ].
        ^currentTask
    !
markWaiting
        currentTask taskWaiting: true.
        ^currentTask
    !
schedule
        currentTask := taskList.
        [ currentTask == nil ] whileFalse: [
            currentTask isTaskHoldingOrWaiting
                ifTrue: [ currentTask := currentTask link ]
                ifFalse: [
                    currentTaskIdentity := currentTask identity.
                    currentTask := currentTask runTask ] ]
    !
start
        | workQ |
        self createIdler: self idlerId priority: 0
            work: nil state: TaskState running.

        workQ := self createPacket: nil identity: self workerId kind: self workPacketKind.
        workQ := self createPacket: workQ identity: self workerId kind: self workPacketKind.
        self createWorker: self workerId priority: 1000
            work: workQ state: TaskState waitingWithPacket.

        workQ := self createPacket: nil identity: self deviceA kind: self devicePacketKind.
        workQ := self createPacket: workQ identity: self deviceA kind: self devicePacketKind.
        workQ := self createPacket: workQ identity: self deviceA kind: self devicePacketKind.
        self createHandler: self handlerA priority: 2000
            work: workQ state: TaskState waitingWithPacket.

        workQ := self createPacket: nil identity: self deviceB kind: self devicePacketKind.
        workQ := self createPacket: workQ identity: self deviceB kind: self devicePacketKind.
        workQ := self createPacket: workQ identity: self deviceB kind: self devicePacketKind.
        self createHandler: self handlerB priority: 3000
            work: workQ state: TaskState waitingWithPacket.

        self createDevice: self deviceA priority: 4000
            work: nil state: TaskState waiting.
        self createDevice: self deviceB priority: 5000
            work: nil state: TaskState waiting.

        self schedule.

        ^(queuePacketCount * 100000) + holdCount
    !
 !

!RichardsBenchmark class methodsFor: 'bench'!
create
 ^self new init !
setUp
        "each runOne builds its own fresh scheduler — nothing shared to set up"
        ^self
    !
runOne
        ^self create start
    !
checkResult: r
        "queuePacketCount = 23246 and holdCount = 9297, encoded exactly"
        ^r = 2324609297
    !
 !

!Strength methodsFor: 'bench'!
initSymbol: aSymbol value: n
        symbolicValue := aSymbol.
        arithmeticValue := n.
    !
arithmeticValue
 ^arithmeticValue !
sameAs: aStrength
 ^arithmeticValue = aStrength arithmeticValue !
stronger: aStrength
 ^arithmeticValue < aStrength arithmeticValue !
weaker: aStrength
 ^arithmeticValue > aStrength arithmeticValue !
weakest: aStrength
        (self weaker: aStrength) ifTrue: [ ^self ].
        ^aStrength
    !
 !

!Strength class methodsFor: 'bench'!
addStrength: aSymbol value: n
        | s |
        s := self basicNew initSymbol: aSymbol value: n.
        Table at: aSymbol put: s.
        ^s
    !
initStrengths
        Table := Dictionary new.
        Required := self addStrength: #required value: 0.
        StrongPreferred := self addStrength: #strongPreferred value: 1.
        Preferred := self addStrength: #preferred value: 2.
        StrongDefault := self addStrength: #strongDefault value: 3.
        Normal := self addStrength: #normal value: 4.
        WeakDefault := self addStrength: #weakDefault value: 5.
        Weakest := self addStrength: #weakest value: 6.
    !
of: aSymbol
 ^Table at: aSymbol !
required
 ^Required !
strongPreferred
 ^StrongPreferred !
preferred
 ^Preferred !
strongDefault
 ^StrongDefault !
normal
 ^Normal !
weakDefault
 ^WeakDefault !
weakest
 ^Weakest !
 !

!DBVariable methodsFor: 'bench'!
init
        value := 0.
        constraints := OrderedCollection new.
        determinedBy := nil.
        walkStrength := Strength weakest.
        stay := true.
        mark := 0.
    !
value
 ^value !
value: aValue
 value := aValue !
constraints
 ^constraints !
determinedBy
 ^determinedBy !
determinedBy: aConstraint
 determinedBy := aConstraint !
walkStrength
 ^walkStrength !
walkStrength: aStrength
 walkStrength := aStrength !
stay
 ^stay !
stay: aBoolean
 stay := aBoolean !
mark
 ^mark !
mark: anInteger
 mark := anInteger !
addConstraint: aConstraint
 constraints add: aConstraint !
removeConstraint: aConstraint
        | keep |
        keep := OrderedCollection new.
        constraints do: [:c | (c == aConstraint) ifFalse: [ keep add: c ] ].
        constraints := keep.
        (determinedBy == aConstraint) ifTrue: [ determinedBy := nil ].
    !
 !

!DBVariable class methodsFor: 'bench'!
new
 ^self basicNew init !
value: aValue
        | v |
        v := self new.
        v value: aValue.
        ^v
    !
 !

!Plan methodsFor: 'bench'!
execute
 self do: [:c | c execute ] !
 !

!Planner methodsFor: 'bench'!
init
 currentMark := 0 !
newMark
        currentMark := currentMark + 1.
        ^currentMark
    !
incrementalAdd: aConstraint
        | mark overridden |
        mark := self newMark.
        overridden := aConstraint satisfy: mark.
        [ overridden == nil ] whileFalse: [
            overridden := overridden satisfy: mark ].
    !
incrementalRemove: aConstraint
        | out unsatisfied |
        out := aConstraint output.
        aConstraint markUnsatisfied.
        aConstraint removeFromGraph.
        unsatisfied := self removePropagateFrom: out.
        unsatisfied do: [:u | self incrementalAdd: u ].
    !
addPropagate: aConstraint mark: mark
        | todo d |
        todo := OrderedCollection new.
        todo addLast: aConstraint.
        [ todo isEmpty ] whileFalse: [
            d := todo removeFirst.
            (d output mark = mark) ifTrue: [
                self incrementalRemove: aConstraint.
                ^false ].
            d recalculate.
            self addConstraintsConsuming: d output to: todo ].
        ^true
    !
removePropagateFrom: out
        | unsatisfied todo v |
        out determinedBy: nil.
        out walkStrength: Strength weakest.
        out stay: true.
        unsatisfied := OrderedCollection new.
        todo := OrderedCollection new.
        todo addLast: out.
        [ todo isEmpty ] whileFalse: [
            v := todo removeFirst.
            v constraints do: [:c |
                c isSatisfied ifFalse: [ unsatisfied addLast: c ] ].
            self constraintsConsuming: v do: [:c |
                c recalculate.
                todo addLast: c output ] ].
        ^unsatisfied
    !
extractPlanFromConstraints: aCollection
        | sources |
        sources := OrderedCollection new.
        aCollection do: [:c |
            (c isInput and: [ c isSatisfied ]) ifTrue: [ sources addLast: c ] ].
        ^self makePlan: sources
    !
makePlan: sources
        | mark plan todo c |
        mark := self newMark.
        plan := Plan new.
        todo := sources.
        [ todo isEmpty ] whileFalse: [
            c := todo removeFirst.
            ((c output mark ~= mark) and: [ c inputsKnown: mark ]) ifTrue: [
                plan addLast: c.
                c output mark: mark.
                self addConstraintsConsuming: c output to: todo ] ].
        ^plan
    !
constraintsConsuming: aVariable do: aBlock
        | determining |
        determining := aVariable determinedBy.
        aVariable constraints do: [:c |
            ((c ~~ determining) and: [ c isSatisfied ]) ifTrue: [ aBlock value: c ] ].
    !
addConstraintsConsuming: aVariable to: aCollection
        self constraintsConsuming: aVariable do: [:c | aCollection addLast: c ].
    !
 !

!Planner class methodsFor: 'bench'!
new
 ^self basicNew init !
reset
 Current := self new !
current
 ^Current !
 !

!AbstractConstraint methodsFor: 'bench'!
strength
 ^strength !
isInput
 ^false !
addConstraint
        self addToGraph.
        Planner current incrementalAdd: self.
    !
destroyConstraint
        self isSatisfied
            ifTrue: [ Planner current incrementalRemove: self ]
            ifFalse: [ self removeFromGraph ].
    !
satisfy: mark
        | out overridden |
        self chooseMethod: mark.
        self isSatisfied ifFalse: [
            (strength sameAs: Strength required) ifTrue: [
                self error: 'Could not satisfy a required constraint' ].
            ^nil ].
        self markInputs: mark.
        out := self output.
        overridden := out determinedBy.
        (overridden == nil) ifFalse: [ overridden markUnsatisfied ].
        out determinedBy: self.
        (Planner current addPropagate: self mark: mark) ifFalse: [
            self error: 'Cycle encountered' ].
        out mark: mark.
        ^overridden
    !
markInputs: mark
        self inputsDo: [:in | in mark: mark ].
    !
inputsKnown: mark
        self inputsDo: [:v |
            ((v mark = mark) or: [ v stay or: [ v determinedBy == nil ] ])
                ifFalse: [ ^false ] ].
        ^true
    !
 !

!UnaryConstraint methodsFor: 'bench'!
initVar: aVariable strength: strengthSymbol
        strength := Strength of: strengthSymbol.
        output := aVariable.
        satisfied := false.
        self addConstraint.
    !
isSatisfied
 ^satisfied !
output
 ^output !
addToGraph
        output addConstraint: self.
        satisfied := false.
    !
removeFromGraph
        (output == nil) ifFalse: [ output removeConstraint: self ].
        satisfied := false.
    !
chooseMethod: mark
        satisfied := (output mark ~= mark)
            and: [ strength stronger: output walkStrength ].
    !
inputsDo: aBlock
 ^self !
markUnsatisfied
 satisfied := false !
recalculate
        output walkStrength: strength.
        output stay: self isInput not.
        output stay ifTrue: [ self execute ].
    !
 !

!UnaryConstraint class methodsFor: 'bench'!
var: aVariable strength: strengthSymbol
        ^self basicNew initVar: aVariable strength: strengthSymbol
    !
 !

!StayConstraint methodsFor: 'bench'!
execute
 ^self !
 !

!EditConstraint methodsFor: 'bench'!
isInput
 ^true !
execute
 ^self !
 !

!BinaryConstraint methodsFor: 'bench'!
initVar: aVariable var: bVariable strength: strengthSymbol
        strength := Strength of: strengthSymbol.
        v1 := aVariable.
        v2 := bVariable.
        direction := nil.
        self addConstraint.
    !
isSatisfied
 ^(direction == nil) not !
addToGraph
        v1 addConstraint: self.
        v2 addConstraint: self.
        direction := nil.
    !
removeFromGraph
        (v1 == nil) ifFalse: [ v1 removeConstraint: self ].
        (v2 == nil) ifFalse: [ v2 removeConstraint: self ].
        direction := nil.
    !
chooseMethod: mark
        (v1 mark = mark) ifTrue: [
            direction := ((v2 mark ~= mark) and: [ strength stronger: v2 walkStrength ])
                ifTrue: [ #forward ] ifFalse: [ nil ].
            ^self ].
        (v2 mark = mark) ifTrue: [
            direction := ((v1 mark ~= mark) and: [ strength stronger: v1 walkStrength ])
                ifTrue: [ #backward ] ifFalse: [ nil ].
            ^self ].
        "Neither variable is marked, so there is a choice: prefer to flow
         toward the weaker walkabout strength."
        (v1 walkStrength weaker: v2 walkStrength)
            ifTrue: [
                direction := (strength stronger: v1 walkStrength)
                    ifTrue: [ #backward ] ifFalse: [ nil ] ]
            ifFalse: [
                direction := (strength stronger: v2 walkStrength)
                    ifTrue: [ #forward ] ifFalse: [ nil ] ].
    !
inputsDo: aBlock
        (direction == #forward)
            ifTrue: [ aBlock value: v1 ]
            ifFalse: [ aBlock value: v2 ].
    !
markUnsatisfied
 direction := nil !
output
        (direction == #forward) ifTrue: [ ^v2 ].
        ^v1
    !
recalculate
        | in out |
        (direction == #forward)
            ifTrue: [ in := v1. out := v2 ]
            ifFalse: [ in := v2. out := v1 ].
        out walkStrength: (strength weakest: in walkStrength).
        out stay: in stay.
        out stay ifTrue: [ self execute ].
    !
 !

!BinaryConstraint class methodsFor: 'bench'!
var: aVariable var: bVariable strength: strengthSymbol
        ^self basicNew initVar: aVariable var: bVariable strength: strengthSymbol
    !
 !

!EqualityConstraint methodsFor: 'bench'!
execute
        (direction == #forward)
            ifTrue: [ v2 value: v1 value ]
            ifFalse: [ v1 value: v2 value ].
    !
 !

!ScaleConstraint methodsFor: 'bench'!
initSrc: srcVariable scale: scaleVariable offset: offsetVariable dst: dstVariable strength: strengthSymbol
        strength := Strength of: strengthSymbol.
        v1 := srcVariable.
        v2 := dstVariable.
        scale := scaleVariable.
        offset := offsetVariable.
        direction := nil.
        self addConstraint.
    !
addToGraph
        v1 addConstraint: self.
        v2 addConstraint: self.
        scale addConstraint: self.
        offset addConstraint: self.
        direction := nil.
    !
removeFromGraph
        (v1 == nil) ifFalse: [ v1 removeConstraint: self ].
        (v2 == nil) ifFalse: [ v2 removeConstraint: self ].
        (scale == nil) ifFalse: [ scale removeConstraint: self ].
        (offset == nil) ifFalse: [ offset removeConstraint: self ].
        direction := nil.
    !
inputsDo: aBlock
        (direction == #forward)
            ifTrue: [ aBlock value: v1 ]
            ifFalse: [ aBlock value: v2 ].
        aBlock value: scale.
        aBlock value: offset.
    !
execute
        (direction == #forward)
            ifTrue: [ v2 value: v1 value * scale value + offset value ]
            ifFalse: [ v1 value: (v2 value - offset value) // scale value ].
    !
recalculate
        | in out |
        (direction == #forward)
            ifTrue: [ in := v1. out := v2 ]
            ifFalse: [ in := v2. out := v1 ].
        out walkStrength: (strength weakest: in walkStrength).
        out stay: (in stay and: [ scale stay and: [ offset stay ] ]).
        out stay ifTrue: [ self execute ].
    !
 !

!ScaleConstraint class methodsFor: 'bench'!
src: srcVariable scale: scaleVariable offset: offsetVariable dst: dstVariable strength: strengthSymbol
        ^self basicNew initSrc: srcVariable scale: scaleVariable
            offset: offsetVariable dst: dstVariable strength: strengthSymbol
    !
 !

!DeltaBlue class methodsFor: 'bench'!
setUp
 ^self !
runOne
        ^(self chainTest: 100) + (self projectionTest: 100)
    !
checkResult: r
 ^r = 224874 !
chainTest: n
        | prev v first last editC edits plan |
        Planner reset.
        prev := nil.
        1 to: n + 1 do: [:i |
            v := DBVariable new.
            (prev == nil) ifFalse: [
                EqualityConstraint var: prev var: v strength: #required ].
            (i = 1) ifTrue: [ first := v ].
            (i = (n + 1)) ifTrue: [ last := v ].
            prev := v ].
        StayConstraint var: last strength: #strongDefault.
        editC := EditConstraint var: first strength: #preferred.
        edits := OrderedCollection new.
        edits add: editC.
        plan := Planner current extractPlanFromConstraints: edits.
        0 to: 99 do: [:i |
            first value: i.
            plan execute.
            (last value = i) ifFalse: [ self error: 'Chain test failed' ] ].
        ^last value
    !
projectionTest: n
        | scale offset src dst dests total |
        Planner reset.
        dests := OrderedCollection new.
        scale := DBVariable value: 10.
        offset := DBVariable value: 1000.
        1 to: n do: [:i |
            src := DBVariable value: i.
            dst := DBVariable value: i.
            dests addLast: dst.
            StayConstraint var: src strength: #normal.
            ScaleConstraint src: src scale: scale offset: offset dst: dst strength: #required ].
        self change: src to: 17.
        (dst value = 1170) ifFalse: [ self error: 'Projection test 1 failed' ].
        self change: dst to: 1050.
        (src value = 5) ifFalse: [ self error: 'Projection test 2 failed' ].
        self change: scale to: 5.
        1 to: n - 1 do: [:i |
            ((dests at: i) value = (i * 5 + 1000))
                ifFalse: [ self error: 'Projection test 3 failed' ] ].
        self change: offset to: 2000.
        total := 0.
        1 to: n - 1 do: [:i |
            ((dests at: i) value = (i * 5 + 2000))
                ifFalse: [ self error: 'Projection test 4 failed' ].
            total := total + (dests at: i) value ].
        ^total + dst value
    !
change: aVariable to: newValue
        | editC edits plan |
        editC := EditConstraint var: aVariable strength: #preferred.
        edits := OrderedCollection new.
        edits add: editC.
        plan := Planner current extractPlanFromConstraints: edits.
        10 timesRepeat: [
            aVariable value: newValue.
            plan execute ].
        editC destroyConstraint.
    !
 !


Strength initStrengths.!
!CogBench class methodsFor: 'bench'!
benchRichards
	| r |
	RichardsBenchmark setUp.
	r := RichardsBenchmark runOne.
	(RichardsBenchmark checkResult: r) ifFalse: [ ^self error: 'richards: wrong result' ].
	^r!
benchDeltaBlue
	| r |
	Strength initStrengths.
	DeltaBlue setUp.
	r := DeltaBlue runOne.
	(DeltaBlue checkResult: r) ifFalse: [ ^self error: 'deltablue: wrong result' ].
	^r!
runEverything
	self runAll.
	self run: 'richards ' block: [ self benchRichards ] check: 2324609297.
	self run: 'deltablue' block: [ self benchDeltaBlue ] check: 224874.! !

CogBench runEverything.!
Smalltalk exitSuccess.!
