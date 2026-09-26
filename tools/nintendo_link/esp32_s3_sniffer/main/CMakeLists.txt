idf_component_register(
    SRCS "main.c" "sd_card.c" "gba_trade.c" "web_server.c"
    INCLUDE_DIRS "."
    REQUIRES esp_event esp_netif esp_wifi nvs_flash esp_http_server fatfs vfs sdmmc driver esp_timer
    EMBED_TXTFILES "../web/index.html" "../web/style.css" "../web/app.js"
)