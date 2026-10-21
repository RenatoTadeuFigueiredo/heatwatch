#ifndef HeatWatch_Bridging_h
#define HeatWatch_Bridging_h

#include <libproc.h>
#include <sys/types.h>

/* ---- Temperature (private IOHID sensor API, no root required) ---- */

int hw_temp_init(void);
int hw_temp_sensor_count(void);
double hw_temp_read(void);
void hw_temp_refresh_sensors(void);
void hw_temp_close(void);

/* ---- CPU load fallback for Macs without exposed die sensors ---- */

double hw_cpu_load(void);

/* ---- Per-process energy via proc_pid_rusage ---- */

typedef struct {
    pid_t pid;
    unsigned long long energy_nj;
} proc_energy_t;

/* Returns the number of entries written to *out (caller frees), or -1 on error. */
int proc_energy_snapshot(proc_energy_t **out);

/* Executable path for pids without a running NSApplication. */
int proc_pid_path(pid_t pid, char *buffer, size_t size);

#endif
