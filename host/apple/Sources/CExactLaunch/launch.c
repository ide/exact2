// @ref design: Exact Observe §3.2 — L and the process age, before `main`.
#include "CExactLaunch.h"
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

static exact_launch_facts facts;

// Priority near Observe's (62137): late among constructors, so close to `main`.
__attribute__((constructor(62137))) static void exact_launch_constructor(void) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    facts.constructorMono = (double)mach_absolute_time() * base.numer / base.denom / 1e9;
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        double start = info.kp_proc.p_starttime.tv_sec + info.kp_proc.p_starttime.tv_usec / 1e6;
        facts.processAge = (now.tv_sec + now.tv_usec / 1e6) - start;
        facts.traced = (info.kp_proc.p_flag & P_TRACED) != 0;
        facts.valid = 1;
    }
    const char *prewarm = getenv("ActivePrewarm");
    facts.prewarm = prewarm != NULL && strcmp(prewarm, "1") == 0;
    facts.tty = isatty(STDERR_FILENO);
}

exact_launch_facts exact_launch_constructor_facts(void) { return facts; }
