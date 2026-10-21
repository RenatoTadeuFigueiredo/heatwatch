#include "Bridging.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>

int proc_energy_snapshot(proc_energy_t **out)
{
    *out = NULL;

    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return -1;
    capacity += 64;

    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (pids == NULL) return -1;

    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (count <= 0) {
        free(pids);
        return -1;
    }

    proc_energy_t *entries = calloc((size_t)count, sizeof(proc_energy_t));
    if (entries == NULL) {
        free(pids);
        return -1;
    }

    int used = 0;
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        struct rusage_info_v6 info;
        memset(&info, 0, sizeof(info));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&info) != 0) {
            continue; /* root-owned or already exited */
        }

        entries[used].pid = pid;
        entries[used].energy_nj = info.ri_energy_nj;
        used++;
    }

    free(pids);

    if (used == 0) {
        free(entries);
        return -1;
    }

    *out = entries;
    return used;
}

int proc_pid_path(pid_t pid, char *buffer, size_t size)
{
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return -1;

    strlcpy(buffer, path, size);
    return 0;
}
