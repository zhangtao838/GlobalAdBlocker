#ifndef GABBinaryRules_h
#define GABBinaryRules_h

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define GAB_RULES_MAGIC 0x52424147
#define GAB_RULES_VERSION 1
#define GAB_BUCKET_COUNT 256

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t exact_count;
    uint32_t suffix_count;
    uint32_t exact_hash_size;
    uint32_t exact_hash_offset;
    uint32_t suffix_array_offset;
    uint32_t string_pool_offset;
    uint32_t string_pool_size;
    uint32_t bucket_offsets[GAB_BUCKET_COUNT];
    uint32_t bucket_counts[GAB_BUCKET_COUNT];
} gab_rules_header_t;

typedef struct {
    uint32_t hash;
    uint32_t str_offset;
} gab_exact_entry_t;

typedef struct {
    uint16_t length;
    uint32_t str_offset;
} gab_suffix_entry_t;

#pragma pack(pop)

static inline uint32_t gab_hash_string(const char *str, size_t len) {
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash ^= (uint8_t)str[i];
        hash *= 16777619u;
    }
    return hash;
}

typedef struct {
    const void *base;
    size_t size;
    const gab_rules_header_t *header;
    const gab_exact_entry_t *exact_table;
    const gab_suffix_entry_t *suffix_array;
    const char *string_pool;
} gab_rules_ctx_t;

static inline int gab_rules_init(gab_rules_ctx_t *ctx, const void *base, size_t size) {
    if (!base || size < sizeof(gab_rules_header_t)) return -1;
    ctx->base = base;
    ctx->size = size;
    ctx->header = (const gab_rules_header_t *)base;
    if (ctx->header->magic != GAB_RULES_MAGIC) return -2;
    if (ctx->header->version != GAB_RULES_VERSION) return -3;
    if (ctx->header->exact_hash_size == 0 || (ctx->header->exact_hash_size & (ctx->header->exact_hash_size - 1)) != 0) return -4;
    ctx->exact_table = (const gab_exact_entry_t *)((const char *)base + ctx->header->exact_hash_offset);
    ctx->suffix_array = (const gab_suffix_entry_t *)((const char *)base + ctx->header->suffix_array_offset);
    ctx->string_pool = (const char *)base + ctx->header->string_pool_offset;
    return 0;
}

static inline int gab_rules_match_exact(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (!ctx || !host || host_len == 0) return 0;
    if (ctx->header->exact_count == 0) return 0;
    uint32_t hash = gab_hash_string(host, host_len);
    uint32_t mask = ctx->header->exact_hash_size - 1;
    uint32_t idx = hash & mask;
    for (uint32_t i = 0; i < ctx->header->exact_hash_size; i++) {
        const gab_exact_entry_t *entry = &ctx->exact_table[idx];
        if (entry->str_offset == 0) return 0;
        if (entry->hash == hash) {
            const char *domain = ctx->string_pool + entry->str_offset;
            size_t domain_len = strlen(domain);
            if (domain_len == host_len && memcmp(domain, host, host_len) == 0) return 1;
        }
        idx = (idx + 1) & mask;
    }
    return 0;
}

static inline int gab_rules_match_suffix(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (!ctx || !host || host_len == 0) return 0;
    if (ctx->header->suffix_count == 0) return 0;
    uint8_t last_byte = (uint8_t)host[host_len - 1];
    uint32_t bucket_start = ctx->header->bucket_offsets[last_byte];
    uint32_t bucket_count = ctx->header->bucket_counts[last_byte];
    if (bucket_count == 0) return 0;
    for (uint32_t i = 0; i < bucket_count; i++) {
        const gab_suffix_entry_t *entry = &ctx->suffix_array[bucket_start + i];
        if (entry->length > host_len) continue;
        const char *suffix = ctx->string_pool + entry->str_offset;
        const char *host_tail = host + (host_len - entry->length);
        if (memcmp(host_tail, suffix, entry->length) == 0) {
            if (host_len == entry->length || host[host_len - entry->length - 1] == '.') return 1;
        }
    }
    return 0;
}

static inline int gab_rules_match(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (gab_rules_match_exact(ctx, host, host_len)) return 1;
    if (gab_rules_match_suffix(ctx, host, host_len)) return 1;
    return 0;
}

#endif
