// The process's launch facts, read by a constructor before `main` (Observe's
// own method, `AppLoadTimeProvider.m`): what only the earliest code can see.
#pragma once

typedef struct {
    /// Seconds from the kernel's process start to this constructor (wall
    /// clock, both read here, so a later clock change cannot move it).
    double processAge;
    /// `CACurrentMediaTime()` at the constructor (mach_absolute_time).
    double constructorMono;
    /// iOS prewarmed this launch (`ActivePrewarm=1`; gone after launch).
    int prewarm;
    /// A debugger is attached (`P_TRACED`).
    int traced;
    /// stderr is a terminal (Observe classifies such launches cold).
    int tty;
    /// The kernel answered for the process start.
    int valid;
} exact_launch_facts;

exact_launch_facts exact_launch_constructor_facts(void);
