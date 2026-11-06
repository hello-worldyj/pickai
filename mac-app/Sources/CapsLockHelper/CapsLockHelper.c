#include "include/CapsLockHelper.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>

static io_connect_t open_hid(void) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass));
    if (!svc) return 0;
    io_connect_t conn = 0;
    IOServiceOpen(svc, mach_task_self(), kIOHIDParamConnectType, &conn);
    IOObjectRelease(svc);
    return conn;
}

bool capslock_get(void) {
    io_connect_t conn = open_hid();
    if (!conn) return false;
    bool state = false;
    IOHIDGetModifierLockState(conn, kIOHIDCapsLockState, &state);
    IOServiceClose(conn);
    return state;
}

void capslock_set(bool on) {
    io_connect_t conn = open_hid();
    if (!conn) return;
    IOHIDSetModifierLockState(conn, kIOHIDCapsLockState, on);
    IOServiceClose(conn);
}
