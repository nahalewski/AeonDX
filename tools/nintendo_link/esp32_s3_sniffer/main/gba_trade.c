#include "gba_trade.h"
#include "sd_card.h"
#include <string.h>
#include <stdlib.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "gba_trade";

static gba_party_t s_party;
static gba_trade_status_t s_status;
static SemaphoreHandle_t s_trade_mutex = NULL;

void gba_charset_to_ascii(const uint8_t *src, char *dst, size_t max_len)
{
    if (!src || !dst || max_len == 0) return;

    size_t d = 0;
    for (size_t i = 0; i < max_len - 1; i++) {
        uint8_t c = src[i];
        if (c == 0xFF) break; // End of string in Gen 3
        if (c == 0x00) {
            dst[d++] = ' ';
        } else if (c >= 0xA1 && c <= 0xAA) {
            dst[d++] = '0' + (c - 0xA1);
        } else if (c >= 0xBB && c <= 0xD4) {
            dst[d++] = 'A' + (c - 0xBB);
        } else if (c >= 0xD5 && c <= 0xEE) {
            dst[d++] = 'a' + (c - 0xD5);
        } else if (c == 0xAB) {
            dst[d++] = '!';
        } else if (c == 0xAC) {
            dst[d++] = '?';
        } else if (c == 0xAD) {
            dst[d++] = '.';
        } else if (c == 0xAE) {
            dst[d++] = '-';
        } else {
            dst[d++] = '?';
        }
    }
    dst[d] = '\0';
}

static void init_default_party(void)
{
    s_party.count = 6;

    // Slot 0: CHARIZARD
    strncpy(s_party.members[0].name, "CHARIZARD", sizeof(s_party.members[0].name));
    s_party.members[0].species = 6;
    s_party.members[0].level = 50;
    s_party.members[0].hp = 153;
    s_party.members[0].max_hp = 153;
    strncpy(s_party.members[0].item, "Leftovers", sizeof(s_party.members[0].item));
    strncpy(s_party.members[0].moves[0], "Flamethrower", 24);
    strncpy(s_party.members[0].moves[1], "Wing Attack", 24);
    strncpy(s_party.members[0].moves[2], "Slash", 24);
    strncpy(s_party.members[0].moves[3], "Dragon Claw", 24);
    strncpy(s_party.members[0].ot_name, "RED", 16);
    s_party.members[0].ot_id = 12345;

    // Slot 1: PIKACHU
    strncpy(s_party.members[1].name, "PIKACHU", sizeof(s_party.members[1].name));
    s_party.members[1].species = 25;
    s_party.members[1].level = 48;
    s_party.members[1].hp = 110;
    s_party.members[1].max_hp = 110;
    strncpy(s_party.members[1].item, "Light Ball", sizeof(s_party.members[1].item));
    strncpy(s_party.members[1].moves[0], "Thunderbolt", 24);
    strncpy(s_party.members[1].moves[1], "Quick Attack", 24);
    strncpy(s_party.members[1].moves[2], "Iron Tail", 24);
    strncpy(s_party.members[1].moves[3], "Thunder Wave", 24);
    strncpy(s_party.members[1].ot_name, "RED", 16);
    s_party.members[1].ot_id = 12345;

    // Slot 2: BLASTOISE
    strncpy(s_party.members[2].name, "BLASTOISE", sizeof(s_party.members[2].name));
    s_party.members[2].species = 9;
    s_party.members[2].level = 52;
    s_party.members[2].hp = 165;
    s_party.members[2].max_hp = 165;
    strncpy(s_party.members[2].item, "Mystic Water", sizeof(s_party.members[2].item));
    strncpy(s_party.members[2].moves[0], "Surf", 24);
    strncpy(s_party.members[2].moves[1], "Ice Beam", 24);
    strncpy(s_party.members[2].moves[2], "Bite", 24);
    strncpy(s_party.members[2].moves[3], "Hydro Pump", 24);
    strncpy(s_party.members[2].ot_name, "RED", 16);
    s_party.members[2].ot_id = 12345;

    // Slot 3: VENUSAUR
    strncpy(s_party.members[3].name, "VENUSAUR", sizeof(s_party.members[3].name));
    s_party.members[3].species = 3;
    s_party.members[3].level = 50;
    s_party.members[3].hp = 155;
    s_party.members[3].max_hp = 155;
    strncpy(s_party.members[3].item, "Miracle Seed", sizeof(s_party.members[3].item));
    strncpy(s_party.members[3].moves[0], "Solar Beam", 24);
    strncpy(s_party.members[3].moves[1], "Sludge Bomb", 24);
    strncpy(s_party.members[3].moves[2], "Sleep Powder", 24);
    strncpy(s_party.members[3].moves[3], "Synthesis", 24);
    strncpy(s_party.members[3].ot_name, "RED", 16);
    s_party.members[3].ot_id = 12345;

    // Slot 4: SNORLAX
    strncpy(s_party.members[4].name, "SNORLAX", sizeof(s_party.members[4].name));
    s_party.members[4].species = 143;
    s_party.members[4].level = 55;
    s_party.members[4].hp = 220;
    s_party.members[4].max_hp = 220;
    strncpy(s_party.members[4].item, "Chesto Berry", sizeof(s_party.members[4].item));
    strncpy(s_party.members[4].moves[0], "Body Slam", 24);
    strncpy(s_party.members[4].moves[1], "Rest", 24);
    strncpy(s_party.members[4].moves[2], "Shadow Ball", 24);
    strncpy(s_party.members[4].moves[3], "Earthquake", 24);
    strncpy(s_party.members[4].ot_name, "RED", 16);
    s_party.members[4].ot_id = 12345;

    // Slot 5: DRATINI
    strncpy(s_party.members[5].name, "DRATINI", sizeof(s_party.members[5].name));
    s_party.members[5].species = 147;
    s_party.members[5].level = 25;
    s_party.members[5].hp = 65;
    s_party.members[5].max_hp = 65;
    strncpy(s_party.members[5].item, "Dragon Scale", sizeof(s_party.members[5].item));
    strncpy(s_party.members[5].moves[0], "Dragon Rage", 24);
    strncpy(s_party.members[5].moves[1], "Thunder Wave", 24);
    strncpy(s_party.members[5].moves[2], "Twister", 24);
    strncpy(s_party.members[5].moves[3], "Slam", 24);
    strncpy(s_party.members[5].ot_name, "RED", 16);
    s_party.members[5].ot_id = 12345;
}

void gba_trade_init(void)
{
    if (!s_trade_mutex) {
        s_trade_mutex = xSemaphoreCreateMutex();
    }

    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    init_default_party();

    s_status.phase = GBA_TRADE_STATE_IDLE;
    s_status.offered_slot = -1;
    strncpy(s_status.partner_name, "SWITCH 2", sizeof(s_status.partner_name));
    strncpy(s_status.partner_species, "KORAIDON", sizeof(s_status.partner_species));
    s_status.partner_level = 50;
    s_status.partner_hp_pct = 100;
    strncpy(s_status.current_save, "Pokemon_FireRed.sav", sizeof(s_status.current_save));
    s_status.gba_link_active = true;

    xSemaphoreGive(s_trade_mutex);
    ESP_LOGI(TAG, "GBA trade engine initialized.");
}

gba_trade_status_t gba_trade_get_status(void)
{
    gba_trade_status_t copy;
    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    copy = s_status;
    xSemaphoreGive(s_trade_mutex);
    return copy;
}

const gba_party_t* gba_trade_get_party(void)
{
    return &s_party;
}

esp_err_t gba_trade_offer(uint8_t slot)
{
    if (slot >= s_party.count) return ESP_ERR_INVALID_ARG;

    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    s_status.offered_slot = (int8_t)slot;
    s_status.phase = GBA_TRADE_STATE_OFFERED;
    ESP_LOGI(TAG, "Trade proposal: Offered slot %u (%s)", slot, s_party.members[slot].name);
    xSemaphoreGive(s_trade_mutex);

    return ESP_OK;
}

esp_err_t gba_trade_confirm(void)
{
    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    if (s_status.phase == GBA_TRADE_STATE_OFFERED) {
        s_status.phase = GBA_TRADE_STATE_CONFIRMED;
        ESP_LOGI(TAG, "Trade confirmed by both parties. Executing trade sequence...");
    }
    xSemaphoreGive(s_trade_mutex);
    return ESP_OK;
}

esp_err_t gba_trade_cancel(void)
{
    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    s_status.offered_slot = -1;
    s_status.phase = GBA_TRADE_STATE_IDLE;
    ESP_LOGI(TAG, "Trade cancelled / reset to IDLE.");
    xSemaphoreGive(s_trade_mutex);
    return ESP_OK;
}

esp_err_t gba_trade_load_save(const char *filename)
{
    if (!filename) return ESP_ERR_INVALID_ARG;

    ESP_LOGI(TAG, "Attempting to load GBA save: %s", filename);
    FILE *f = sd_card_open_save(filename);
    if (!f) {
        ESP_LOGW(TAG, "Could not open save file %s from SD card; updating active file designation.", filename);
        xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
        strncpy(s_status.current_save, filename, sizeof(s_status.current_save));
        xSemaphoreGive(s_trade_mutex);
        return ESP_OK;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (size >= 131072) {
        // Parse Gen 3 Save Sectors
        // Find Sector 1 of the active save slot
        uint32_t best_counter = 0;
        long best_sector1_offset = -1;

        // Slot A: 0..13 (0x00000 to 0x0E000), Slot B: 14..27 (0x0E000 to 0x1C000)
        for (int i = 0; i < 28; i++) {
            long sector_offset = i * 4096;
            fseek(f, sector_offset + 4096 - 16, SEEK_SET);
            uint8_t footer[16];
            if (fread(footer, 1, 16, f) == 16) {
                uint16_t sector_id = footer[4] | (footer[5] << 8); // sector ID is at footer offset 4 in standard Gen 3
                uint32_t counter = footer[12] | (footer[13] << 8) | (footer[14] << 16) | (footer[15] << 24);
                if (sector_id == 1 && counter >= best_counter) {
                    best_counter = counter;
                    best_sector1_offset = sector_offset;
                }
            }
        }

        if (best_sector1_offset >= 0) {
            ESP_LOGI(TAG, "Located active Gen 3 Sector 1 at offset 0x%lx (counter: %lu)", best_sector1_offset, (unsigned long)best_counter);
            // In FRLG, team count is at sector + 0x034
            fseek(f, best_sector1_offset + 0x034, SEEK_SET);
            uint32_t team_count = 0;
            if (fread(&team_count, 1, 4, f) == 4 && team_count >= 1 && team_count <= 6) {
                xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
                s_party.count = team_count;
                for (uint32_t s = 0; s < team_count; s++) {
                    uint8_t mon_buf[100];
                    if (fread(mon_buf, 1, 100, f) == 100) {
                        // mon_buf contains unencrypted or decrypted Gen 3 party struct
                        // Nickname is at offset 8 (10 bytes)
                        char nick[16];
                        gba_charset_to_ascii(mon_buf + 8, nick, 11);
                        if (strlen(nick) > 0) {
                            strncpy(s_party.members[s].name, nick, sizeof(s_party.members[s].name));
                        }
                        // Level is at offset 84
                        s_party.members[s].level = mon_buf[84] ? mon_buf[84] : 50;
                        // Current HP is at offset 86, Max HP is at offset 88
                        uint16_t cur_hp = mon_buf[86] | (mon_buf[87] << 8);
                        uint16_t max_hp = mon_buf[88] | (mon_buf[89] << 8);
                        if (max_hp > 0) {
                            s_party.members[s].hp = cur_hp;
                            s_party.members[s].max_hp = max_hp;
                        }
                    }
                }
                xSemaphoreGive(s_trade_mutex);
                ESP_LOGI(TAG, "Successfully extracted %lu Pokemon from save file %s!", (unsigned long)team_count, filename);
            }
        }
    }

    fclose(f);

    xSemaphoreTake(s_trade_mutex, portMAX_DELAY);
    strncpy(s_status.current_save, filename, sizeof(s_status.current_save));
    xSemaphoreGive(s_trade_mutex);

    return ESP_OK;
}
