/* AeonDX Link: the phone over Bluetooth LE (aeon_link) bridged to the
 * ESP32-S3's own USB serial (USB Serial/JTAG), both ways.  Flashed on its
 * own it lets AeonDX reach whatever is on the board's USB side over BLE, and
 * shows the GATT service working; in a firmware that already speaks a serial
 * protocol (GB-Link-Switch-LDN), feed aeon_link's bytes into the same parser
 * the USB bytes go to and send replies with aeon_link_send as well (see
 * ../README.md). */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"

#include "aeon_link.h"

static const char* TAG = "aeonlink";

/* phone -> USB */
static void from_phone(const uint8_t* data, size_t len, void* user)
{
  (void)user;
  usb_serial_jtag_write_bytes(data, len, pdMS_TO_TICKS(20));
}

/* USB -> phone */
static void usb_task(void* arg)
{
  (void)arg;
  uint8_t buf[512];
  for (;;) {
    int n = usb_serial_jtag_read_bytes(buf, sizeof buf, pdMS_TO_TICKS(10));
    if (n > 0) aeon_link_send(buf, (size_t)n);
  }
}

void app_main(void)
{
  usb_serial_jtag_driver_config_t cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&cfg));
  int rc = aeon_link_start("AeonDX Link", from_phone, NULL);
  if (rc) ESP_LOGE(TAG, "BLE start failed: %d", rc);
  xTaskCreate(usb_task, "usb", 4096, NULL, 5, NULL);
}
