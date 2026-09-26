/* aeon_link: a byte stream between AeonDX (Android) and an ESP32-S3 over
 * Bluetooth LE -- the same bytes the board's USB serial carries, so a
 * firmware that speaks a serial protocol (GB-Link-Switch-LDN's, see
 * docs/SERIAL_PROTOCOL.md there) can take it over BLE unchanged.
 *
 * The GATT service (128-bit UUIDs, shown big-endian):
 *   service  8f2a0001-5b3c-4d7e-9a61-2c4e6f8a0b1d
 *   RX       8f2a0002-...  write / write without response: phone -> board
 *   TX       8f2a0003-...  notify: board -> phone, in MTU - 3 byte chunks
 *   INFO     8f2a0004-...  read: "aeonlink 1 <device name>"
 * The board advertises the service UUID (and its name in the scan response),
 * takes one connection at a time and advertises again when it drops.
 * AeonDX's side is android/FoldLink.java. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* bytes from the phone; called on the NimBLE host task, keep it short */
typedef void (*aeon_link_rx_cb)(const uint8_t* data, size_t len, void* user);

/* start Bluetooth, the service and advertising (NVS is set up if needed) */
int aeon_link_start(const char* device_name, aeon_link_rx_cb on_rx, void* user);

/* bytes to the phone (split to the connection's MTU); how many went out, 0
 * when no phone is connected / subscribed */
size_t aeon_link_send(const uint8_t* data, size_t len);

/* a phone is connected and listening */
int aeon_link_connected(void);

#ifdef __cplusplus
}
#endif
