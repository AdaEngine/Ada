// Offline-only adapter for the pinned meshoptimizer 1.3 scan API. No engine/runtime linkage.
#include "meshoptimizer.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <exception>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static_assert(MESHOPTIMIZER_VERSION == 1030, "Use the pinned meshoptimizer 1.3 source");

static uint32_t word(const unsigned char* bytes) {
    return uint32_t(bytes[0]) | uint32_t(bytes[1]) << 8 | uint32_t(bytes[2]) << 16 | uint32_t(bytes[3]) << 24;
}

static void writeWord(uint32_t value) {
    unsigned char bytes[4] = {uint8_t(value), uint8_t(value >> 8), uint8_t(value >> 16), uint8_t(value >> 24)};
    if (std::fwrite(bytes, 1, 4, stdout) != 4) throw "Cannot write meshlet output";
}

static int run() {
    unsigned char header[24];
    if (std::fread(header, 1, 24, stdin) != 24 || std::memcmp(header, "ADAMIN01", 8) != 0) throw "Invalid input header";
    uint32_t vertexCount = word(header + 8), indexCount = word(header + 12);
    uint32_t maxVertices = word(header + 16), maxTriangles = word(header + 20);
    if (indexCount % 3 || indexCount > (1u << 28) || maxVertices < 3 || maxVertices > 256 || maxTriangles < 1 || maxTriangles > 256)
        throw "Invalid input counts/profile";
    std::vector<unsigned char> bytes(size_t(indexCount) * 4);
    if (!bytes.empty() && std::fread(bytes.data(), 1, bytes.size(), stdin) != bytes.size()) throw "Truncated input indices";
    if (std::fgetc(stdin) != EOF) throw "Trailing input bytes";
    std::vector<unsigned int> indices(indexCount);
    for (size_t i = 0; i < indexCount; ++i) {
        indices[i] = word(bytes.data() + i * 4);
        if (indices[i] >= vertexCount) throw "Vertex index exceeds source vertex count";
    }
    size_t bound = meshopt_buildMeshletsBound(indexCount, maxVertices, maxTriangles);
    std::vector<meshopt_Meshlet> meshlets(bound);
    std::vector<unsigned int> vertices(size_t(indexCount), 0);
    std::vector<unsigned char> triangles(size_t(indexCount), 0);
    size_t count = indexCount ? meshopt_buildMeshletsScan(meshlets.data(), vertices.data(), triangles.data(),
        indices.data(), indexCount, vertexCount, maxVertices, maxTriangles) : 0;
    // Reconstruct every native local triangle before accepting it: dropped/reordered degenerates fail.
    size_t cursor = 0;
    for (size_t i = 0; i < count; ++i) {
        const meshopt_Meshlet& meshlet = meshlets[i];
        if (meshlet.vertex_count > maxVertices || meshlet.triangle_count > maxTriangles) throw "Native profile violation";
        for (size_t j = 0; j < meshlet.triangle_count * 3; ++j) {
            unsigned int local = triangles[meshlet.triangle_offset + j];
            if (local >= meshlet.vertex_count || cursor >= indices.size() || vertices[meshlet.vertex_offset + local] != indices[cursor++])
                throw "Native builder did not preserve source triangle sequence";
        }
    }
    if (cursor != indices.size()) throw "Native builder did not cover the source indices";
    if (std::fwrite("ADAMOUT1", 1, 8, stdout) != 8) throw "Cannot write output header";
    writeWord(uint32_t(count));
    cursor = 0;
    for (size_t i = 0; i < count; ++i) {
        writeWord(uint32_t(cursor));
        writeWord(meshlets[i].triangle_count * 3);
        cursor += meshlets[i].triangle_count * 3;
    }
    return 0;
}

int main() {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    try { return run(); }
    catch (const char* error) { std::fprintf(stderr, "MeshletScan: %s\n", error); }
    catch (const std::exception& error) { std::fprintf(stderr, "MeshletScan: %s\n", error.what()); }
    return 1;
}
