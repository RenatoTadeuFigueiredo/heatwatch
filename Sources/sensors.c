#include "Bridging.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

/* Private IOHID API surface (not exported in the public SDK headers). */
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int32_t type,
                                          int32_t matching, uint64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperatureM 15
#define IOHID_EVENT_FIELD_BASE(type) ((type) << 16)

#define MAX_SENSORS 32
#define SENSORS_PER_READ 5

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static IOHIDEventSystemClientRef g_client = NULL;
static IOHIDServiceClientRef g_sensors[MAX_SENSORS];
static int g_sensor_count = 0;

/* CPU load fallback state. */
static uint64_t g_prev_ticks[4] = {0, 0, 0, 0};

static int build_matching_dictionary(CFDictionaryRef *out)
{
    int page = 0xff00, usage = 5;
    CFNumberRef page_number = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usage_number = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    if (!page_number || !usage_number) return -1;

    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[2] = { page_number, usage_number };
    *out = CFDictionaryCreate(NULL, keys, values, 2,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(page_number);
    CFRelease(usage_number);
    return *out ? 0 : -1;
}

static void release_sensors_locked(void)
{
    for (int i = 0; i < g_sensor_count; i++) {
        CFRelease(g_sensors[i]);
        g_sensors[i] = NULL;
    }
    g_sensor_count = 0;
}

static int collect_sensors_locked(IOHIDEventSystemClientRef client)
{
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return -1;

    release_sensors_locked();
    long count = CFArrayGetCount(services);
    for (long i = 0; i < count && g_sensor_count < MAX_SENSORS; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!product) continue;

        char name[128] = {0};
        Boolean converted = CFStringGetCString((CFStringRef)product, name, sizeof(name),
                                               kCFStringEncodingUTF8);
        CFRelease(product);
        if (!converted) continue;

        /* Apple Silicon exposes CPU die sensors as "PMU tdieN". */
        if (strstr(name, "tdie") == NULL) continue;

        g_sensors[g_sensor_count++] = (IOHIDServiceClientRef)CFRetain(service);
    }

    CFRelease(services);
    return g_sensor_count;
}

int hw_temp_init(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_client == NULL) {
        g_client = IOHIDEventSystemClientCreate(NULL);
        if (g_client != NULL) {
            CFDictionaryRef matching = NULL;
            if (build_matching_dictionary(&matching) == 0) {
                IOHIDEventSystemClientSetMatching(g_client, matching);
                CFRelease(matching);
            }
            collect_sensors_locked(g_client);
        }
    }
    int count = g_sensor_count;
    pthread_mutex_unlock(&g_lock);
    return count;
}

int hw_temp_sensor_count(void)
{
    pthread_mutex_lock(&g_lock);
    int count = g_sensor_count;
    pthread_mutex_unlock(&g_lock);
    return count;
}

void hw_temp_refresh_sensors(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_client != NULL) collect_sensors_locked(g_client);
    pthread_mutex_unlock(&g_lock);
}

double hw_temp_read(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_sensor_count == 0) {
        pthread_mutex_unlock(&g_lock);
        return -1.0;
    }

    /* Sampling a spread of sensors is enough for a trend and keeps SMC traffic low. */
    int stride = g_sensor_count / SENSORS_PER_READ;
    if (stride < 1) stride = 1;

    double sum = 0.0;
    int samples = 0;
    for (int i = 0; i < g_sensor_count; i += stride) {
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(g_sensors[i],
            kIOHIDEventTypeTemperatureM, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event,
            IOHID_EVENT_FIELD_BASE(kIOHIDEventTypeTemperatureM));
        CFRelease(event);
        if (value > 0.0 && value < 130.0) {
            sum += value;
            samples++;
        }
    }
    pthread_mutex_unlock(&g_lock);

    return samples > 0 ? sum / samples : -1.0;
}

void hw_temp_close(void)
{
    pthread_mutex_lock(&g_lock);
    release_sensors_locked();
    if (g_client != NULL) {
        CFRelease(g_client);
        g_client = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

double hw_cpu_load(void)
{
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t size = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                        (host_info_t)&info, &size) != KERN_SUCCESS) {
        return -1.0;
    }

    uint64_t ticks[4] = {
        info.cpu_ticks[CPU_STATE_USER],
        info.cpu_ticks[CPU_STATE_SYSTEM],
        info.cpu_ticks[CPU_STATE_IDLE],
        info.cpu_ticks[CPU_STATE_NICE]
    };

    uint64_t busy = 0, total = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t delta = ticks[i] - g_prev_ticks[i];
        total += delta;
        if (i != CPU_STATE_IDLE) busy += delta;
        g_prev_ticks[i] = ticks[i];
    }
    if (total == 0) return -1.0;
    return (double)busy / (double)total * 100.0;
}
