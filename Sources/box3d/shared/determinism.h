// SPDX-FileCopyrightText: 2025 Erin Catto
// SPDX-License-Identifier: MIT
#pragma once

#include "box3d/id.h"

#include "human.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define RAGDOLL_GROUP_SIZE 2
#define RAGDOLL_GRID_COUNT 2

typedef struct RagdollGroup
{
	Human humans[RAGDOLL_GROUP_SIZE];
} RagdollGroup;

typedef struct FallingRagdollData
{
	RagdollGroup groups[RAGDOLL_GRID_COUNT * RAGDOLL_GRID_COUNT];
	b3MeshData* gridMesh;
	b3MeshData* torusMesh;
	int columnCount;
	int columnIndex;
	int stepCount;
	int sleepStep;
	uint32_t hash;
} FallingRagdollData;

FallingRagdollData CreateFallingRagdolls( b3WorldId worldId );
bool UpdateFallingRagdolls( b3WorldId worldId, FallingRagdollData* data );
void DestroyFallingRagdolls( FallingRagdollData* data );

#ifdef __cplusplus
}
#endif
