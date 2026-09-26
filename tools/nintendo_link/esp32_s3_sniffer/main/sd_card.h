#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SD_MOUNT_POINT "/sdcard"

/**
 * @brief Initialize SD card in SPI/SDMMC mode and mount FAT filesystem at /sdcard
 * @return ESP_OK if mounted, or error code
 */
esp_err_t sd_card_init(void);

/**
 * @brief Check if SD card is currently mounted
 */
bool sd_card_is_mounted(void);

/**
 * @brief List .sav save files in /sdcard/saves directory
 * @param json_buf Output buffer to write JSON array: [{"name":"x.sav","size":131072}, ...]
 * @param max_len Size of json_buf
 * @return ESP_OK on success
 */
esp_err_t sd_card_list_saves(char *json_buf, size_t max_len);

/**
 * @brief Open a save file from /sdcard/saves
 * @param filename File name (e.g. "Pokemon_FireRed.sav")
 * @return FILE pointer or NULL
 */
FILE* sd_card_open_save(const char *filename);

#ifdef __cplusplus
}
#endif
