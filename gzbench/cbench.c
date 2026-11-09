// cbench <dir> <count> <rounds> <out dir> (not for upstream): each feed gzipped by ISA-L 2.31.1 at level 0 (the call
// swift-iouring-Tabonx makes), libdeflate at level 1 and zlib at level 1; ns per body and mean size, outputs kept.
#include <igzip_lib.h>
#include <libdeflate.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

static uint64_t now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }

static size_t isal(const void *in, size_t n, void *out, size_t cap) {
    struct isal_zstream s;
    isal_deflate_stateless_init(&s);
    s.next_in = (uint8_t *)in;
    s.avail_in = (uint32_t)n;
    s.next_out = out;
    s.avail_out = (uint32_t)cap;
    s.gzip_flag = IGZIP_GZIP;
    s.level = 0;
    return isal_deflate_stateless(&s) == COMP_OK ? cap - s.avail_out : 0;
}
static struct libdeflate_compressor *ld;
static size_t ldef(const void *in, size_t n, void *out, size_t cap) { return libdeflate_gzip_compress(ld, in, n, out, cap); }
static z_stream z;
static size_t zl1(const void *in, size_t n, void *out, size_t cap) {
    deflateReset(&z);
    z.next_in = (Bytef *)in; z.avail_in = (uInt)n; z.next_out = out; z.avail_out = (uInt)cap;
    return deflate(&z, Z_FINISH) == Z_STREAM_END ? cap - z.avail_out : 0;
}

int main(int argc, char **argv) {
    const char *dir = argv[1], *outdir = argv[4];
    int count = atoi(argv[2]), rounds = atoi(argv[3]);
    unsigned char **body = malloc(count * sizeof *body); size_t *len = malloc(count * sizeof *len);
    for (int i = 0; i < count; i++) {
        char path[512]; snprintf(path, sizeof path, "%s/%04d.json", dir, i);
        FILE *f = fopen(path, "rb"); fseek(f, 0, SEEK_END); len[i] = ftell(f); fseek(f, 0, SEEK_SET);
        body[i] = malloc(len[i]); fread(body[i], 1, len[i], f); fclose(f);
    }
    ld = libdeflate_alloc_compressor(1);
    deflateInit2(&z, 1, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY);
    struct { const char *name; size_t (*fn)(const void *, size_t, void *, size_t); } c[] = {
        {"isal-l0", isal}, {"libdeflate-l1", ldef}, {"zlib-l1", zl1}};
    size_t cap = 1 << 20; unsigned char *out = malloc(cap);
    for (int k = 0; k < 3; k++) {
        size_t total = 0;
        for (int i = 0; i < count; i++) {  // a warm-up round, whose outputs are kept for checking
            size_t m = c[k].fn(body[i], len[i], out, cap);
            total += m;
            char path[512]; snprintf(path, sizeof path, "%s/%s-%04d.gz", outdir, c[k].name, i);
            FILE *f = fopen(path, "wb"); fwrite(out, 1, m, f); fclose(f);
        }
        uint64_t t0 = now();
        for (int r = 0; r < rounds; r++) for (int i = 0; i < count; i++) c[k].fn(body[i], len[i], out, cap);
        double ns = (double)(now() - t0) / ((double)rounds * count);
        printf("%-14s %8.0f ns per feed, mean %6.0f bytes\n", c[k].name, ns, (double)total / count);
    }
    return 0;
}
