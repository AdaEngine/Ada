// SPDX-FileCopyrightText: 2023 Erin Catto
// SPDX-License-Identifier: MIT

#include "test_macros.h"

#include "box3d/types.h"

int IdTest( void )
{
	uint64_t x = 0x0123456789ABCDEFull;

	{
		b3BodyId id = b3LoadBodyId( x );
		uint64_t y = b3StoreBodyId( id );
		ENSURE( x == y );
	}

	{
		b3ShapeId id = b3LoadShapeId( x );
		uint64_t y = b3StoreShapeId( id );
		ENSURE( x == y );
	}

	{
		b3JointId id = b3LoadJointId( x );
		uint64_t y = b3StoreJointId( id );
		ENSURE( x == y );
	}

	return 0;
}
