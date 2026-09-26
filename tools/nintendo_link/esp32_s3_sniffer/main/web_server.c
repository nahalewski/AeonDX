#include "web_server.h"
#include "sd_card.h"
#include "gba_trade.h"
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "esp_log.h"
#include "esp_http_server.h"

static const char *TAG = "web_server";
static httpd_handle_t s_server = NULL;

// Embedded Web UI symbols (fallback when not loaded from SD)
extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[]   asm("_binary_index_html_end");
extern const uint8_t style_css_start[]  asm("_binary_style_css_start");
extern const uint8_t style_css_end[]    asm("_binary_style_css_end");
extern const uint8_t app_js_start[]     asm("_binary_app_js_start");
extern const uint8_t app_js_end[]       asm("_binary_app_js_end");

static esp_err_t serve_file_or_embed(httpd_req_t *req, const char *sd_path, const uint8_t *embed_start, const uint8_t *embed_end, const char *content_type)
{
    httpd_resp_set_type(req, content_type);
    httpd_resp_set_hdr(req, "Cache-Control", "no-cache");

    struct stat st;
    if (stat(sd_path, &st) == 0 && st.st_size > 0) {
        FILE *f = fopen(sd_path, "r");
        if (f) {
            char chunk[1024];
            size_t bytes_read;
            while ((bytes_read = fread(chunk, 1, sizeof(chunk), f)) > 0) {
                if (httpd_resp_send_chunk(req, chunk, bytes_read) != ESP_OK) {
                    fclose(f);
                    return ESP_FAIL;
                }
            }
            fclose(f);
            return httpd_resp_send_chunk(req, NULL, 0);
        }
    }

    // Serve embedded asset
    const size_t size = embed_end - embed_start;
    return httpd_resp_send(req, (const char *)embed_start, size);
}

// GET /
static esp_err_t index_handler(httpd_req_t *req)
{
    return serve_file_or_embed(req, "/sdcard/www/index.html", index_html_start, index_html_end, "text/html");
}

// GET /style.css
static esp_err_t style_handler(httpd_req_t *req)
{
    return serve_file_or_embed(req, "/sdcard/www/style.css", style_css_start, style_css_end, "text/css");
}

// GET /app.js
static esp_err_t js_handler(httpd_req_t *req)
{
    return serve_file_or_embed(req, "/sdcard/www/app.js", app_js_start, app_js_end, "application/javascript");
}

// GET /api/status
static esp_err_t api_status_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    gba_trade_status_t status = gba_trade_get_status();
    const char *phase_str = "IDLE";
    switch (status.phase) {
        case GBA_TRADE_STATE_OFFERED: phase_str = "OFFERED"; break;
        case GBA_TRADE_STATE_CONFIRMED: phase_str = "CONFIRMED"; break;
        case GBA_TRADE_STATE_TRADING: phase_str = "TRADING"; break;
        case GBA_TRADE_STATE_COMPLETE: phase_str = "COMPLETE"; break;
        case GBA_TRADE_STATE_CANCELLED: phase_str = "CANCELLED"; break;
        default: phase_str = "IDLE"; break;
    }

    char json[512];
    snprintf(json, sizeof(json),
        "{\"connected\":%s,\"trade_phase\":\"%s\",\"offered_slot\":%d,"
        "\"partner_name\":\"%s\",\"partner_level\":%u,\"partner_hp\":%u,"
        "\"sd_mounted\":%s,\"sd_save\":\"%s\"}",
        status.gba_link_active ? "true" : "false",
        phase_str,
        (int)status.offered_slot,
        status.partner_name,
        (unsigned)status.partner_level,
        (unsigned)status.partner_hp_pct,
        sd_card_is_mounted() ? "true" : "false",
        status.current_save
    );

    return httpd_resp_send(req, json, strlen(json));
}

// GET /api/party
static esp_err_t api_party_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    const gba_party_t *party = gba_trade_get_party();
    char json[2048];
    snprintf(json, sizeof(json), "{\"count\":%u,\"party\":[", (unsigned)party->count);

    for (uint8_t i = 0; i < party->count; i++) {
        const pokemon_summary_t *p = &party->members[i];
        char mon_json[350];
        snprintf(mon_json, sizeof(mon_json),
            "%s{\"name\":\"%s\",\"level\":%u,\"hp\":%u,\"maxHp\":%u,\"species\":%u,\"item\":\"%s\","
            "\"moves\":[\"%s\",\"%s\",\"%s\",\"%s\"]}",
            i == 0 ? "" : ",",
            p->name, (unsigned)p->level, (unsigned)p->hp, (unsigned)p->max_hp,
            (unsigned)p->species, p->item,
            p->moves[0], p->moves[1], p->moves[2], p->moves[3]
        );
        strcat(json, mon_json);
    }
    strcat(json, "]}");

    return httpd_resp_send(req, json, strlen(json));
}

// POST /api/trade/offer
static esp_err_t api_trade_offer_handler(httpd_req_t *req)
{
    char buf[128];
    int ret = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (ret <= 0) return ESP_FAIL;
    buf[ret] = '\0';

    uint8_t slot = 0;
    char *p = strstr(buf, "\"slot\"");
    if (p) {
        char *colon = strchr(p, ':');
        if (colon) {
            slot = (uint8_t)atoi(colon + 1);
        }
    }

    gba_trade_offer(slot);

    httpd_resp_set_type(req, "application/json");
    const char *resp = "{\"success\":true,\"message\":\"Trade proposal sent!\"}";
    return httpd_resp_send(req, resp, strlen(resp));
}

// POST /api/trade/cancel
static esp_err_t api_trade_cancel_handler(httpd_req_t *req)
{
    gba_trade_cancel();
    httpd_resp_set_type(req, "application/json");
    const char *resp = "{\"success\":true,\"message\":\"Trade proposal cancelled.\"}";
    return httpd_resp_send(req, resp, strlen(resp));
}

// GET /api/sd/saves
static esp_err_t api_sd_saves_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    char save_list[1024];
    sd_card_list_saves(save_list, sizeof(save_list));

    char json[1100];
    snprintf(json, sizeof(json), "{\"saves\":%s}", save_list);
    return httpd_resp_send(req, json, strlen(json));
}

// POST /api/sd/load
static esp_err_t api_sd_load_handler(httpd_req_t *req)
{
    char buf[256];
    int ret = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (ret <= 0) return ESP_FAIL;
    buf[ret] = '\0';

    char filename[64] = "Pokemon_FireRed.sav";
    char *p = strstr(buf, "\"filename\"");
    if (p) {
        char *quote1 = strchr(p + 10, '\"');
        if (quote1) {
            char *quote2 = strchr(quote1 + 1, '\"');
            if (quote2) {
                size_t len = quote2 - (quote1 + 1);
                if (len < sizeof(filename)) {
                    strncpy(filename, quote1 + 1, len);
                    filename[len] = '\0';
                }
            }
        }
    }

    gba_trade_load_save(filename);

    httpd_resp_set_type(req, "application/json");
    char resp[128];
    snprintf(resp, sizeof(resp), "{\"success\":true,\"filename\":\"%s\"}", filename);
    return httpd_resp_send(req, resp, strlen(resp));
}

esp_err_t start_web_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 12;
    config.stack_size = 8192;

    ESP_LOGI(TAG, "Starting HTTP Server on port: %d", config.server_port);
    if (httpd_start(&s_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server!");
        return ESP_FAIL;
    }

    httpd_uri_t uri_get_index = { .uri = "/", .method = HTTP_GET, .handler = index_handler };
    httpd_uri_t uri_get_css   = { .uri = "/style.css", .method = HTTP_GET, .handler = style_handler };
    httpd_uri_t uri_get_js    = { .uri = "/app.js", .method = HTTP_GET, .handler = js_handler };

    httpd_uri_t uri_api_status       = { .uri = "/api/status", .method = HTTP_GET, .handler = api_status_handler };
    httpd_uri_t uri_api_party        = { .uri = "/api/party", .method = HTTP_GET, .handler = api_party_handler };
    httpd_uri_t uri_api_trade_offer  = { .uri = "/api/trade/offer", .method = HTTP_POST, .handler = api_trade_offer_handler };
    httpd_uri_t uri_api_trade_cancel = { .uri = "/api/trade/cancel", .method = HTTP_POST, .handler = api_trade_cancel_handler };
    httpd_uri_t uri_api_sd_saves     = { .uri = "/api/sd/saves", .method = HTTP_GET, .handler = api_sd_saves_handler };
    httpd_uri_t uri_api_sd_load      = { .uri = "/api/sd/load", .method = HTTP_POST, .handler = api_sd_load_handler };

    httpd_register_uri_handler(s_server, &uri_get_index);
    httpd_register_uri_handler(s_server, &uri_get_css);
    httpd_register_uri_handler(s_server, &uri_get_js);
    httpd_register_uri_handler(s_server, &uri_api_status);
    httpd_register_uri_handler(s_server, &uri_api_party);
    httpd_register_uri_handler(s_server, &uri_api_trade_offer);
    httpd_register_uri_handler(s_server, &uri_api_trade_cancel);
    httpd_register_uri_handler(s_server, &uri_api_sd_saves);
    httpd_register_uri_handler(s_server, &uri_api_sd_load);

    ESP_LOGI(TAG, "Registered Web and REST API URI handlers.");
    return ESP_OK;
}

void stop_web_server(void)
{
    if (s_server) {
        httpd_stop(s_server);
        s_server = NULL;
    }
}
