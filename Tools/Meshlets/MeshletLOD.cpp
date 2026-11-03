// Offline-only adaptive hierarchy builder. Source vertex identities and group borders are preserved.
#include "meshoptimizer.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <unordered_map>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static_assert(MESHOPTIMIZER_VERSION == 1030, "Use pinned meshoptimizer 1.3");
static uint32_t word(const unsigned char* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
static void output(uint32_t value) {
    unsigned char p[4] = {uint8_t(value), uint8_t(value >> 8), uint8_t(value >> 16), uint8_t(value >> 24)};
    if (std::fwrite(p, 1, 4, stdout) != 4) throw "Output write failed";
}
static void scalar(float value) { uint32_t bits; std::memcpy(&bits, &value, 4); output(bits); }
struct Node {
    uint32_t parent = UINT32_MAX, firstChild = 0, childCount = 0, firstSource = 0, sourceCount = 0, level = 0;
    float lo[3], hi[3], error = 0;
    std::vector<unsigned int> indices;
};

static std::unordered_map<uint64_t, unsigned int> borders(const std::vector<unsigned int>& indices) {
    std::unordered_map<uint64_t, unsigned int> counts;
    for (size_t i = 0; i < indices.size(); i += 3) for (int edge = 0; edge < 3; ++edge) {
        unsigned int a = indices[i + edge], b = indices[i + (edge + 1) % 3];
        uint64_t key = uint64_t(std::min(a, b)) << 32 | std::max(a, b);
        ++counts[key];
    }
    for (auto i = counts.begin(); i != counts.end();) { if (i->second == 2) i = counts.erase(i); else ++i; }
    return counts;
}

static std::vector<unsigned int> simplify(const std::vector<unsigned int>& source, const std::vector<float>& positions, float& error) {
    // Compact by original index identity, never by position: seams remain separate vertices.
    std::unordered_map<unsigned int, unsigned int> remap;
    std::vector<unsigned int> vertices, indices;
    std::vector<float> localPositions;
    indices.reserve(source.size());
    for (unsigned int index : source) {
        auto entry = remap.emplace(index, unsigned(vertices.size()));
        if (entry.second) {
            vertices.push_back(index);
            localPositions.insert(localPositions.end(), positions.begin() + size_t(index) * 3, positions.begin() + size_t(index) * 3 + 3);
        }
        indices.push_back(entry.first->second);
    }
    std::vector<unsigned int> destination(source.size());
    size_t target = (source.size() / 6) * 3;
    size_t count = meshopt_simplify(destination.data(), indices.data(), indices.size(), localPositions.data(), vertices.size(), 12,
        target, std::numeric_limits<float>::max(), meshopt_SimplifyLockBorder | meshopt_SimplifyErrorAbsolute, &error);
    destination.resize(count);
    for (unsigned int& index : destination) index = vertices[index];
    // Preserve exact source-ID boundary edges even across UV/normal seams and adjacent mixed LOD groups.
    if (borders(source) != borders(destination)) return source;
    return destination;
}

static int run() {
    unsigned char header[24];
    if (std::fread(header, 1, 24, stdin) != 24 || std::memcmp(header, "ADALOD01", 8) != 0) throw "Invalid LOD input header";
    uint32_t vertexCount = word(header + 8), indexCount = word(header + 12), maxVertices = word(header + 16), maxTriangles = word(header + 20);
    if (indexCount % 3 || indexCount > (1u << 28) || vertexCount > (1u << 28) || maxVertices < 3 || maxVertices > 256 || maxTriangles < 1 || maxTriangles > 256)
        throw "Invalid LOD counts/profile";
    size_t byteCount = size_t(vertexCount) * 12 + size_t(indexCount) * 4;
    std::vector<unsigned char> bytes(byteCount);
    if (std::fread(bytes.data(), 1, byteCount, stdin) != byteCount || std::fgetc(stdin) != EOF) throw "Invalid LOD geometry bytes";
    std::vector<float> positions(size_t(vertexCount) * 3);
    for (size_t i = 0; i < positions.size(); ++i) {
        uint32_t bits = word(bytes.data() + i * 4); std::memcpy(&positions[i], &bits, 4);
        if (!std::isfinite(positions[i])) throw "Nonfinite source position";
    }
    std::vector<unsigned int> indices(indexCount);
    for (size_t i = 0; i < indices.size(); ++i) {
        indices[i] = word(bytes.data() + size_t(vertexCount) * 12 + i * 4);
        if (indices[i] >= vertexCount) throw "Invalid source index";
    }
    size_t bound = meshopt_buildMeshletsBound(indexCount, maxVertices, maxTriangles);
    std::vector<meshopt_Meshlet> scan(bound);
    std::vector<unsigned int> remap(indexCount);
    std::vector<unsigned char> triangles(indexCount);
    size_t clusterCount = indexCount ? meshopt_buildMeshletsScan(scan.data(), remap.data(), triangles.data(), indices.data(), indexCount,
        vertexCount, maxVertices, maxTriangles) : 0;
    std::vector<Node> nodes;
    std::vector<uint32_t> current, roots;
    uint32_t sourceCursor = 0;
    for (size_t first = 0; first < clusterCount; first += 4) {
        Node node;
        node.firstSource = sourceCursor;
        for (size_t c = first; c < std::min(first + 4, clusterCount); ++c) node.sourceCount += scan[c].triangle_count * 3;
        node.indices.assign(indices.begin() + sourceCursor, indices.begin() + sourceCursor + node.sourceCount);
        for (int axis = 0; axis < 3; ++axis) { node.lo[axis] = std::numeric_limits<float>::max(); node.hi[axis] = -node.lo[axis]; }
        for (unsigned int index : node.indices) for (int axis = 0; axis < 3; ++axis) {
            node.lo[axis] = std::min(node.lo[axis], positions[size_t(index) * 3 + axis]);
            node.hi[axis] = std::max(node.hi[axis], positions[size_t(index) * 3 + axis]);
        }
        current.push_back(uint32_t(nodes.size())); nodes.push_back(std::move(node)); sourceCursor += nodes.back().sourceCount;
    }
    if (sourceCursor != indexCount) throw "Leaf coverage mismatch";
    while (!current.empty()) {
        std::vector<uint32_t> next;
        for (size_t first = 0; first < current.size();) {
            size_t end = first + 1;
            while (end < current.size() && end - first < 4 && current[end] == current[end - 1] + 1 &&
                nodes[current[end]].firstSource == nodes[current[end - 1]].firstSource + nodes[current[end - 1]].sourceCount) ++end;
            if (end - first == 1) { roots.push_back(current[first]); first = end; continue; }
            Node node;
            node.firstChild = current[first]; node.childCount = uint32_t(end - first);
            node.firstSource = nodes[current[first]].firstSource; node.level = nodes[current[first]].level + 1;
            for (int axis = 0; axis < 3; ++axis) { node.lo[axis] = nodes[current[first]].lo[axis]; node.hi[axis] = nodes[current[first]].hi[axis]; }
            std::vector<unsigned int> source;
            for (size_t i = first; i < end; ++i) {
                const Node& child = nodes[current[i]];
                node.sourceCount += child.sourceCount; node.error = std::max(node.error, child.error);
                for (int axis = 0; axis < 3; ++axis) { node.lo[axis] = std::min(node.lo[axis], child.lo[axis]); node.hi[axis] = std::max(node.hi[axis], child.hi[axis]); }
                source.insert(source.end(), child.indices.begin(), child.indices.end());
            }
            float error = 0;
            node.indices = simplify(source, positions, error);
            if (node.indices.empty() || node.indices.size() >= source.size() || !std::isfinite(error)) {
                for (size_t i = first; i < end; ++i) roots.push_back(current[i]);
            } else {
                float diagonal = 0;
                for (int axis = 0; axis < 3; ++axis) diagonal += (node.hi[axis] - node.lo[axis]) * (node.hi[axis] - node.lo[axis]);
                // A conservative visual heuristic avoids zero-error planar coarsening at every distance.
                node.error = std::nextafter(std::max(node.error + error, std::sqrt(diagonal) * 0.001f), std::numeric_limits<float>::infinity());
                if (!std::isfinite(node.error) || node.level > 32) throw "Hierarchy error/depth overflow";
                uint32_t parent = uint32_t(nodes.size());
                for (size_t i = first; i < end; ++i) nodes[current[i]].parent = parent;
                next.push_back(parent); nodes.push_back(std::move(node));
            }
            first = end;
        }
        current = std::move(next);
    }
    std::sort(roots.begin(), roots.end(), [&](uint32_t a, uint32_t b) { return nodes[a].firstSource < nodes[b].firstSource; });
    size_t flatCount = 0; for (const Node& node : nodes) flatCount += node.indices.size();
    if (nodes.size() > 1000000 || flatCount > (1u << 28)) throw "Hierarchy budget exceeded";
    if (std::fwrite("ADALODO1", 1, 8, stdout) != 8) throw "Output header failed";
    output(uint32_t(nodes.size())); output(uint32_t(roots.size())); output(uint32_t(flatCount));
    uint32_t firstIndex = 0;
    for (const Node& node : nodes) {
        output(node.parent); output(node.firstChild); output(node.childCount); output(node.firstSource); output(node.sourceCount);
        output(firstIndex); output(uint32_t(node.indices.size())); output(node.level);
        for (float v : node.lo) scalar(v); for (float v : node.hi) scalar(v); scalar(node.error);
        firstIndex += uint32_t(node.indices.size());
    }
    for (uint32_t root : roots) output(root);
    for (const Node& node : nodes) for (unsigned int index : node.indices) output(index);
    return 0;
}

int main() {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
#endif
    try { return run(); }
    catch (const char* error) { std::fprintf(stderr, "MeshletLOD: %s\n", error); }
    catch (const std::exception& error) { std::fprintf(stderr, "MeshletLOD: %s\n", error.what()); }
    return 1;
}
