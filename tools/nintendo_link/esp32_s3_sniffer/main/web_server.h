#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start HTTP web server on port 80 serving UI and REST API
 */
esp_err_t start_web_server(void);

/**
 * @brief Stop the HTTP web server
 */
void stop_web_server(void);

#ifdef __cplusplus
}
#endif
