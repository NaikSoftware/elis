#define _GNU_SOURCE // accept4
#include "elis_bluez.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <systemd/sd-bus.h>
#include <unistd.h>

// libbluetooth-dev is not a build dependency: the few kernel ABI values the socket needs, from <bluetooth/*.h>.
#define ELIS_AF_BLUETOOTH 31
#define ELIS_BTPROTO_L2CAP 0
#define ELIS_SOL_BLUETOOTH 274
#define ELIS_BT_SECURITY 4
#define ELIS_BT_SECURITY_LOW 1
#define ELIS_BT_SNDMTU 12
#define ELIS_BT_RCVMTU 13
#define ELIS_BDADDR_LE_PUBLIC 0x01

struct elis_sockaddr_l2 {
    sa_family_t l2_family;
    unsigned short l2_psm;
    uint8_t l2_bdaddr[6];
    unsigned short l2_cid;
    uint8_t l2_bdaddr_type;
};

struct elis_bt_security {
    uint8_t level;
    uint8_t key_size;
};

#define ROOT "/ua/naiksoftware/elis/ble"
#define SERVICE ROOT "/service0"
#define CHARACTERISTIC SERVICE "/char0"
#define ADVERTISEMENT ROOT "/adv0"
#define PSM_UUID "a6e5c0de-0001-4a67-8000-656c697300d1"

struct elis_bluez {
    sd_bus *bus;
    elis_bluez_event callback;
    void *context;
    char adapter[256];
    int powered;
    char uuid[37];
    uint16_t psm;
    int registered;     // the application, then the advertisement, are BlueZ's until withdrawn
    sd_bus_slot *pending;
};

static void emit(elis_bluez *b, int event, const char *message) { b->callback(b->context, event, message); }

// MARK: exported objects

static int service_uuid(sd_bus *bus, const char *path, const char *interface, const char *property,
                        sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    elis_bluez *b = userdata;
    return sd_bus_message_append(reply, "s", b->uuid);
}

static int fixed_true(sd_bus *bus, const char *path, const char *interface, const char *property,
                      sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "b", 1);
}

static int characteristic_uuid(sd_bus *bus, const char *path, const char *interface, const char *property,
                               sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "s", PSM_UUID);
}

static int characteristic_service(sd_bus *bus, const char *path, const char *interface, const char *property,
                                  sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "o", SERVICE);
}

static int characteristic_flags(sd_bus *bus, const char *path, const char *interface, const char *property,
                                sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "as", 1, "read");
}

static int read_value(sd_bus_message *call, void *userdata, sd_bus_error *error) {
    elis_bluez *b = userdata;
    const uint8_t value[2] = {b->psm & 0xFF, b->psm >> 8};
    sd_bus_message *reply = NULL;
    int r = sd_bus_message_new_method_return(call, &reply);
    if (r >= 0) r = sd_bus_message_append_array(reply, 'y', value, sizeof value);
    if (r >= 0) r = sd_bus_send(NULL, reply, NULL);
    sd_bus_message_unref(reply);
    return r;
}

static int advertisement_type(sd_bus *bus, const char *path, const char *interface, const char *property,
                              sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    return sd_bus_message_append(reply, "s", "peripheral");
}

static int advertisement_uuids(sd_bus *bus, const char *path, const char *interface, const char *property,
                               sd_bus_message *reply, void *userdata, sd_bus_error *error) {
    elis_bluez *b = userdata;
    return sd_bus_message_append(reply, "as", 1, b->uuid);
}

static int released(sd_bus_message *call, void *userdata, sd_bus_error *error) {
    return sd_bus_reply_method_return(call, NULL);
}

static const sd_bus_vtable service_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("UUID", "s", service_uuid, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Primary", "b", fixed_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_VTABLE_END,
};

static const sd_bus_vtable characteristic_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("UUID", "s", characteristic_uuid, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Service", "o", characteristic_service, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Flags", "as", characteristic_flags, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_METHOD("ReadValue", "a{sv}", "ay", read_value, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_VTABLE_END,
};

// the service UUID only: a local name would expose the computer's name
static const sd_bus_vtable advertisement_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("Type", "s", advertisement_type, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("ServiceUUIDs", "as", advertisement_uuids, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Discoverable", "b", fixed_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_METHOD("Release", "", "", released, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_VTABLE_END,
};

// MARK: adapter

static void set_error(char *error, size_t size, const char *step, int r, const sd_bus_error *e) {
    if (error && size) snprintf(error, size, "%s: %s", step, e && e->message ? e->message : strerror(-r));
}

/// The first object with LEAdvertisingManager1 and GattManager1, from BlueZ's object manager.
static int find_adapter(elis_bluez *b, sd_bus_error *e) {
    sd_bus_message *reply = NULL;
    int r = sd_bus_call_method(b->bus, "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", e,
                               &reply, "");
    if (r < 0) return r;
    int found = 0;
    r = sd_bus_message_enter_container(reply, 'a', "{oa{sa{sv}}}");
    while (r >= 0 && !found && (r = sd_bus_message_enter_container(reply, 'e', "oa{sa{sv}}")) > 0) {
        const char *path = NULL;
        int advertises = 0, serves = 0;
        r = sd_bus_message_read(reply, "o", &path);
        if (r >= 0) r = sd_bus_message_enter_container(reply, 'a', "{sa{sv}}");
        while (r >= 0 && (r = sd_bus_message_enter_container(reply, 'e', "sa{sv}")) > 0) {
            const char *interface = NULL;
            r = sd_bus_message_read(reply, "s", &interface);
            if (r >= 0) {
                advertises |= strcmp(interface, "org.bluez.LEAdvertisingManager1") == 0;
                serves |= strcmp(interface, "org.bluez.GattManager1") == 0;
                r = sd_bus_message_skip(reply, "a{sv}");
            }
            if (r >= 0) r = sd_bus_message_exit_container(reply);
        }
        if (r >= 0) r = sd_bus_message_exit_container(reply);
        if (r >= 0) r = sd_bus_message_exit_container(reply);
        if (r >= 0 && advertises && serves && strlen(path) < sizeof b->adapter) {
            strcpy(b->adapter, path);
            found = 1;
        }
    }
    sd_bus_message_unref(reply);
    if (r < 0) return r;
    return found ? 0 : -ENODEV;
}

static void read_powered(elis_bluez *b) {
    int on = 0;
    b->powered = sd_bus_get_property_trivial(b->bus, "org.bluez", b->adapter, "org.bluez.Adapter1", "Powered", NULL, 'b',
                                             &on) >= 0 && on;
}

static int properties_changed(sd_bus_message *m, void *userdata, sd_bus_error *error) {
    elis_bluez *b = userdata;
    const char *interface = NULL;
    if (sd_bus_message_read(m, "s", &interface) < 0 || strcmp(interface, "org.bluez.Adapter1") != 0) return 0;
    if (sd_bus_message_enter_container(m, 'a', "{sv}") < 0) return 0;
    while (sd_bus_message_enter_container(m, 'e', "sv") > 0) {
        const char *name = NULL;
        int on = 0;
        if (sd_bus_message_read(m, "s", &name) < 0) return 0;
        if (strcmp(name, "Powered") == 0) {
            if (sd_bus_message_read(m, "v", "b", &on) < 0) return 0;
            if (on != b->powered) {
                b->powered = on;
                emit(b, on ? ELIS_BLUEZ_POWERED : ELIS_BLUEZ_UNPOWERED, NULL);
            }
        } else if (sd_bus_message_skip(m, "v") < 0) {
            return 0;
        }
        if (sd_bus_message_exit_container(m) < 0) return 0;
    }
    return 0;
}

// bluetoothd restarting drops every registration; it is the radio going off and coming back.
// shortcut: an adapter unplugged under a running bluetoothd is not followed; re-run serve after plugging one in
static int owner_changed(sd_bus_message *m, void *userdata, sd_bus_error *error) {
    elis_bluez *b = userdata;
    const char *name = NULL, *old = NULL, *now = NULL;
    if (sd_bus_message_read(m, "sss", &name, &old, &now) < 0) return 0;
    b->registered = 0;
    b->pending = sd_bus_slot_unref(b->pending);
    if (b->powered) {
        b->powered = 0;
        emit(b, ELIS_BLUEZ_UNPOWERED, NULL);
    }
    if (now && *now) {
        read_powered(b);
        if (b->powered) emit(b, ELIS_BLUEZ_POWERED, NULL);
    }
    return 0;
}

elis_bluez *elis_bluez_open(elis_bluez_event callback, void *context, char *error, size_t error_size) {
    elis_bluez *b = calloc(1, sizeof *b);
    if (!b) return NULL;
    b->callback = callback;
    b->context = context;
    sd_bus_error e = SD_BUS_ERROR_NULL;
    int r = sd_bus_open_system(&b->bus);
    if (r < 0) {
        set_error(error, error_size, "system bus", r, NULL);
        goto fail;
    }
    r = find_adapter(b, &e);
    if (r < 0) {
        set_error(error, error_size, "adapter", r, r == -ENODEV ? NULL : &e);
        goto fail;
    }
    read_powered(b);
    char match[512];
    snprintf(match, sizeof match, "type='signal',sender='org.bluez',path='%s',interface='org.freedesktop.DBus.Properties',"
             "member='PropertiesChanged',arg0='org.bluez.Adapter1'", b->adapter);
    if ((r = sd_bus_add_match(b->bus, NULL, match, properties_changed, b)) < 0
        || (r = sd_bus_add_match(b->bus, NULL, "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',"
                                 "arg0='org.bluez'", owner_changed, b)) < 0
        || (r = sd_bus_add_object_manager(b->bus, NULL, ROOT)) < 0
        || (r = sd_bus_add_object_vtable(b->bus, NULL, SERVICE, "org.bluez.GattService1", service_vtable, b)) < 0
        || (r = sd_bus_add_object_vtable(b->bus, NULL, CHARACTERISTIC, "org.bluez.GattCharacteristic1",
                                         characteristic_vtable, b)) < 0
        || (r = sd_bus_add_object_vtable(b->bus, NULL, ADVERTISEMENT, "org.bluez.LEAdvertisement1",
                                         advertisement_vtable, b)) < 0) {
        set_error(error, error_size, "export", r, NULL);
        goto fail;
    }
    sd_bus_error_free(&e);
    return b;
fail:
    sd_bus_error_free(&e);
    elis_bluez_free(b);
    return NULL;
}

void elis_bluez_free(elis_bluez *b) {
    if (!b) return;
    if (b->bus) {
        elis_bluez_withdraw(b);
        sd_bus_flush(b->bus);
        sd_bus_flush_close_unref(b->bus);
    }
    free(b);
}

int elis_bluez_fd(elis_bluez *b) { return sd_bus_get_fd(b->bus); }

int elis_bluez_process(elis_bluez *b) {
    int r;
    while ((r = sd_bus_process(b->bus, NULL)) > 0) {}
    return r;
}

int elis_bluez_powered(elis_bluez *b) { return b->powered; }

// MARK: registration

static void failed(elis_bluez *b, const char *step, const sd_bus_error *e) {
    char message[512];
    snprintf(message, sizeof message, "%s: %s", step, e && e->message ? e->message : "no reply");
    emit(b, ELIS_BLUEZ_FAILED, message);
}

static int advertisement_registered(sd_bus_message *reply, void *userdata, sd_bus_error *unused) {
    elis_bluez *b = userdata;
    b->pending = sd_bus_slot_unref(b->pending);
    const sd_bus_error *e = sd_bus_message_get_error(reply);
    if (e) return failed(b, "advertising", e), 0;
    b->registered = 2;
    emit(b, ELIS_BLUEZ_ADVERTISING, NULL);
    return 0;
}

static int application_registered(sd_bus_message *reply, void *userdata, sd_bus_error *unused) {
    elis_bluez *b = userdata;
    b->pending = sd_bus_slot_unref(b->pending);
    const sd_bus_error *e = sd_bus_message_get_error(reply);
    if (e) return failed(b, "service", e), 0;
    b->registered = 1;
    // BlueZ reads the advertisement back before it replies, so neither call can be a blocking one
    int r = sd_bus_call_method_async(b->bus, &b->pending, "org.bluez", b->adapter, "org.bluez.LEAdvertisingManager1",
                                     "RegisterAdvertisement", advertisement_registered, b, "oa{sv}", ADVERTISEMENT, 0);
    if (r < 0) failed(b, "advertising", NULL);
    return 0;
}

void elis_bluez_withdraw(elis_bluez *b) {
    // a registration still in flight finishes in BlueZ; its reply must not report the old UUID as live
    b->pending = sd_bus_slot_unref(b->pending);
    if (b->registered >= 2)
        sd_bus_call_method_async(b->bus, NULL, "org.bluez", b->adapter, "org.bluez.LEAdvertisingManager1",
                                 "UnregisterAdvertisement", NULL, NULL, "o", ADVERTISEMENT);
    if (b->registered >= 1)
        sd_bus_call_method_async(b->bus, NULL, "org.bluez", b->adapter, "org.bluez.GattManager1", "UnregisterApplication",
                                 NULL, NULL, "o", ROOT);
    b->registered = 0;
}

void elis_bluez_advertise(elis_bluez *b, const char *service_uuid, uint16_t psm) {
    elis_bluez_withdraw(b);
    snprintf(b->uuid, sizeof b->uuid, "%s", service_uuid);
    b->psm = psm;
    int r = sd_bus_call_method_async(b->bus, &b->pending, "org.bluez", b->adapter, "org.bluez.GattManager1",
                                     "RegisterApplication", application_registered, b, "oa{sv}", ROOT, 0);
    if (r < 0) failed(b, "service", NULL);
}

// MARK: L2CAP

int elis_l2cap_listen(uint16_t *psm) {
    int fd = socket(ELIS_AF_BLUETOOTH, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, ELIS_BTPROTO_L2CAP);
    if (fd < 0) return -1;
    struct elis_sockaddr_l2 address = {.l2_family = ELIS_AF_BLUETOOTH, .l2_bdaddr_type = ELIS_BDADDR_LE_PUBLIC};
    // the phone opens it with createInsecureL2capChannel; Noise keyed by the token secures the bytes
    struct elis_bt_security security = {.level = ELIS_BT_SECURITY_LOW};
    uint16_t mtu = 65535; // one SDU per recv, so the receive side takes the largest a phone may send
    socklen_t length = sizeof address;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) < 0
        || setsockopt(fd, ELIS_SOL_BLUETOOTH, ELIS_BT_SECURITY, &security, sizeof security) < 0
        || setsockopt(fd, ELIS_SOL_BLUETOOTH, ELIS_BT_RCVMTU, &mtu, sizeof mtu) < 0
        || listen(fd, 8) < 0
        || getsockname(fd, (struct sockaddr *)&address, &length) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    *psm = address.l2_psm; // little-endian on the wire and on every host Linux Elis runs on
    return fd;
}

int elis_l2cap_accept(int listener, int *send_mtu) {
    int fd = accept4(listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) return -1;
    uint16_t mtu = 0;
    socklen_t length = sizeof mtu;
    *send_mtu = getsockopt(fd, ELIS_SOL_BLUETOOTH, ELIS_BT_SNDMTU, &mtu, &length) == 0 && mtu > 0 ? mtu : 23;
    return fd;
}
