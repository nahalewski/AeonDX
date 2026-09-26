#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "sd_card.h"
#include "gba_trade.h"
#include "web_server.h"

static const char *TAG = "aeondx_gba";

#define AP_SSID "AeonDX-GBALink"
#define AP_CHANNEL 1
#define AP_MAX_CONN 4

static void wifi_init_softap(void)
{
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    wifi_config_t wifi_config = {
        .ap = {
            .ssid = AP_SSID,
            .ssid_len = strlen(AP_SSID),
            .channel = AP_CHANNEL,
            .password = "",
            .max_connection = AP_MAX_CONN,
            .authmode = WIFI_AUTH_OPEN,
            .pmf_cfg = {
                .required = false,
            },
        },
    };

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "Wi-Fi SoftAP started. SSID: %s (Open)", AP_SSID);
    ESP_LOGI(TAG, "Web UI available at: http://192.168.4.1/");
}

void app_main(void)
{
    ESP_LOGI(TAG, "================================================");
    ESP_LOGI(TAG, "   AeonDX GBA Link Bridge (ESP32-S3 + SD Card)   ");
    ESP_LOGI(TAG, "================================================");

    // 1. Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // 2. Initialize TCP/IP stack and event loop
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    // 3. Mount SD Card
    ret = sd_card_init();
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "SD Card mounted successfully.");
    } else {
        ESP_LOGW(TAG, "SD Card not detected or failed to mount (%s). Using embedded defaults.", esp_err_to_name(ret));
    }

    // 4. Initialize GBA Trade State Machine & Party
    gba_trade_init();

    // 5. Start Wi-Fi SoftAP
    wifi_init_softap();

    // 6. Start HTTP Web Server
    ret = start_web_server();
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Web Server active. Access the Retro Battle/Trade UI at http://192.168.4.1");
    } else {
        ESP_LOGE(TAG, "Failed to start HTTP server!");
    }

    ESP_LOGI(TAG, "AeonDX GBA Link Ready: Connect device to '%s' and open http://192.168.4.1", AP_SSID);

    // Main loop
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}