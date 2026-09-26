#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    GBA_TRADE_STATE_IDLE = 0,
    GBA_TRADE_STATE_CONNECTED,
    GBA_TRADE_STATE_OFFERED,
    GBA_TRADE_STATE_CONFIRMED,
    GBA_TRADE_STATE_TRADING,
    GBA_TRADE_STATE_COMPLETE,
    GBA_TRADE_STATE_CANCELLED
} gba_trade_state_t;

typedef struct {
    char name[16];
    uint16_t species;
    uint8_t level;
    uint16_t hp;
    uint16_t max_hp;
    char item[24];
    char moves[4][24];
    char ot_name[16];
    uint32_t ot_id;
} pokemon_summary_t;

typedef struct {
    uint8_t count;
    pokemon_summary_t members[6];
} gba_party_t;

typedef struct {
    gba_trade_state_t phase;
    int8_t offered_slot;
    char partner_name[32];
    char partner_species[32];
    uint8_t partner_level;
    uint8_t partner_hp_pct;
    char current_save[64];
    bool gba_link_active;
} gba_trade_status_t;

/**
 * @brief Initialize GBA trading state machine and default team
 */
void gba_trade_init(void);

/**
 * @brief Get current trade status snapshot
 */
gba_trade_status_t gba_trade_get_status(void);

/**
 * @brief Get active party buffer
 */
const gba_party_t* gba_trade_get_party(void);

/**
 * @brief Offer a party member for trade (FIGHT / OFFER action)
 * @param slot 0-5 index in party
 */
esp_err_t gba_trade_offer(uint8_t slot);

/**
 * @brief Confirm proposed trade
 */
esp_err_t gba_trade_confirm(void);

/**
 * @brief Cancel trade proposal or reset (RUN / CANCEL action)
 */
esp_err_t gba_trade_cancel(void);

/**
 * @brief Load party from a GBA .sav save file on SD card
 * @param filename File name located in /sdcard/saves/
 */
esp_err_t gba_trade_load_save(const char *filename);

/**
 * @brief Helper to convert Gen 3 character encoding to standard ASCII string
 */
void gba_charset_to_ascii(const uint8_t *src, char *dst, size_t max_len);

#ifdef __cplusplus
}
#endif
