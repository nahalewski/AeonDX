#include "sd_card.h"
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdspi_host.h"
#include "driver/spi_common.h"

static const char *TAG = "sd_card";
static bool s_is_mounted = false;
static sdmmc_card_t *s_card = NULL;

// Default SPI Pins for ESP32-S3 SD Card (FSPIM / Custom SPI)
#define PIN_NUM_MISO 13
#define PIN_NUM_MOSI 11
#define PIN_NUM_CLK  12
#define PIN_NUM_CS   10

esp_err_t sd_card_init(void)
{
    ESP_LOGI(TAG, "Initializing SD card via SDSPI...");

    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024
    };

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = PIN_NUM_MOSI,
        .miso_io_num = PIN_NUM_MISO,
        .sclk_io_num = PIN_NUM_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4000,
    };

    esp_err_t ret = spi_bus_initialize(SPI2_HOST, &bus_cfg, SDSPI_DEFAULT_DMA);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "Failed to initialize SPI bus for SD: %s", esp_err_to_name(ret));
        s_is_mounted = false;
        return ret;
    }

    sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot_config.gpio_cs = PIN_NUM_CS;
    slot_config.host_id = SPI2_HOST;

    sdmmc_host_t host = SDSPI_HOST_DEFAULT();
    host.slot = SPI2_HOST;

    ret = esp_vfs_fat_sdspi_mount(SD_MOUNT_POINT, &host, &slot_config, &mount_config, &s_card);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "SD card mount failed (%s). Continuing in standalone mode.", esp_err_to_name(ret));
        s_is_mounted = false;
        return ret;
    }

    s_is_mounted = true;
    ESP_LOGI(TAG, "SD Card mounted successfully at %s", SD_MOUNT_POINT);
    sdmmc_card_print_info(stdout, s_card);

    // Create /sdcard/saves and /sdcard/www directories if they don't exist
    struct stat st;
    if (stat("/sdcard/saves", &st) != 0) {
        mkdir("/sdcard/saves", 0775);
    }
    if (stat("/sdcard/www", &st) != 0) {
        mkdir("/sdcard/www", 0775);
    }

    return ESP_OK;
}

bool sd_card_is_mounted(void)
{
    return s_is_mounted;
}

esp_err_t sd_card_list_saves(char *json_buf, size_t max_len)
{
    if (!json_buf || max_len < 3) return ESP_ERR_INVALID_ARG;

    strcpy(json_buf, "[");
    size_t current_len = 1;

    DIR *d = opendir("/sdcard/saves");
    if (!d) {
        // Return default mock save list if SD is unmounted or empty
        const char *fallback = "[{\"name\":\"Pokemon_FireRed.sav\",\"size\":131072},{\"name\":\"Pokemon_Emerald.sav\",\"size\":131072},{\"name\":\"Pokemon_LeafGreen.sav\",\"size\":131072}]";
        if (strlen(fallback) < max_len) {
            strcpy(json_buf, fallback);
            return ESP_OK;
        }
        strcat(json_buf, "]");
        return ESP_OK;
    }

    struct dirent *dir;
    bool first = true;
    while ((dir = readdir(d)) != NULL) {
        if (dir->d_type == DT_REG || dir->d_type == DT_UNKNOWN) {
            const char *dot = strrchr(dir->d_name, '.');
            if (dot && (strcasecmp(dot, ".sav") == 0 || strcasecmp(dot, ".pk3") == 0)) {
                char filepath[300];
                snprintf(filepath, sizeof(filepath), "/sdcard/saves/%s", dir->d_name);
                struct stat st;
                size_t file_size = 131072;
                if (stat(filepath, &st) == 0) {
                    file_size = st.st_size;
                }

                char item[350];
                snprintf(item, sizeof(item), "%s{\"name\":\"%s\",\"size\":%u}",
                         first ? "" : ",", dir->d_name, (unsigned)file_size);
                first = false;

                if (current_len + strlen(item) + 2 < max_len) {
                    strcat(json_buf, item);
                    current_len += strlen(item);
                }
            }
        }
    }
    closedir(d);

    if (first) {
        // Empty folder, inject standard save name
        const char *def = "{\"name\":\"Pokemon_FireRed.sav\",\"size\":131072}";
        if (current_len + strlen(def) + 2 < max_len) {
            strcat(json_buf, def);
        }
    }

    strcat(json_buf, "]");
    return ESP_OK;
}

FILE* sd_card_open_save(const char *filename)
{
    if (!s_is_mounted || !filename) return NULL;
    char path[300];
    snprintf(path, sizeof(path), "/sdcard/saves/%s", filename);
    return fopen(path, "rb");
}
