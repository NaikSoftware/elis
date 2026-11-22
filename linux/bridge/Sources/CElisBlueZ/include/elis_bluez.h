#pragma once
#include <stddef.h>
#include <stdint.h>

// The phone relay's BLE peripheral on Linux: BlueZ over sd-bus and an LE L2CAP CoC socket.
// Every call, and every callback, runs on the caller's one thread or serial queue.
typedef struct elis_bluez elis_bluez;

enum {
    ELIS_BLUEZ_POWERED = 1,     // the adapter is on: publish and advertise
    ELIS_BLUEZ_UNPOWERED = 2,   // the adapter or bluetoothd went away
    ELIS_BLUEZ_ADVERTISING = 3, // the last elis_bluez_advertise is live
    ELIS_BLUEZ_FAILED = 4,      // it failed; `message` is "<step>: <reason>", step service or advertising
};

typedef void (*elis_bluez_event)(void *context, int event, const char *message);

/// The first LE-capable adapter on the system bus, or NULL with the reason in `error`.
elis_bluez *elis_bluez_open(elis_bluez_event callback, void *context, char *error, size_t error_size);
void elis_bluez_free(elis_bluez *bluez);
/// The bus descriptor to watch for input.
int elis_bluez_fd(elis_bluez *bluez);
/// Handles everything the bus has, calling back; negative once the bus connection is lost.
int elis_bluez_process(elis_bluez *bluez);
int elis_bluez_powered(elis_bluez *bluez);
/// Serves `psm` (read as 2 bytes little-endian) under `service_uuid` and advertises that UUID alone,
/// replacing the last registration. Answers with ADVERTISING or FAILED.
void elis_bluez_advertise(elis_bluez *bluez, const char *service_uuid, uint16_t psm);
/// Withdraws the service and the advertisement.
void elis_bluez_withdraw(elis_bluez *bluez);

/// A non-blocking LE L2CAP CoC listener on a dynamic PSM, unencrypted; -1 with errno.
int elis_l2cap_listen(uint16_t *psm);
/// The next channel, non-blocking and close-on-exec, and the largest SDU it sends; -1 with errno.
int elis_l2cap_accept(int listener, int *send_mtu);
