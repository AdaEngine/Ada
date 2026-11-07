#include "AdaMeshBoolean.h"
#include "manifold/manifold.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <new>

struct AdaMeshBooleanContext { manifold::ExecutionContext value; };
struct AdaMeshBooleanResult {
    std::vector<double> properties;
    std::vector<uint32_t> indices, sources, faces;
};

namespace {
int statusCode(manifold::Manifold::Error status) {
    using E = manifold::Manifold::Error;
    if (status == E::NoError) return 0;
    if (status == E::Cancelled) return 4;
    if (status == E::ResultTooLarge) return 3;
    if (status == E::NotManifold) return 2;
    return 1;
}

bool valid(const AdaMeshBooleanInput &input) {
    if (!input.properties || !input.indices || input.vertexCount < 4 ||
        input.indexCount < 12 || input.indexCount % 3 || input.vertexCount > UINT32_MAX) return false;
    for (size_t i = 0; i < input.vertexCount * 8; ++i)
        if (!std::isfinite(input.properties[i])) return false;
    for (size_t i = 0; i < input.indexCount; ++i)
        if (input.indices[i] >= input.vertexCount) return false;
    return true;
}

bool collapsedFloatFace(const manifold::MeshGL &mesh) {
    for (size_t face = 0; face < mesh.NumTri(); ++face) {
        const float *a = mesh.vertProperties.data() + mesh.triVerts[face * 3] * mesh.numProp;
        const float *b = mesh.vertProperties.data() + mesh.triVerts[face * 3 + 1] * mesh.numProp;
        const float *c = mesh.vertProperties.data() + mesh.triVerts[face * 3 + 2] * mesh.numProp;
        const double ux = double(b[0]) - a[0], uy = double(b[1]) - a[1], uz = double(b[2]) - a[2];
        const double vx = double(c[0]) - a[0], vy = double(c[1]) - a[1], vz = double(c[2]) - a[2];
        if (uy * vz - uz * vy == 0 && uz * vx - ux * vz == 0 && ux * vy - uy * vx == 0) return true;
    }
    return false;
}

bool mergeRoundedPositions(manifold::MeshGL &mesh, manifold::ExecutionContext &context) {
    // Distinct Double vertices may become exactly coincident at Float export.
    // Existing merge vectors describe the pre-rounding topology and cannot join
    // these newly coincident vertices. Keep all property vertices/attributes,
    // extending only their geometric equivalence before closed-solid validation.
    std::map<std::array<float, 3>, uint32_t> vertices;
    for (uint32_t index = 0; index < mesh.NumVert(); ++index) {
        if (index % 4096 == 0 && context.Cancelled()) return false;
        const float *point = mesh.vertProperties.data() + index * mesh.numProp;
        auto inserted = vertices.emplace(std::array<float, 3>{point[0], point[1], point[2]}, index);
        if (!inserted.second) {
            mesh.mergeFromVert.push_back(index);
            mesh.mergeToVert.push_back(inserted.first->second);
        }
    }
    return true;
}

// Split the adjacent, nondegenerate triangle at a collinear boundary vertex.
// This is an oriented edge flip: positions and the represented surface do not
// move. Both new faces inherit the adjacent face's provenance and interpolated
// properties; the removed face had zero area. A following native import validates
// the complete closed topology before any repaired result can escape this adapter.
enum class FloatRepair { unchanged, repaired, budget, cancelled };
FloatRepair splitCollinearFaces(manifold::MeshGL &mesh, manifold::ExecutionContext &context,
                        size_t maximumBytes) {
    const size_t count = mesh.NumTri(), vertices = mesh.NumVert();
    struct Run { uint32_t original; uint8_t flags; std::array<float, 12> transform; };
    // Conservative accounting for parent IDs, face metadata, old/new map edges
    // and rebuilt run tables; this bounds the adapter's own repair scratch.
    if (vertices > maximumBytes / 4 || count > (maximumBytes - vertices * 4) / (sizeof(Run) + 4 * 64 + 65)) return FloatRepair::budget;
    std::vector<uint32_t> parent(vertices);
    for (uint32_t i = 0; i < vertices; ++i) parent[i] = i;
    auto find = [&parent](uint32_t index) {
        while (parent[index] != index) { parent[index] = parent[parent[index]]; index = parent[index]; }
        return index;
    };
    for (size_t i = 0; i < mesh.mergeFromVert.size(); ++i) {
        const auto a = find(mesh.mergeFromVert[i]), b = find(mesh.mergeToVert[i]);
        parent[std::max(a, b)] = std::min(a, b);
    }
    std::vector<Run> runs(count);
    const bool transforms = !mesh.runTransform.empty();
    for (size_t run = 0; run < mesh.runOriginalID.size(); ++run) {
        Run value{mesh.runOriginalID[run], mesh.runFlags.empty() ? uint8_t(0) : mesh.runFlags[run], {}};
        if (transforms) std::copy_n(mesh.runTransform.begin() + run * 12, 12, value.transform.begin());
        std::fill(runs.begin() + mesh.runIndex[run] / 3, runs.begin() + mesh.runIndex[run + 1] / 3, value);
    }
    struct Edge { size_t face; int slot; };
    std::map<uint64_t, Edge> edges;
    auto edgeKey = [](uint32_t a, uint32_t b) { return (uint64_t(a) << 32) | b; };
    for (size_t face = 0; face < count; ++face) {
        if (face % 4096 == 0 && context.Cancelled()) return FloatRepair::cancelled;
        for (int edge = 0; edge < 3; ++edge) {
            const auto a = find(mesh.triVerts[face * 3 + edge]);
            const auto b = find(mesh.triVerts[face * 3 + (edge + 1) % 3]);
            edges.emplace(edgeKey(a, b), Edge{face, edge});
        }
    }
    std::vector<uint8_t> touched(count, 0);
    bool changed = false;
    for (size_t face = 0; face < count; ++face) {
        if (face % 4096 == 0 && context.Cancelled()) return FloatRepair::cancelled;
        if (touched[face]) continue;
        for (int opposite = 0; opposite < 3; ++opposite) {
            const auto aID = mesh.triVerts[face * 3 + opposite];
            const auto bID = mesh.triVerts[face * 3 + (opposite + 1) % 3];
            const auto cID = mesh.triVerts[face * 3 + (opposite + 2) % 3];
            const float *a = mesh.vertProperties.data() + aID * mesh.numProp;
            const float *b = mesh.vertProperties.data() + bID * mesh.numProp;
            const float *c = mesh.vertProperties.data() + cID * mesh.numProp;
            const std::array<double, 3> u{double(a[0]) - b[0], double(a[1]) - b[1], double(a[2]) - b[2]};
            const std::array<double, 3> v{double(c[0]) - b[0], double(c[1]) - b[1], double(c[2]) - b[2]};
            const double length = v[0]*v[0] + v[1]*v[1] + v[2]*v[2];
            if (length == 0 || u[1]*v[2] - u[2]*v[1] != 0 || u[2]*v[0] - u[0]*v[2] != 0 || u[0]*v[1] - u[1]*v[0] != 0) continue;
            const double t = (u[0]*v[0] + u[1]*v[1] + u[2]*v[2]) / length;
            if (!(t > 0 && t < 1)) continue;
            const auto found = edges.find(edgeKey(find(cID), find(bID)));
            if (found == edges.end() || found->second.face == face || touched[found->second.face]) continue;
            const auto adjacent = found->second.face;
            const int slot = found->second.slot;
            const auto cOther = mesh.triVerts[adjacent * 3 + slot];
            const auto bOther = mesh.triVerts[adjacent * 3 + (slot + 1) % 3];
            const auto dOther = mesh.triVerts[adjacent * 3 + (slot + 2) % 3];
            // A duplicate new diagonal would have four incident faces.
            if (find(aID) == find(dOther) || edges.count(edgeKey(find(aID), find(dOther))) || edges.count(edgeKey(find(dOther), find(aID)))) continue;
            const float *d = mesh.vertProperties.data() + dOther * mesh.numProp;
            const double dx = double(d[0]) - b[0], dy = double(d[1]) - b[1], dz = double(d[2]) - b[2];
            if (dy*v[2] - dz*v[1] == 0 && dz*v[0] - dx*v[2] == 0 && dx*v[1] - dy*v[0] == 0) continue;
            if (mesh.NumVert() >= maximumBytes / 64 || mesh.NumVert() == UINT32_MAX) return FloatRepair::budget;
            const auto newA = mesh.NumVert();
            std::vector<float> properties(mesh.numProp);
            for (size_t property = 0; property < mesh.numProp; ++property) {
                const double first = mesh.vertProperties[bOther * mesh.numProp + property];
                properties[property] = static_cast<float>(first + t * (double(mesh.vertProperties[cOther * mesh.numProp + property]) - first));
            }
            std::copy_n(a, 3, properties.begin());
            mesh.vertProperties.insert(mesh.vertProperties.end(), properties.begin(), properties.end());
            // MeshGL import consumes direct property-to-geometric indices, not
            // transitive aliases. Point the new seam vertex at the canonical ID.
            mesh.mergeFromVert.push_back(newA); mesh.mergeToVert.push_back(find(aID));
            parent.push_back(find(aID));
            mesh.triVerts[face * 3] = newA; mesh.triVerts[face * 3 + 1] = bOther; mesh.triVerts[face * 3 + 2] = dOther;
            mesh.triVerts[adjacent * 3] = newA; mesh.triVerts[adjacent * 3 + 1] = dOther; mesh.triVerts[adjacent * 3 + 2] = cOther;
            mesh.faceID[face] = mesh.faceID[adjacent]; runs[face] = runs[adjacent];
            touched[face] = 1; touched[adjacent] = 1; changed = true;
            edges.emplace(edgeKey(find(aID), find(dOther)), Edge{face, 0});
            edges.emplace(edgeKey(find(dOther), find(aID)), Edge{adjacent, 0});
            break;
        }
    }
    if (!changed) return FloatRepair::unchanged;
    mesh.runIndex.clear(); mesh.runOriginalID.clear(); mesh.runFlags.clear(); mesh.runTransform.clear();
    for (size_t face = 0; face < count; ++face) {
        if (face && runs[face].original == runs[face-1].original && runs[face].flags == runs[face-1].flags && runs[face].transform == runs[face-1].transform) continue;
        mesh.runIndex.push_back(static_cast<uint32_t>(face * 3)); mesh.runOriginalID.push_back(runs[face].original); mesh.runFlags.push_back(runs[face].flags);
        if (transforms) mesh.runTransform.insert(mesh.runTransform.end(), runs[face].transform.begin(), runs[face].transform.end());
    }
    mesh.runIndex.push_back(static_cast<uint32_t>(count * 3));
    return FloatRepair::repaired;
}

manifold::MeshGL ingest(const AdaMeshBooleanInput &input, const std::map<uint32_t, uint32_t> &ids) {
    manifold::MeshGL mesh;
    mesh.numProp = 8;
    mesh.vertProperties.assign(input.properties, input.properties + input.vertexCount * 8);
    mesh.triVerts.assign(input.indices, input.indices + input.indexCount);
    for (size_t face = 0; face < input.indexCount / 3; ++face) {
        mesh.runIndex.push_back(static_cast<uint32_t>(face * 3));
        mesh.runOriginalID.push_back(ids.at(input.faceSources ? input.faceSources[face] : 0));
        mesh.faceID.push_back(input.faceIDs ? input.faceIDs[face] : static_cast<uint32_t>(face));
    }
    mesh.runIndex.push_back(static_cast<uint32_t>(input.indexCount));
    // Reconstruct only exactly coincident position topology, preserving split properties.
    std::map<std::array<double, 3>, uint32_t> vertices;
    for (uint32_t i = 0; i < input.vertexCount; ++i) {
        const double *p = input.properties + i * 8;
        auto inserted = vertices.emplace(std::array<double, 3>{p[0], p[1], p[2]}, i);
        if (!inserted.second) {
            mesh.mergeFromVert.push_back(i);
            mesh.mergeToVert.push_back(inserted.first->second);
        }
    }
    return mesh;
}
}

extern "C" {
AdaMeshBooleanContext *ada_mesh_context_create(void) {
    try { return new AdaMeshBooleanContext; } catch (...) { return nullptr; }
}
void ada_mesh_context_cancel(AdaMeshBooleanContext *context) { if (context) context->value.Cancel(); }
void ada_mesh_context_destroy(AdaMeshBooleanContext *context) { delete context; }

AdaMeshBooleanResult *ada_mesh_boolean(AdaMeshBooleanContext *context,
    AdaMeshBooleanInput base, AdaMeshBooleanInput operand, int operation,
    size_t maximumTriangles, size_t maximumOutputBytes, int *status) {
    if (!status) return nullptr;
    *status = 1;
    if (!context || !valid(base) || !valid(operand) || operation < 0 || operation > 2) return nullptr;
    if (context->value.Cancelled()) { *status = 4; return nullptr; }
    try {
        std::map<uint32_t, uint32_t> ids;
        for (const auto &input : {base, operand})
            for (size_t face = 0; face < input.indexCount / 3; ++face)
                ids.emplace(input.faceSources ? input.faceSources[face] : 0, 0);
        const auto firstID = manifold::Manifold::ReserveIDs(static_cast<uint32_t>(ids.size()));
        std::map<uint32_t, uint32_t> original;
        uint32_t next = firstID;
        for (auto &entry : ids) { entry.second = next; original.emplace(next++, entry.first); }
        auto a = context->value.FromMeshGL(ingest(base, ids));
        *status = statusCode(a.Status()); if (*status) return nullptr;
        auto b = context->value.FromMeshGL(ingest(operand, ids));
        *status = statusCode(b.Status()); if (*status) return nullptr;
        const auto op = operation == 0 ? manifold::OpType::Add : operation == 1 ? manifold::OpType::Subtract : manifold::OpType::Intersect;
        auto result = a.Boolean(b, op).WithContext(context->value);
        *status = statusCode(result.Status()); if (*status) return nullptr;
        // Manifold's normalIdx is relative to properties AFTER position XYZ.
        auto mesh = result.GetMeshGL(0);
        if (mesh.NumTri() > maximumTriangles || mesh.NumVert() > maximumOutputBytes / 64 ||
            mesh.NumTri() > (maximumOutputBytes - mesh.NumVert() * 64) / 20) { *status = 3; return nullptr; }
        // Boolean intersections are computed in Double; render/query/collision
        // coordinates are Float. Re-import only a collapsed export so Manifold's
        // native Float-tolerance topology cleanup repairs the closed solid,
        // retaining merge vectors, original IDs, face IDs and properties.
        // Dropping isolated faces here would leave an unvalidated open shell.
        for (int repair = 0; repair < 8 && collapsedFloatFace(mesh); ++repair) {
            if (!mergeRoundedPositions(mesh, context->value)) { *status = 4; return nullptr; }
            auto rounded = context->value.FromMeshGL(mesh);
            *status = statusCode(rounded.Status()); if (*status) return nullptr;
            mesh = rounded.GetMeshGL(0);
            if (collapsedFloatFace(mesh)) {
                const auto repair = splitCollinearFaces(mesh, context->value, maximumOutputBytes);
                if (repair == FloatRepair::budget) { *status = 3; return nullptr; }
                if (repair == FloatRepair::cancelled) { *status = 4; return nullptr; }
                if (repair == FloatRepair::repaired) {
                    rounded = context->value.FromMeshGL(mesh);
                    *status = statusCode(rounded.Status()); if (*status) return nullptr;
                }
            }
            if (context->value.Cancelled()) { *status = 4; return nullptr; }
            mesh = rounded.GetMeshGL(0);
        }
        if (collapsedFloatFace(mesh)) { *status = 6; return nullptr; }
        const size_t vertices = mesh.NumVert(), triangles = mesh.NumTri();
        if (triangles > maximumTriangles || vertices > maximumOutputBytes / 64 ||
            triangles > (maximumOutputBytes - vertices * 64) / 20) { *status = 3; return nullptr; }
        auto out = std::make_unique<AdaMeshBooleanResult>();
        out->properties.assign(mesh.vertProperties.begin(), mesh.vertProperties.end());
        out->indices = std::move(mesh.triVerts);
        out->faces = std::move(mesh.faceID);
        out->sources.resize(triangles);
        for (size_t run = 0; run < mesh.runOriginalID.size(); ++run) {
            const auto found = original.find(mesh.runOriginalID[run]);
            if (found == original.end()) { *status = 7; return nullptr; }
            std::fill(out->sources.begin() + mesh.runIndex[run] / 3,
                      out->sources.begin() + mesh.runIndex[run + 1] / 3, found->second);
        }
        if (context->value.Cancelled()) { *status = 4; return nullptr; }
        *status = 0;
        return out.release();
    } catch (const std::bad_alloc &) { *status = 3; }
      catch (...) { *status = 5; }
    return nullptr;
}
size_t ada_mesh_result_vertex_count(const AdaMeshBooleanResult *r) { return r ? r->properties.size() / 8 : 0; }
size_t ada_mesh_result_index_count(const AdaMeshBooleanResult *r) { return r ? r->indices.size() : 0; }
const double *ada_mesh_result_properties(const AdaMeshBooleanResult *r) { return r ? r->properties.data() : nullptr; }
const uint32_t *ada_mesh_result_indices(const AdaMeshBooleanResult *r) { return r ? r->indices.data() : nullptr; }
const uint32_t *ada_mesh_result_sources(const AdaMeshBooleanResult *r) { return r ? r->sources.data() : nullptr; }
const uint32_t *ada_mesh_result_faces(const AdaMeshBooleanResult *r) { return r ? r->faces.data() : nullptr; }
void ada_mesh_result_destroy(AdaMeshBooleanResult *r) { delete r; }
}
