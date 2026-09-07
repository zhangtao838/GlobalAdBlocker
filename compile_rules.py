#!/usr/bin/env python3
"""
GlobalAdBlocker 规则编译器：JSON 规则 → 二进制格式
用法: python3 compile_rules.py input.json output.bin
"""

import json
import struct
import sys
import os

GAB_RULES_MAGIC = 0x52424147  # 'GABR'
GAB_RULES_VERSION = 1
GAB_BUCKET_COUNT = 256
HEADER_SIZE = 40 + 256 * 4 + 256 * 4  # 10个uint32 + bucket_offsets + bucket_counts = 2088字节


def fnv1a_hash(s: bytes) -> int:
    """FNV-1a 哈希函数，与 C 端一致"""
    h = 2166136261
    for b in s:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def next_power_of_2(n: int) -> int:
    """计算大于等于n的最小2的幂"""
    if n <= 0:
        return 1
    p = 1
    while p < n:
        p <<= 1
    return p


def compile_rules(input_path: str, output_path: str):
    # 1. 读取 JSON
    with open(input_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    exact_domains = list(set(data.get('exact', [])))
    suffix_domains = list(set(data.get('suffix', [])))

    # 转小写并去重
    exact_domains = sorted(set(d.lower().strip() for d in exact_domains if d.strip()))
    suffix_domains = sorted(set(d.lower().strip() for d in suffix_domains if d.strip()))

    print(f"精确匹配: {len(exact_domains)} 条")
    print(f"后缀匹配: {len(suffix_domains)} 条")

    # 2. 构建字符串池
    # 偏移0保留给空槽标记，所以第一个域名从偏移1开始
    string_pool = bytearray([0])  # 偏移0 = \0（空槽标记）
    domain_offsets = {}  # domain -> offset in string_pool

    for domain in exact_domains + suffix_domains:
        if domain in domain_offsets:
            continue
        domain_bytes = domain.encode('utf-8') + b'\x00'
        domain_offsets[domain] = len(string_pool)
        string_pool.extend(domain_bytes)

    string_pool_size = len(string_pool)
    print(f"字符串池: {string_pool_size} 字节")

    # 3. 构建精确匹配哈希表（开放寻址法）
    exact_count = len(exact_domains)
    if exact_count > 0:
        # 哈希表大小为数量的2倍，向上取整到2的幂，确保负载因子<=0.5
        exact_hash_size = next_power_of_2(exact_count * 2)
    else:
        exact_hash_size = 1  # 至少1个槽

    exact_table = [(0, 0)] * exact_hash_size  # (hash, str_offset), (0,0)表示空槽

    for domain in exact_domains:
        domain_bytes = domain.encode('utf-8')
        h = fnv1a_hash(domain_bytes)
        mask = exact_hash_size - 1
        idx = h & mask

        # 线性探测
        while exact_table[idx][1] != 0:
            idx = (idx + 1) & mask

        exact_table[idx] = (h, domain_offsets[domain])

    # 4. 构建后缀匹配数组（按最后一个字节分桶）
    suffix_count = len(suffix_domains)

    # 分桶
    buckets = [[] for _ in range(GAB_BUCKET_COUNT)]
    for domain in suffix_domains:
        last_byte = domain.encode('utf-8')[-1]
        buckets[last_byte].append(domain)

    # 每个桶内按字典序排序
    for i in range(GAB_BUCKET_COUNT):
        buckets[i].sort()

    # 计算桶的偏移和数量
    bucket_offsets = [0] * GAB_BUCKET_COUNT
    bucket_counts = [0] * GAB_BUCKET_COUNT
    current_offset = 0
    for i in range(GAB_BUCKET_COUNT):
        bucket_offsets[i] = current_offset
        bucket_counts[i] = len(buckets[i])
        current_offset += len(buckets[i])

    # 构建后缀数组
    suffix_array = []  # [(length, str_offset)]
    for i in range(GAB_BUCKET_COUNT):
        for domain in buckets[i]:
            suffix_array.append((len(domain), domain_offsets[domain]))

    # 5. 计算各部分偏移
    exact_hash_offset = HEADER_SIZE
    suffix_array_offset = exact_hash_offset + exact_hash_size * 8  # 每个条目8字节
    string_pool_offset = suffix_array_offset + suffix_count * 6     # 每个条目6字节

    # 对齐到4字节
    if string_pool_offset % 4 != 0:
        string_pool_offset += 4 - (string_pool_offset % 4)

    total_size = string_pool_offset + string_pool_size
    print(f"文件总大小: {total_size} 字节 ({total_size/1024/1024:.2f} MB)")
    print(f"  头部: {HEADER_SIZE} 字节")
    print(f"  精确哈希表: {exact_hash_size * 8} 字节 ({exact_hash_size} 槽)")
    print(f"  后缀数组: {suffix_count * 6} 字节")
    print(f"  字符串池: {string_pool_size} 字节")

    # 6. 写入二进制文件
    with open(output_path, 'wb') as f:
        # 文件头
        f.write(struct.pack('<IIIIIIIII',
            GAB_RULES_MAGIC,       # magic
            GAB_RULES_VERSION,      # version
            exact_count,            # exact_count
            suffix_count,           # suffix_count
            exact_hash_size,        # exact_hash_size
            exact_hash_offset,      # exact_hash_offset
            suffix_array_offset,    # suffix_array_offset
            string_pool_offset,     # string_pool_offset
            string_pool_size,       # string_pool_size
        ))

        # bucket_offsets
        for offset in bucket_offsets:
            f.write(struct.pack('<I', offset))

        # bucket_counts
        for count in bucket_counts:
            f.write(struct.pack('<I', count))

        # 精确匹配哈希表
        for h, offset in exact_table:
            f.write(struct.pack('<II', h, offset))

        # 后缀匹配数组
        for length, offset in suffix_array:
            f.write(struct.pack('<HI', length, offset))

        # 对齐填充
        current_pos = f.tell()
        if current_pos < string_pool_offset:
            f.write(b'\x00' * (string_pool_offset - current_pos))

        # 字符串池
        f.write(bytes(string_pool))

    print(f"\n编译完成: {output_path}")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"用法: {sys.argv[0]} input.json output.bin")
        sys.exit(1)

    compile_rules(sys.argv[1], sys.argv[2])
