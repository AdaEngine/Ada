// SPDX-FileCopyrightText: 2025 Erin Catto
// SPDX-License-Identifier: MIT

#include "block_allocator.h"
#include "test_macros.h"

typedef struct
{
	int value1;
	float value2;
} Foo;

_Static_assert( sizeof( Foo ) >= sizeof( void* ), "too small" );

static int TestBlockAllocate( void )
{
	b3BlockAllocator allocator = b3CreateBlockAllocator( (int)sizeof( Foo ), 2 );

	Foo* item1 = b3AllocateElement( &allocator );
	ENSURE( item1 != NULL );

	Foo* item2 = b3AllocateElement( &allocator );
	ENSURE( item2 != NULL );

	b3DestroyBlockAllocator( &allocator );
	return 0;
}

static int TestBlockClear( void )
{
	b3BlockAllocator allocator = b3CreateBlockAllocator( (int)sizeof( Foo ), 0 );

	Foo* item1 = b3AllocateElement( &allocator );
	Foo* item2 = b3AllocateElement( &allocator );

	b3FreeElement( &allocator, item1 );
	b3FreeElement( &allocator, item2 );

	b3DestroyBlockAllocator( &allocator );
	return 0;
}

int AllocatorTest( void )
{
	RUN_SUBTEST( TestBlockAllocate );
	RUN_SUBTEST( TestBlockClear );

	return 0;
}
