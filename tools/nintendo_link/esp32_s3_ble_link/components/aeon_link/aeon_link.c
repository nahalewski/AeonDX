/* aeon_link: the byte stream over a NimBLE GATT service (see aeon_link.h). */
#include <string.h>

#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "aeon_link.h"

static const char* TAG = "aeon_link";

/* 8f2a000x-5b3c-4d7e-9a61-2c4e6f8a0b1d, little-endian for NimBLE */
#define AEON_UUID(x) BLE_UUID128_INIT(0x1d, 0x0b, 0x8a, 0x6f, 0x4e, 0x2c, 0x61, 0x9a, \
                                      0x7e, 0x4d, 0x3c, 0x5b, (x), 0x00, 0x2a, 0x8f)
static const ble_uuid128_t SVC_UUID = AEON_UUID(0x01);
static const ble_uuid128_t RX_UUID = AEON_UUID(0x02);
static const ble_uuid128_t TX_UUID = AEON_UUID(0x03);
static const ble_uuid128_t INFO_UUID = AEON_UUID(0x04);

static struct {
  aeon_link_rx_cb on_rx;
  void* user;
  char name[32];
  uint8_t own_addr_type;
  uint16_t conn;          /* BLE_HS_CONN_HANDLE_NONE when nobody */
  uint16_t tx_handle;
  uint16_t mtu;
  int subscribed;
} L = { .conn = BLE_HS_CONN_HANDLE_NONE, .mtu = 23 };

static void advertise(void);

static int access_cb(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt* ctxt, void* arg)
{
  (void)conn; (void)attr;
  const ble_uuid_t* uuid = ctxt->chr->uuid;
  if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && ble_uuid_cmp(uuid, &RX_UUID.u) == 0) {
    uint8_t buf[512];
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len > sizeof buf) len = sizeof buf;
    uint16_t got = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, len, &got) != 0) return BLE_ATT_ERR_UNLIKELY;
    if (L.on_rx && got) L.on_rx(buf, got, L.user);
    return 0;
  }
  if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR && ble_uuid_cmp(uuid, &INFO_UUID.u) == 0) {
    char info[64];
    int n = snprintf(info, sizeof info, "aeonlink 1 %s", L.name);
    return os_mbuf_append(ctxt->om, info, (uint16_t)n) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
  }
  (void)arg;
  return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def SERVICES[] = {
  {
    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = &SVC_UUID.u,
    .characteristics = (struct ble_gatt_chr_def[]) {
      { .uuid = &RX_UUID.u, .access_cb = access_cb,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP },
      { .uuid = &TX_UUID.u, .access_cb = access_cb, .val_handle = &L.tx_handle,
        .flags = BLE_GATT_CHR_F_NOTIFY },
      { .uuid = &INFO_UUID.u, .access_cb = access_cb, .flags = BLE_GATT_CHR_F_READ },
      { 0 },
    },
  },
  { 0 },
};

static int gap_event(struct ble_gap_event* e, void* arg)
{
  (void)arg;
  switch (e->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (e->connect.status == 0) {
        L.conn = e->connect.conn_handle;
        L.mtu = 23;
        L.subscribed = 0;
        ESP_LOGI(TAG, "phone connected");
      } else {
        advertise();
      }
      return 0;
    case BLE_GAP_EVENT_DISCONNECT:
      ESP_LOGI(TAG, "phone disconnected (%d)", e->disconnect.reason);
      L.conn = BLE_HS_CONN_HANDLE_NONE;
      L.subscribed = 0;
      advertise();
      return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
      if (e->subscribe.attr_handle == L.tx_handle) L.subscribed = e->subscribe.cur_notify;
      return 0;
    case BLE_GAP_EVENT_MTU:
      L.mtu = e->mtu.value;
      ESP_LOGI(TAG, "mtu %u", L.mtu);
      return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
      advertise();
      return 0;
    default:
      return 0;
  }
}

static void advertise(void)
{
  struct ble_hs_adv_fields adv;
  memset(&adv, 0, sizeof adv);
  adv.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
  adv.uuids128 = &SVC_UUID;
  adv.num_uuids128 = 1;
  adv.uuids128_is_complete = 1;
  int rc = ble_gap_adv_set_fields(&adv);
  if (rc) { ESP_LOGE(TAG, "adv fields %d", rc); return; }
  struct ble_hs_adv_fields rsp;
  memset(&rsp, 0, sizeof rsp);
  rsp.name = (const uint8_t*)L.name;
  rsp.name_len = (uint8_t)strlen(L.name);
  rsp.name_is_complete = 1;
  ble_gap_adv_rsp_set_fields(&rsp);
  struct ble_gap_adv_params p;
  memset(&p, 0, sizeof p);
  p.conn_mode = BLE_GAP_CONN_MODE_UND;
  p.disc_mode = BLE_GAP_DISC_MODE_GEN;
  rc = ble_gap_adv_start(L.own_addr_type, NULL, BLE_HS_FOREVER, &p, gap_event, NULL);
  if (rc && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "adv start %d", rc);
}

static void on_sync(void)
{
  ble_hs_util_ensure_addr(0);
  ble_hs_id_infer_auto(0, &L.own_addr_type);
  advertise();
}

static void on_reset(int reason) { ESP_LOGW(TAG, "host reset %d", reason); }

static void host_task(void* param)
{
  (void)param;
  nimble_port_run();
  nimble_port_freertos_deinit();
}

int aeon_link_start(const char* device_name, aeon_link_rx_cb on_rx, void* user)
{
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    err = nvs_flash_init();
  }
  if (err != ESP_OK) return err;
  L.on_rx = on_rx;
  L.user = user;
  snprintf(L.name, sizeof L.name, "%s", device_name ? device_name : "AeonDX Link");
  err = nimble_port_init();
  if (err != ESP_OK) return err;
  ble_hs_cfg.sync_cb = on_sync;
  ble_hs_cfg.reset_cb = on_reset;
  ble_svc_gap_init();
  ble_svc_gatt_init();
  int rc = ble_gatts_count_cfg(SERVICES);
  if (rc == 0) rc = ble_gatts_add_svcs(SERVICES);
  if (rc) return rc;
  ble_svc_gap_device_name_set(L.name);
  nimble_port_freertos_init(host_task);
  return 0;
}

int aeon_link_connected(void) { return L.conn != BLE_HS_CONN_HANDLE_NONE && L.subscribed; }

size_t aeon_link_send(const uint8_t* data, size_t len)
{
  if (!aeon_link_connected() || !data) return 0;
  size_t chunk = L.mtu > 3 ? (size_t)L.mtu - 3 : 20;
  size_t sent = 0;
  while (sent < len) {
    size_t n = len - sent < chunk ? len - sent : chunk;
    struct os_mbuf* om = ble_hs_mbuf_from_flat(data + sent, (uint16_t)n);
    if (!om) break;
    if (ble_gatts_notify_custom(L.conn, L.tx_handle, om) != 0) break;
    sent += n;
  }
  return sent;
}
