// SPDX-FileCopyrightText: 2023 Erin Catto
// SPDX-License-Identifier: MIT

#include "bitset.h"
#include "ctz.h"
#include "test_macros.h"

#include <math.h>

#define COUNT 169

int TestBitMath( void )
{
	uint32_t r1 = b3CLZ32( 9 );
	ENSURE( r1 == 31 - 3 );

	for (int i = 1; i < 1000; ++i)
	{
		int e1 = b3LowerPowerOf2Exponent( i );
		int e2 = (int)floorf( log2f( (float)i ) );
		ENSURE(e1 == e2);
	}

	return 0;
}

int TestBitSet( void )
{
	struct b3BitSet bitSet = b3CreateBitSet( COUNT );

	b3SetBitCountAndClear( &bitSet, COUNT );
	bool values[COUNT] = { false };

	int32_t i1 = 0, i2 = 1;
	b3SetBit( &bitSet, i1 );
	values[i1] = true;

	while ( i2 < COUNT )
	{
		b3SetBit( &bitSet, i2 );
		values[i2] = true;
		int32_t next = i1 + i2;
		i1 = i2;
		i2 = next;
	}

	for ( int32_t i = 0; i < COUNT; ++i )
	{
		bool value = b3GetBit( &bitSet, i );
		ENSURE( value == values[i] );
	}

	b3DestroyBitSet( &bitSet );

	return 0;
}

int BitTest( void )
{
	RUN_SUBTEST( TestBitMath );
	RUN_SUBTEST( TestBitSet );
	return 0;
}
