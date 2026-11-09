# Concurrency: one actor per thread

## An executor of your own

Each actor runs on its own thread through a custom executor, the [`EventLoop`](../Sources/EventLoop/EventLoop.swift)
module:

```swift
actor Reactor {
    nonisolated let loop: EventLoop                   // try EventLoop(name: "reactor")
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    func run() async throws {
        try loop.register(listener, for: .readable, token: 0)
        var events = EventLoop.EventBuffer(capacity: 256)
        while true {
            let (count, jobsWaiting) = loop.waitForEvents(&events)   // sockets ready, or a message for this loop
            for i in 0..<count { handle(events[i]) }
            if jobsWaiting { await Task.yield() }                    // let the messages run
        }
    }
}
```

- `enqueue` appends to a `Mutex`-protected job list and writes the eventfd only when the loop is asleep (an atomic
  flag), as NIO's event loop does.
- A reactor waits in `epoll_wait` on its own sockets plus the loop's eventfd, so one call covers both readiness and
  messages from other actors.
- With no job to run, the thread sleeps on a second epoll instance that holds only the eventfd: level-triggered
  sockets stay ready while their actor is busy elsewhere, and waiting on them then would spin.
- `wait(until:)` and `interrupt()` let the actor wait for a deadline or a wake-up while the thread runs its other
  jobs.

## No global executor, no libdispatch

Make `main` synchronous. It starts one root task on the first loop, holding a `withDiscardingTaskGroup` with every
actor as a child (`group.addTask(executorPreference: actor.loop)`), then gives its own thread to that loop
(`runOnCallingThread()`). Every thread is then an actor's, and the global concurrent executor never starts its
threads.

## Shared state behind a Mutex, not an actor

A scheduler that every thread touches for a moment (take the next batch, add work) costs less as `Mutex`-protected
state than as an actor with its own thread: no hop, no wake-up. Workers wait on their own loop, and an `isolated`
parameter makes the compiler check it:

```swift
func nextReads<L: LoopIsolated>(for lane: isolated L, finished: ReadBatchDone?) async -> ReadBatch
```

Wake-ups are collected under the lock in a `~Copyable` list and fired after it is released (`consuming func fire()`).

## Batch the hand-offs

The mechanism mattered less than how often it ran. (The numbers below are one workload's; the lesson is to measure
how often threads hand work over, not to copy 2 ms.) Replacing a task per message with awaited calls was slower on its
own. Making each reactor turn last at least 2 ms, so a turn's work travels in one message, cut context switches from
0.53 to 0.25 per request.

## One thread: MainActor

For a single-threaded server, default MainActor isolation lets the compiler prove nothing runs elsewhere, with a
synchronous loop and no executors, no `async`, and no `Task`.
