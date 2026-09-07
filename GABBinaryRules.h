#ifndef GABBinaryRules_h
#define GABBinaryRules_h

#include <stdint.h>
#include <stddef.h>
#include <string.h>

// 魔数: 'GABR' (0x47=G, 0x41=A, 0x42=B, 0x52=R)
#define GAB_RULES_MAGIC 0x52424147
#define GAB_RULES_VERSION 1
#define GAB_BUCKET_COUNT 256

#pragma pack(push, 1)

// 文件头: 固定大小，紧跟在文件最前面
typedef struct {
    uint32_t magic;               // 魔数 GAB_RULES_MAGIC
    uint32_t version;             // 版本号 GAB_RULES_VERSION
    uint32_t exact_count;         // 精确匹配域名数量
    uint32_t suffix_count;        // 后缀匹配域名数量
    uint32_t exact_hash_size;     // 精确匹配哈希表大小（必须是2的幂）
    uint32_t exact_hash_offset;   // 精确匹配哈希表在文件中的偏移（字节）
    uint32_t suffix_array_offset; // 后缀匹配数组在文件中的偏移（字节）
    uint32_t string_pool_offset;  // 字符串池在文件中的偏移（字节）
    uint32_t string_pool_size;    // 字符串池大小（字节）
    uint32_t bucket_offsets[GAB_BUCKET_COUNT]; // 每个桶在suffix_array中的起始索引
    uint32_t bucket_counts[GAB_BUCKET_COUNT];  // 每个桶中的suffix数量
} gab_rules_header_t;

// 精确匹配哈希表条目（开放寻址法）
typedef struct {
    uint32_t hash;        // 域名的FNV-1a哈希值
    uint32_t str_offset;  // 域名在字符串池中的偏移，0表示空槽（字符串池偏移0保留给空槽标记）
} gab_exact_entry_t;

// 后缀匹配数组条目（按最后一个字节分桶，桶内按字典序排序）
typedef struct {
    uint16_t length;      // 域名长度（不含\0）
    uint32_t str_offset;  // 域名在字符串池中的偏移
} gab_suffix_entry_t;

#pragma pack(pop)

// FNV-1a 哈希函数
static inline uint32_t gab_hash_string(const char *str, size_t len) {
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash ^= (uint8_t)str[i];
        hash *= 16777619u;
    }
    return hash;
}

// 规则上下文（mmap映射后的指针集合）
typedef struct {
    const void *base;                  // mmap起始地址
    size_t size;                       // 文件大小
    const gab_rules_header_t *header;  // 文件头指针
    const gab_exact_entry_t *exact_table;    // 精确匹配哈希表
    const gab_suffix_entry_t *suffix_array;  // 后缀匹配数组
    const char *string_pool;           // 字符串池
} gab_rules_ctx_t;

// 初始化上下文，校验文件头
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

// 精确匹配查找（开放寻址哈希表）
static inline int gab_rules_match_exact(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (!ctx || !host || host_len == 0) return 0;
    if (ctx->header->exact_count == 0) return 0;

    uint32_t hash = gab_hash_string(host, host_len);
    uint32_t mask = ctx->header->exact_hash_size - 1;
    uint32_t idx = hash & mask;

    for (uint32_t i = 0; i < ctx->header->exact_hash_size; i++) {
        const gab_exact_entry_t *entry = &ctx->exact_table[idx];
        if (entry->str_offset == 0) return 0;  // 遇到空槽，未命中

        if (entry->hash == hash) {
            const char *domain = ctx->string_pool + entry->str_offset;
            // 字符串池中的域名以\0结尾，用strlen获取长度后比较
            size_t domain_len = strlen(domain);
            if (domain_len == host_len && memcmp(domain, host, host_len) == 0) {
                return 1;
            }
        }

        idx = (idx + 1) & mask;  // 线性探测下一个槽
    }

    return 0;
}

// 后缀匹配查找（按最后一个字节分桶，桶内遍历）
static inline int gab_rules_match_suffix(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (!ctx || !host || host_len == 0) return 0;
    if (ctx->header->suffix_count == 0) return 0;

    // 按host最后一个字节分桶（后缀匹配要求host最后一个字节==suffix最后一个字节）
    uint8_t last_byte = (uint8_t)host[host_len - 1];
    uint32_t bucket_start = ctx->header->bucket_offsets[last_byte];
    uint32_t bucket_count = ctx->header->bucket_counts[last_byte];

    if (bucket_count == 0) return 0;

    for (uint32_t i = 0; i < bucket_count; i++) {
        const gab_suffix_entry_t *entry = &ctx->suffix_array[bucket_start + i];
        if (entry->length > host_len) continue;

        const char *suffix = ctx->string_pool + entry->str_offset;
        // 检查host是否以suffix结尾
        const char *host_tail = host + (host_len - entry->length);
        if (memcmp(host_tail, suffix, entry->length) == 0) {
            // 确保是完整域名段，避免 partial match（例如 "notads.com" 匹配 "ads.com"）
            if (host_len == entry->length || host[host_len - entry->length - 1] == '.') {
                return 1;
            }
        }
    }

    return 0;
}

// 综合匹配（精确 + 后缀）
static inline int gab_rules_match(const gab_rules_ctx_t *ctx, const char *host, size_t host_len) {
    if (gab_rules_match_exact(ctx, host, host_len)) return 1;
    if (gab_rules_match_suffix(ctx, host, host_len)) return 1;
    return 0;
}

#endif /* GABBinaryRules_h */
