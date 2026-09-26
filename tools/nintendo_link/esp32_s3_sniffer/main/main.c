#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define DWELL_TIME_MS 5000
#define MANAGEMENT_HEADER_LEN 24

static const uint8_t scan_channels[] = {1, 6, 11};

typedef struct {
    uint32_t management_frames;
    uint32_t action_frames;
    uint32_t nintendo_frames;
    int last_rssi;
    uint8_t last_source[6];
} channel_stats_t;

static channel_stats_t stats[sizeof(scan_channels) / sizeof(scan_channels[0])];
static portMUX_TYPE stats_mux = portMUX_INITIALIZER_UNLOCKED;

static int channel_index(uint8_t channel)
{
    for (size_t i = 0; i < sizeof(scan_channels) / sizeof(scan_channels[0]); i++) {
        if (scan_channels[i] == channel) return (int)i;
    }
    return -1;
}

static bool has_nintendo_oui(const uint8_t *frame, size_t length)
{
    static const uint8_t nintendo_oui[] = {0x00, 0x22, 0xaa};
    const size_t action_body_offset = MANAGEMENT_HEADER_LEN;

    return length >= action_body_offset + 4 &&
           frame[action_body_offset] == 127 &&
           memcmp(frame + action_body_offset + 1, nintendo_oui,
                  sizeof(nintendo_oui)) == 0;
}

static void promiscuous_rx(void *buffer, wifi_promiscuous_pkt_type_t packet_type)
{
    if (packet_type != WIFI_PKT_MGMT || buffer == NULL) return;

    const wifi_promiscuous_pkt_t *packet = (const wifi_promiscuous_pkt_t *)buffer;
    const uint8_t *frame = packet->payload;
    const size_t length = packet->rx_ctrl.sig_len;
    if (length < MANAGEMENT_HEADER_LEN) return;

    const uint16_t frame_control = (uint16_t)frame[0] | ((uint16_t)frame[1] << 8);
    const uint8_t frame_type = (frame_control >> 2) & 0x03;
    const uint8_t frame_subtype = (frame_control >> 4) & 0x0f;
    if (frame_type != 0) return;

    const int index = channel_index(packet->rx_ctrl.channel);
    if (index < 0) return;

    const bool is_action = frame_subtype == 13;
    const bool is_nintendo = is_action && has_nintendo_oui(frame, length);

    taskENTER_CRITICAL(&stats_mux);
    stats[index].management_frames++;
    if (is_action) stats[index].action_frames++;
    if (is_nintendo) {
        stats[index].nintendo_frames++;
        stats[index].last_rssi = packet->rx_ctrl.rssi;
        memcpy(stats[index].last_source, frame + 10, sizeof(stats[index].last_source));
    }
    taskEXIT_CRITICAL(&stats_mux);
}

static channel_stats_t take_channel_stats(int index)
{
    channel_stats_t snapshot;

    taskENTER_CRITICAL(&stats_mux);
    snapshot = stats[index];
    memset(&stats[index], 0, sizeof(stats[index]));
    taskEXIT_CRITICAL(&stats_mux);
    return snapshot;
}

void app_main(void)
{
    esp_err_t nvs_result = nvs_flash_init();
    if (nvs_result == ESP_ERR_NVS_NO_FREE_PAGES ||
        nvs_result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        nvs_result = nvs_flash_init();
    }
    ESP_ERROR_CHECK(nvs_result);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_config));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_NULL));
    ESP_ERROR_CHECK(esp_wifi_start());

    wifi_promiscuous_filter_t filter = {
        .filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT,
    };
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous_filter(&filter));
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous_rx_cb(promiscuous_rx));
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous(true));

    printf("AeonDX LDN sniffer: ESP32-S3, 2.4 GHz, receive-only\n");
    printf("Watching channels 1, 6, and 11; dwell %u ms each\n", DWELL_TIME_MS);

    while (true) {
        for (int i = 0; i < (int)(sizeof(scan_channels) / sizeof(scan_channels[0])); i++) {
            const uint8_t channel = scan_channels[i];
            ESP_ERROR_CHECK(esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE));
            vTaskDelay(pdMS_TO_TICKS(DWELL_TIME_MS));

            const channel_stats_t sample = take_channel_stats(i);
            printf("ch %u: mgmt=%lu action=%lu Nintendo-OUI=%lu",
                   channel,
                   (unsigned long)sample.management_frames,
                   (unsigned long)sample.action_frames,
                   (unsigned long)sample.nintendo_frames);
            if (sample.nintendo_frames > 0) {
                printf(" last-src=%02x:%02x:%02x:%02x:%02x:%02x rssi=%d dBm",
                       sample.last_source[0], sample.last_source[1],
                       sample.last_source[2], sample.last_source[3],
                       sample.last_source[4], sample.last_source[5],
                       sample.last_rssi);
            }
            printf("\n");
        }
    }
}