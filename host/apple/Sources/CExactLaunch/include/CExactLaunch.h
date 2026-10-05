// Launch facts read by a constructor before `main`, the same way Observe's
// `AppLoadTimeProvider.m` reads them.
#pragma once

typedef struct {
    /// Seconds from the kernel's process start to the constructor. Both ends
    /// are wall clock read together, so a later clock change cannot skew it.
    double processAge;
    /// Seconds on the `CACurrentMediaTime()` clock (mach_absolute_time) at the constructor.
    double constructorMono;
    /// iOS prewarmed this launch. `ActivePrewarm=1` is only set this early.
    int prewarm;
    int traced;
    /// stderr is a terminal (Observe classifies such launches cold).
    int tty;
    /// The kernel reported the process start, so `processAge` and `traced` are set.
    int valid;
} exact_launch_facts;

exact_launch_facts exact_launch_constructor_facts(void);
