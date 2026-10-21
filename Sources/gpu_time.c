#include "Bridging.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>

/* Each Metal command queue shows up as an AGXDeviceUserClient child of the
   accelerator. Its "AppUsage" array carries the GPU nanoseconds the owning
   process has submitted so far; per-process GPU time is not in rusage. */

#define MAX_CLIENTS 512

static int collect_client(io_registry_entry_t service, proc_gpu_time_t *entry)
{
    CFTypeRef creator = IORegistryEntryCreateCFProperty(service, CFSTR("IOUserClientCreator"),
                                                        kCFAllocatorDefault, 0);
    if (creator == NULL) return -1;

    int pid = -1;
    if (CFGetTypeID(creator) == CFStringGetTypeID()) {
        char owner[128] = {0};
        if (CFStringGetCString((CFStringRef)creator, owner, sizeof(owner), kCFStringEncodingUTF8)) {
            if (sscanf(owner, "pid %d", &pid) != 1) pid = -1;
        }
    }
    CFRelease(creator);
    if (pid <= 0) return -1;

    unsigned long long total = 0;
    CFTypeRef usage = IORegistryEntryCreateCFProperty(service, CFSTR("AppUsage"),
                                                      kCFAllocatorDefault, 0);
    if (usage != NULL) {
        if (CFGetTypeID(usage) == CFArrayGetTypeID()) {
            CFArrayRef queues = (CFArrayRef)usage;
            for (CFIndex i = 0; i < CFArrayGetCount(queues); i++) {
                CFDictionaryRef queue = CFArrayGetValueAtIndex(queues, i);
                if (queue == NULL || CFGetTypeID(queue) != CFDictionaryGetTypeID()) continue;

                CFTypeRef value = CFDictionaryGetValue(queue, CFSTR("accumulatedGPUTime"));
                long long nanoseconds = 0;
                if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID() &&
                    CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &nanoseconds) &&
                    nanoseconds > 0) {
                    total += (unsigned long long)nanoseconds;
                }
            }
        }
        CFRelease(usage);
    }

    entry->pid = (pid_t)pid;
    entry->gpu_ns = total;
    return 0;
}

int gpu_time_snapshot(proc_gpu_time_t **out)
{
    *out = NULL;

    io_iterator_t accelerators = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                     &accelerators) != KERN_SUCCESS) {
        return -1;
    }

    proc_gpu_time_t *entries = calloc(MAX_CLIENTS, sizeof(proc_gpu_time_t));
    if (entries == NULL) {
        IOObjectRelease(accelerators);
        return -1;
    }

    int used = 0;
    io_registry_entry_t accelerator;
    while ((accelerator = IOIteratorNext(accelerators)) != 0 && used < MAX_CLIENTS) {
        io_iterator_t children = 0;
        if (IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS) {
            io_registry_entry_t child;
            while ((child = IOIteratorNext(children)) != 0 && used < MAX_CLIENTS) {
                io_name_t klass = {0};
                IOObjectGetClass(child, klass);
                if (strcmp(klass, "AGXDeviceUserClient") == 0 &&
                    collect_client(child, &entries[used]) == 0) {
                    used++;
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(children);
        }
        IOObjectRelease(accelerator);
    }
    IOObjectRelease(accelerators);

    if (used == 0) {
        free(entries);
        return -1;
    }

    *out = entries;
    return used;
}
