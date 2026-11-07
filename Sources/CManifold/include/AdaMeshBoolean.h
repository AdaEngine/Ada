#ifndef ADA_MESH_BOOLEAN_H
#define ADA_MESH_BOOLEAN_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct AdaMeshBooleanContext AdaMeshBooleanContext;
typedef struct AdaMeshBooleanResult AdaMeshBooleanResult;
typedef struct {
    const double *properties; /* x,y,z,nx,ny,nz,u,v */
    size_t vertexCount;
    const uint32_t *indices;
    size_t indexCount;
    const uint32_t *faceSources;
    const uint32_t *faceIDs;
} AdaMeshBooleanInput;

AdaMeshBooleanContext *ada_mesh_context_create(void);
void ada_mesh_context_cancel(AdaMeshBooleanContext *context);
void ada_mesh_context_destroy(AdaMeshBooleanContext *context);
/* operation: 0 union, 1 subtract, 2 intersect. Status: 0 success, 1 invalid,
   2 nonmanifold, 3 budget/allocation, 4 cancellation, 5 internal failure,
   6 unrepresentable Float topology, 7 inconsistent source provenance. */
AdaMeshBooleanResult *ada_mesh_boolean(AdaMeshBooleanContext *context,
    AdaMeshBooleanInput base, AdaMeshBooleanInput operand, int operation,
    size_t maximumTriangles, size_t maximumOutputBytes, int *status);
size_t ada_mesh_result_vertex_count(const AdaMeshBooleanResult *result);
size_t ada_mesh_result_index_count(const AdaMeshBooleanResult *result);
const double *ada_mesh_result_properties(const AdaMeshBooleanResult *result);
const uint32_t *ada_mesh_result_indices(const AdaMeshBooleanResult *result);
const uint32_t *ada_mesh_result_sources(const AdaMeshBooleanResult *result);
const uint32_t *ada_mesh_result_faces(const AdaMeshBooleanResult *result);
void ada_mesh_result_destroy(AdaMeshBooleanResult *result);

#ifdef __cplusplus
}
#endif
#endif
