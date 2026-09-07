/*
===========================================================================
renderer_metalrt - Phase 1 session 4: real world/BSP geometry (LoadWorld).
Session 11 adds MST_PATCH (curved surfaces - arches, pipes, rounded
terrain detail).

MST_TRIANGLE_SOUP, MST_TERRAIN, and MST_FLARE are still real, separate
work for a later session - skipped here, not silently dropped: see the
surfaceType switch below. No textures, no lightmaps, no visibility
culling (PVS) yet either - every planar/patch surface in the map draws,
every frame, as flat (session 10: lit) gray geometry through the same
depth-tested 3D pipeline entity placeholders use (rt_scene.mm). That's
enough to prove the real BSP data (already in world space, no
per-surface transform needed) reaches the screen correctly before any
of the material/culling work on top of it.
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
simd_float3 RT_GetLightDir( void );

namespace {

id<MTLBuffer> rtWorldVertexBuffer = nil;
id<MTLBuffer> rtWorldNormalBuffer = nil;
int rtWorldVertexCount = 0;

// Session 11: MST_PATCH surfaces are control-point grids of overlapping
// 3x3 biquadratic Bezier sub-patches (the classic idTech3 curved-surface
// scheme - see code/renderergl2/tr_curve.c's R_SubdividePatchToGrid for
// the real, LOD-adaptive version this deliberately simplifies). Real
// LOD (view-distance-based subdivision, crack-prevention between
// differently-tessellated neighbors) is real, separate work; this
// tessellates every patch at one fixed resolution instead - correct
// curved geometry, just not adaptive yet.
const int RT_PATCH_TESSELLATION = 8;
const int RT_MAX_PATCH_DIM = 64; // sanity bound against a malformed BSP, not a real engine limit

// Evaluates one 3x3 biquadratic Bezier sub-patch at parametric (u,v) in
// [0,1]^2 - standard De Casteljau-equivalent closed form, not the real
// engine's iterative lerp-based PutPointsOnCurve (mathematically the
// same curve, simpler to evaluate at an arbitrary fixed resolution
// instead of the real engine's adaptive row/column insertion). Normal
// is interpolated from the control points' own normals using the same
// basis weights, rather than recomputed from the tessellated geometry
// (MakeMeshNormals in the real engine) - a reasonable approximation for
// a first pass, not exact for a highly curved patch.
void RT_EvalBezierPatch3x3( const drawVert_t *ctrl[3][3], float u, float v, simd_float3 *outPos, simd_float3 *outNormal )
{
	float bu[3] = { ( 1.0f - u ) * ( 1.0f - u ), 2.0f * u * ( 1.0f - u ), u * u };
	float bv[3] = { ( 1.0f - v ) * ( 1.0f - v ), 2.0f * v * ( 1.0f - v ), v * v };

	simd_float3 pos = simd_make_float3( 0.0f, 0.0f, 0.0f );
	simd_float3 normal = simd_make_float3( 0.0f, 0.0f, 0.0f );
	for ( int j = 0; j < 3; j++ )
	{
		for ( int i = 0; i < 3; i++ )
		{
			float weight = bu[i] * bv[j];
			const float *xyz = ctrl[j][i]->xyz;
			const float *n = ctrl[j][i]->normal;
			pos += weight * simd_make_float3( xyz[0], xyz[1], xyz[2] );
			normal += weight * simd_make_float3( n[0], n[1], n[2] );
		}
	}

	*outPos = pos;
	float normalLen = simd_length( normal );
	*outNormal = ( normalLen > 0.0001f ) ? ( normal / normalLen ) : simd_make_float3( 0.0f, 0.0f, 1.0f );
}

// Tessellates every 3x3 sub-patch of one MST_PATCH surface at a fixed
// resolution and appends the result to the shared world vertex/normal
// arrays - same flat, non-indexed triangle list as planar surfaces, so
// no new pipeline/buffer/draw-call plumbing is needed.
void RT_TessellatePatchSurface( dsurface_t *surf, drawVert_t *allVerts,
	std::vector<simd_float3> *outVerts, std::vector<simd_float3> *outNormals )
{
	int width = surf->patchWidth;
	int height = surf->patchHeight;

	// Real patches are always odd-sized (each pair of extra rows/columns
	// beyond the first 3 shares an edge with the next 3x3 sub-patch) and
	// at least 3x3 - anything else is a malformed surface, not a valid
	// shape to tessellate.
	if ( width < 3 || height < 3 || ( width % 2 ) == 0 || ( height % 2 ) == 0
		|| width > RT_MAX_PATCH_DIM || height > RT_MAX_PATCH_DIM )
		return;

	if ( surf->numVerts != width * height )
		return;

	drawVert_t *ctrlPoints = allVerts + surf->firstVert;
	int numPatchesX = ( width - 1 ) / 2;
	int numPatchesY = ( height - 1 ) / 2;

	simd_float3 gridPos[RT_PATCH_TESSELLATION + 1][RT_PATCH_TESSELLATION + 1];
	simd_float3 gridNorm[RT_PATCH_TESSELLATION + 1][RT_PATCH_TESSELLATION + 1];

	for ( int py = 0; py < numPatchesY; py++ )
	{
		for ( int px = 0; px < numPatchesX; px++ )
		{
			const drawVert_t *ctrl[3][3];
			for ( int j = 0; j < 3; j++ )
				for ( int k = 0; k < 3; k++ )
					ctrl[j][k] = &ctrlPoints[( py * 2 + j ) * width + ( px * 2 + k )];

			for ( int gv = 0; gv <= RT_PATCH_TESSELLATION; gv++ )
			{
				float v = (float)gv / (float)RT_PATCH_TESSELLATION;
				for ( int gu = 0; gu <= RT_PATCH_TESSELLATION; gu++ )
				{
					float u = (float)gu / (float)RT_PATCH_TESSELLATION;
					RT_EvalBezierPatch3x3( ctrl, u, v, &gridPos[gv][gu], &gridNorm[gv][gu] );
				}
			}

			for ( int gv = 0; gv < RT_PATCH_TESSELLATION; gv++ )
			{
				for ( int gu = 0; gu < RT_PATCH_TESSELLATION; gu++ )
				{
					outVerts->push_back( gridPos[gv][gu] );
					outVerts->push_back( gridPos[gv][gu + 1] );
					outVerts->push_back( gridPos[gv + 1][gu + 1] );
					outNormals->push_back( gridNorm[gv][gu] );
					outNormals->push_back( gridNorm[gv][gu + 1] );
					outNormals->push_back( gridNorm[gv + 1][gu + 1] );

					outVerts->push_back( gridPos[gv][gu] );
					outVerts->push_back( gridPos[gv + 1][gu + 1] );
					outVerts->push_back( gridPos[gv + 1][gu] );
					outNormals->push_back( gridNorm[gv][gu] );
					outNormals->push_back( gridNorm[gv + 1][gu + 1] );
					outNormals->push_back( gridNorm[gv + 1][gu] );
				}
			}
		}
	}
}

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
	// count first so the final buffer can be reserved close to its real
	// size up front, then fill it - simpler than a growable buffer for a
	// one-shot, load-time operation. (Patch surfaces still grow the
	// vector dynamically past this reservation - their final vertex
	// count depends on RT_PATCH_TESSELLATION, not worth a second exact
	// pre-count for a load-time operation.)
	int totalVerts = 0;
	int numPlanarSurfaces = 0;
	int numPatchSurfaces = 0;
	int numSkippedSurfaces = 0;
	for ( int i = 0; i < numSurfaces; i++ )
	{
		if ( surfaces[i].surfaceType == MST_PLANAR )
		{
			totalVerts += surfaces[i].numIndexes;
			numPlanarSurfaces++;
		}
		else if ( surfaces[i].surfaceType == MST_PATCH )
		{
			numPatchSurfaces++;
		}
		else if ( surfaces[i].surfaceType != MST_BAD )
		{
			numSkippedSurfaces++;
		}
	}

	if ( numSkippedSurfaces > 0 )
	{
		ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar, %d patch surfaces loaded, "
			"%d other surfaces (triangle-soup/terrain/flares) skipped - not implemented yet\n",
			name, numPlanarSurfaces, numPatchSurfaces, numSkippedSurfaces );
	}

	if ( totalVerts == 0 && numPatchSurfaces == 0 )
	{
		ri.FS_FreeFile( fileData );
		return;
	}

	// Flat, non-indexed triangle list - simplest thing that reuses the
	// existing entity pipeline's vertex layout (device float3
	// *positions, parallel device float3 *normals) unchanged. World-space
	// already; BSP vertex positions/normals need no per-surface
	// transform.
	std::vector<simd_float3> worldVerts;
	std::vector<simd_float3> worldNormals;
	worldVerts.reserve( totalVerts );
	worldNormals.reserve( totalVerts );

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
			const float *normal = surfVerts[vertIndex].normal;
			worldVerts.push_back( simd_make_float3( xyz[0], xyz[1], xyz[2] ) );
			worldNormals.push_back( simd_make_float3( normal[0], normal[1], normal[2] ) );
		}
	}

	for ( int i = 0; i < numSurfaces; i++ )
	{
		if ( surfaces[i].surfaceType == MST_PATCH )
			RT_TessellatePatchSurface( &surfaces[i], allVerts, &worldVerts, &worldNormals );
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
	rtWorldNormalBuffer = [RT_GetDevice() newBufferWithBytes:worldNormals.data()
	                                                   length:worldNormals.size() * sizeof( simd_float3 )
	                                                  options:MTLResourceStorageModeShared];

	ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar, %d patch surfaces, %d verts uploaded\n",
		name, numPlanarSurfaces, numPatchSurfaces, rtWorldVertexCount );
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
	// so the model matrix is identity: MVP == viewProj, and normals need
	// no rotation either (identity 3x3).
	simd_float4x4 mvp = viewProj;
	[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
	[encoder setVertexBuffer:rtWorldNormalBuffer offset:0 atIndex:2];
	simd_float3x3 identityNormalMatrix = {
		simd_make_float3( 1, 0, 0 ), simd_make_float3( 0, 1, 0 ), simd_make_float3( 0, 0, 1 )
	};
	[encoder setVertexBytes:&identityNormalMatrix length:sizeof( identityNormalMatrix ) atIndex:3];

	// Neutral gray, distinct from the entity placeholders' magenta -
	// this is real (if untextured) level geometry, not a stand-in.
	simd_float4 worldColor = simd_make_float4( 0.6f, 0.6f, 0.6f, 1.0f );
	[encoder setFragmentBytes:&worldColor length:sizeof( worldColor ) atIndex:0];
	simd_float3 lightDir = RT_GetLightDir();
	[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:1];

	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:rtWorldVertexCount];
}

void RT_InitWorldFunctions( refexport_t *re )
{
	re->LoadWorld = RT_LoadWorld;
}
