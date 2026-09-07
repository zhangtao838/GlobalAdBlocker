#!/usr/bin/env python3
import json, struct, sys

GAB_RULES_MAGIC = 0x52424147
GAB_RULES_VERSION = 1
GAB_BUCKET_COUNT = 256
HEADER_SIZE = 40 + 256 * 4 + 256 * 4

def fnv1a(s):
    h = 2166136261
    for b in s:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h

def next_pow2(n):
    if n <= 0: return 1
    p = 1
    while p < n: p <<= 1
    return p

def compile_rules(input_path, output_path):
    with open(input_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    exact = sorted(set(d.lower().strip() for d in data.get('exact', []) if d.strip()))
    suffix = sorted(set(d.lower().strip() for d in data.get('suffix', []) if d.strip()))
    print(f"精确: {len(exact)}, 后缀: {len(suffix)}")

    string_pool = bytearray([0])
    domain_offsets = {}
    for d in exact + suffix:
        if d in domain_offsets: continue
        b = d.encode('utf-8') + b'\x00'
        domain_offsets[d] = len(string_pool)
        string_pool.extend(b)
    string_pool_size = len(string_pool)

    exact_count = len(exact)
    exact_hash_size = next_pow2(exact_count * 2) if exact_count > 0 else 1
    exact_table = [(0, 0)] * exact_hash_size
    for d in exact:
        b = d.encode('utf-8')
        h = fnv1a(b)
        mask = exact_hash_size - 1
        idx = h & mask
        while exact_table[idx][1] != 0:
            idx = (idx + 1) & mask
        exact_table[idx] = (h, domain_offsets[d])

    suffix_count = len(suffix)
    buckets = [[] for _ in range(GAB_BUCKET_COUNT)]
    for d in suffix:
        buckets[d.encode('utf-8')[-1]].append(d)
    for i in range(GAB_BUCKET_COUNT):
        buckets[i].sort()
    bucket_offsets = [0] * GAB_BUCKET_COUNT
    bucket_counts = [0] * GAB_BUCKET_COUNT
    cur = 0
    for i in range(GAB_BUCKET_COUNT):
        bucket_offsets[i] = cur
        bucket_counts[i] = len(buckets[i])
        cur += len(buckets[i])
    suffix_array = []
    for i in range(GAB_BUCKET_COUNT):
        for d in buckets[i]:
            suffix_array.append((len(d), domain_offsets[d]))

    exact_hash_offset = HEADER_SIZE
    suffix_array_offset = exact_hash_offset + exact_hash_size * 8
    string_pool_offset = suffix_array_offset + suffix_count * 6
    if string_pool_offset % 4 != 0:
        string_pool_offset += 4 - (string_pool_offset % 4)
    total_size = string_pool_offset + string_pool_size
    print(f"总大小: {total_size} bytes ({total_size/1024/1024:.2f} MB)")

    with open(output_path, 'wb') as f:
        header = struct.pack('<IIIIIIIII',
            GAB_RULES_MAGIC, GAB_RULES_VERSION, exact_count, suffix_count,
            exact_hash_size, exact_hash_offset, suffix_array_offset,
            string_pool_offset, string_pool_size)
        f.write(header)
        for o in bucket_offsets: f.write(struct.pack('<I', o))
        for c in bucket_counts: f.write(struct.pack('<I', c))
        for h, o in exact_table: f.write(struct.pack('<II', h, o))
        for l, o in suffix_array: f.write(struct.pack('<HI', l, o))
        while f.tell() < string_pool_offset: f.write(b'\x00')
        f.write(bytes(string_pool))
    print(f"完成: {output_path}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"用法: {sys.argv[0]} input.json output.bin")
        sys.exit(1)
    compile_rules(sys.argv[1], sys.argv[2])
