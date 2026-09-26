# AeonDX Link: ESP32-S3 over Bluetooth LE

A GATT service that carries a byte stream between AeonDX and an ESP32-S3,
the same bytes the board's USB serial carries. A serial protocol (such as
GB-Link-Switch-LDN's) can then run over BLE as well as over USB-OTG.

| | UUID | |
|---|---|---|
| service | `8f2a0001-5b3c-4d7e-9a61-2c4e6f8a0b1d` | advertised; the name is in the scan response |
| RX | `8f2a0002-5b3c-4d7e-9a61-2c4e6f8a0b1d` | write / write without response: phone to board |
| TX | `8f2a0003-5b3c-4d7e-9a61-2c4e6f8a0b1d` | notify: board to phone, split to the MTU (up to 514 bytes a packet) |
| INFO | `8f2a0004-5b3c-4d7e-9a61-2c4e6f8a0b1d` | read: `aeonlink 1 <name>` |

The phone asks for a 517-byte MTU once it connects. The board takes one
phone at a time and advertises again when it disconnects. AeonDX's side is
`android/FoldLink.java` (bridge calls `link.*`). It speaks to the board
either over USB (CDC-ACM or USB Serial/JTAG) or over this service, and
offers the same stream both ways.

## Build and flash

```
idf.py set-target esp32s3
idf.py build
idf.py -p COMx flash monitor
```

`.github/workflows/esp32.yml` builds it (ESP-IDF v5.3) on every change.

## Using it in another firmware

Copy `components/aeon_link` into the firmware's `components/`, then:

1. Call `aeon_link_start("AeonDX Link", on_rx, NULL)` at start-up.
2. In `on_rx`, push the bytes into the same parser the USB serial bytes
   go to.
3. Where the firmware writes to the USB serial, also call
   `aeon_link_send(data, len)`. It does nothing while no phone is subscribed.

Wi-Fi and Bluetooth share the ESP32-S3's radio. Keep
`CONFIG_ESP_COEX_SW_COEXIST_ENABLE` on when the firmware also uses Wi-Fi
(the LDN bridge does), and test throughput with both running.

`main/main.c` flashed on its own bridges BLE to the board's USB
Serial/JTAG port. Anything sent from a PC terminal reaches the phone, and
the other way round, which makes it an easy way to test the service.
