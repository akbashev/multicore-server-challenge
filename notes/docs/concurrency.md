# Concurrency: one actor per thread

## An executor of your own

Each actor runs on its own thread through a custom executor:

```swift
final class EventLoop: SerialExecutor, TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob)        // lock a job list, write the eventfd if the loop sleeps
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
    // the thread: run queued jobs; with none, sleep in epoll_wait on the eventfd
}

actor Reactor {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }
}
```

- A network reactor waits in `epoll_wait` on its own sockets plus the loop's eventfd, so one call covers both
  readiness and messages from other actors.
- Write the eventfd only when the loop is asleep (an atomic flag), as NIO's event loop does.

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
