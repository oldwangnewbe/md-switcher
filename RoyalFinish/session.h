#pragma once
#include <stdint.h>
#include <wchar.h>

enum {
    ROYAL_SESSION_VERSION = 1,
    ROYAL_CARD_LIMIT = 65536,
    ROYAL_CARD_BYTES = ROYAL_CARD_LIMIT / 8,
    ROYAL_LOG_PATH = 1024
};

typedef struct {
    uint32_t version;
    uint8_t cards[ROYAL_CARD_BYTES];
    wchar_t log_path[ROYAL_LOG_PATH];
} RoyalSession;
