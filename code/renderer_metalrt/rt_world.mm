/*
===========================================================================
renderer_metalrt - Phase 1 session 4: real world/BSP geometry (LoadWorld).

Deliberately scoped to the simplest real slice: MST_PLANAR surfaces only
(ordinary brush faces - walls, floors, ceilings). MST_PATCH (curved
surfaces), MST_TRIANGLE_SOUP, MST_TERRAIN, and MST_FLARE are real,
separate work for a later session - skipped here, not silently dropped:
see the surfaceType switch below. No textures, no lightmaps, no
visibility culling (PVS) yet either - every planar surface in the map
draws, every frame, as flat gray geometry through the same depth-tested
3D pipeline entity placeholders use (rt_scene.mm). That's enough to
prove the real BSP data (already in world space, no per-surface
transform needed) reaches the screen correctly before any of the
lighting/material/culling work on top of it.
===========================================================================
*/
#include "rt_local.h"

#include <simd/simd.h>
#include <vector>

// Shared with rt_scene.mm - normal C++ linkage, matching how they're
// actually defined there (RT_GetDevice/RT_GetCurrentEncoder are already
// declared for us by rt_local.h's __OBJC__ block above).
bool RT_EnsurePipeline3D( void );
id<MTLRenderPipelineState> RT_GetPipeline3D( void );
id<MTLDepthStencilState> RT_GetDepthState3D( void );

namespace {

id<MTLBuffer> rtWorldVertexBuffer = nil;
int rtWorldVertexCount = 0;

} // namespace

static void RT_LoadWorld( const char *name )
{
	byte *fileData = NULL;
	long fileLen = ri.FS_ReadFile( name, (void **)&fileData );
	if ( fileLen < 0 || fileData == NULL )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: LoadWorld: \"%s\" not found\n", name );
		return;
	}

	dheader_t *header = (dheader_t *)fileData;
	if ( header->version < BSP_MIN_VERSION || header->version > BSP_MAX_VERSION )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: LoadWorld: \"%s\" has unsupported BSP version %d "
			"(expected %d-%d)\n", name, header->version, BSP_MIN_VERSION, BSP_MAX_VERSION );
		ri.FS_FreeFile( fileData );
		return;
	}

	lump_t *surfsLump = Q_GetLumpByVersion( header, LUMP_SURFACES );
	lump_t *vertsLump = Q_GetLumpByVersion( header, LUMP_DRAWVERTS );
	lump_t *indexLump = Q_GetLumpByVersion( header, LUMP_DRAWINDEXES );

	if ( surfsLump->filelen % sizeof( dsurface_t ) || vertsLump->filelen % sizeof( drawVert_t )
		|| indexLump->filelen % sizeof( int ) )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: LoadWorld: \"%s\" has malformed lump sizes\n", name );
		ri.FS_FreeFile( fileData );
		return;
	}

	int numSurfaces = surfsLump->filelen / sizeof( dsurface_t );
	dsurface_t *surfaces = (dsurface_t *)( fileData + surfsLump->fileofs );
	drawVert_t *allVerts = (drawVert_t *)( fileData + vertsLump->fileofs );
	int *allIndexes = (int *)( fileData + indexLump->fileofs );

	// Two passes, same shape as the real loader (tr_bsp.c R_LoadSurfaces):
	// count first so the final buffer can be allocated exactly once,
	// then fill it - simpler than a growable buffer for a one-shot,
	// load-time operation.
	int totalVerts = 0;
	int numPlanarSurfaces = 0;
	int numSkippedSurfaces = 0;
	for ( int i = 0; i < numSurfaces; i++ )
	{
		if ( surfaces[i].surfaceType == MST_PLANAR )
		{
			totalVerts += surfaces[i].numIndexes;
			numPlanarSurfaces++;
		}
		else if ( surfaces[i].surfaceType != MST_BAD )
		{
			numSkippedSurfaces++;
		}
	}

	if ( numSkippedSurfaces > 0 )
	{
		ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar surfaces loaded, "
			"%d non-planar surfaces (patches/triangle-soup/terrain/flares) skipped - not implemented yet\n",
			name, numPlanarSurfaces, numSkippedSurfaces );
	}

	if ( totalVerts == 0 )
	{
		ri.FS_FreeFile( fileData );
		return;
	}

	// Flat, non-indexed position-only triangle list - simplest thing
	// that reuses the existing entity pipeline's vertex layout
	// (device float3 *positions) unchanged. World-space already; BSP
	// vertex positions need no per-surface transform.
	std::vector<simd_float3> worldVerts;
	worldVerts.reserve( totalVerts );

	for ( int i = 0; i < numSurfaces; i++ )
	{
		dsurface_t *surf = &surfaces[i];
		if ( surf->surfaceType != MST_PLANAR )
			continue;

		drawVert_t *surfVerts = allVerts + surf->firstVert;
		int *surfIndexes = allIndexes + surf->firstIndex;

		for ( int j = 0; j < surf->numIndexes; j++ )
		{
			int vertIndex = surfIndexes[j];
			if ( vertIndex < 0 || vertIndex >= surf->numVerts )
				continue; // malformed index - skip rather than read out of bounds

			const float *xyz = surfVerts[vertIndex].xyz;
			worldVerts.push_back( simd_make_float3( xyz[0], xyz[1], xyz[2] ) );
		}
	}

	ri.FS_FreeFile( fileData );

	if ( worldVerts.empty() )
		return;

	if ( !RT_EnsurePipeline3D() )
		return;

	rtWorldVertexCount = (int)worldVerts.size();
	rtWorldVertexBuffer = [RT_GetDevice() newBufferWithBytes:worldVerts.data()
	                                                   length:worldVerts.size() * sizeof( simd_float3 )
	                                                  options:MTLResourceStorageModeShared];

	ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar surfaces, %d verts uploaded\n",
		name, numPlanarSurfaces, rtWorldVertexCount );
}

void RT_DrawWorld( simd_float4x4 viewProj )
{
	if ( rtWorldVertexBuffer == nil )
		return;

	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	[encoder setRenderPipelineState:RT_GetPipeline3D()];
	[encoder setDepthStencilState:RT_GetDepthState3D()];
	[encoder setVertexBuffer:rtWorldVertexBuffer offset:0 atIndex:0];

	// No entity transform - world vertices are already in world space,
	// so the model matrix is identity: MVP == viewProj.
	simd_float4x4 mvp = viewProj;
	[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];

	// Neutral gray, distinct from the entity placeholders' magenta -
	// this is real (if untextured) level geometry, not a stand-in.
	simd_float4 worldColor = simd_make_float4( 0.6f, 0.6f, 0.6f, 1.0f );
	[encoder setFragmentBytes:&worldColor length:sizeof( worldColor ) atIndex:0];

	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:rtWorldVertexCount];
}

void RT_InitWorldFunctions( refexport_t *re )
{
	re->LoadWorld = RT_LoadWorld;
}
