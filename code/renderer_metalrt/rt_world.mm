/*
===========================================================================
renderer_metalrt - Phase 1 session 4: real world/BSP geometry (LoadWorld).
Session 11 adds MST_PATCH (curved surfaces - arches, pipes, rounded
terrain detail). Session 21 adds real MoHAA heightmap terrain
(LUMP_TERRAIN/cTerraPatch_t) - a separate lump from LUMP_SURFACES
entirely, NOT the dsurface_t MST_TERRAIN enum value below (this BSP
format's surfaces never actually use that value - real terrain lives in
its own dedicated format, see RT_TessellateTerrainPatch).

MST_TRIANGLE_SOUP and MST_FLARE are still real, separate work for a
later session - skipped here, not silently dropped: see the surfaceType
switch below. No textures, no lightmaps, no visibility culling (PVS)
yet either - every planar/patch surface and terrain patch in the map
draws, every frame, as flat (session 10: lit) gray geometry through the
same depth-tested 3D pipeline entity placeholders use (rt_scene.mm),
or through a real texture where its shader resolves (session 14). That's
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
bool RT_EnsurePipelineTextured3D( void );
void RT_DrawTexturedGeometry( id<MTLBuffer> vertexBuffer, id<MTLBuffer> texcoordBuffer, id<MTLBuffer> normalBuffer,
	int vertexStart, int vertexCount, simd_float4x4 mvp, simd_float3x3 normalMatrix,
	id<MTLTexture> texture, rtBlendMode_t blendMode, simd_float3 lightDir );

// rt_image.mm (not anonymous-namespace-scoped there) - session 14
// reuses these to resolve a world surface's shader name to a texture
// the exact same way rt_scene.mm's TIKI surfaces already do.
qhandle_t RT_RegisterImageCommon( const char *name );
id<MTLTexture> RT_GetImageTexture( qhandle_t handle );
rtBlendMode_t RT_GetImageBlendMode( qhandle_t handle );

namespace {

id<MTLBuffer> rtWorldVertexBuffer = nil;
id<MTLBuffer> rtWorldNormalBuffer = nil;
// Session 14: parallel to rtWorldVertexBuffer/rtWorldNormalBuffer -
// always baked (from drawVert_t::st, already present in the BSP data),
// same reasoning as rt_scene.mm's TIKI texcoord buffer.
id<MTLBuffer> rtWorldTexcoordBuffer = nil;
int rtWorldVertexCount = 0;

// Session 14: one real texture (or nil - flat gray fallback, most
// .shader-script names still don't resolve to a direct image or a
// script this parser understands) per unique BSP shader actually used
// by the map, with the [vertexStart, vertexStart+vertexCount) range of
// the single shared vertex/texcoord/normal buffers above that belongs
// to it. World geometry has no index buffer (session 4's design, a
// flat non-indexed triangle list) - grouping by contiguous vertex
// RANGE per shader (built by processing surfaces shader-by-shader,
// not surface-by-surface) is the non-indexed equivalent of
// rt_scene.mm's per-surface indexOffset/indexCount.
struct rtWorldGroup_t {
	id<MTLTexture> texture;
	rtBlendMode_t blendMode;
	int vertexStart;
	int vertexCount;
};

#define MAX_RT_WORLD_GROUPS 1024
rtWorldGroup_t rtWorldGroups[MAX_RT_WORLD_GROUPS];
int numRtWorldGroups = 0;

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
void RT_EvalBezierPatch3x3( const drawVert_t *ctrl[3][3], float u, float v,
	simd_float3 *outPos, simd_float3 *outNormal, simd_float2 *outTexcoord )
{
	float bu[3] = { ( 1.0f - u ) * ( 1.0f - u ), 2.0f * u * ( 1.0f - u ), u * u };
	float bv[3] = { ( 1.0f - v ) * ( 1.0f - v ), 2.0f * v * ( 1.0f - v ), v * v };

	simd_float3 pos = simd_make_float3( 0.0f, 0.0f, 0.0f );
	simd_float3 normal = simd_make_float3( 0.0f, 0.0f, 0.0f );
	simd_float2 texcoord = simd_make_float2( 0.0f, 0.0f );
	for ( int j = 0; j < 3; j++ )
	{
		for ( int i = 0; i < 3; i++ )
		{
			float weight = bu[i] * bv[j];
			const float *xyz = ctrl[j][i]->xyz;
			const float *n = ctrl[j][i]->normal;
			const float *st = ctrl[j][i]->st;
			pos += weight * simd_make_float3( xyz[0], xyz[1], xyz[2] );
			normal += weight * simd_make_float3( n[0], n[1], n[2] );
			texcoord += weight * simd_make_float2( st[0], st[1] );
		}
	}

	*outPos = pos;
	float normalLen = simd_length( normal );
	*outNormal = ( normalLen > 0.0001f ) ? ( normal / normalLen ) : simd_make_float3( 0.0f, 0.0f, 1.0f );
	*outTexcoord = texcoord;
}

// Tessellates every 3x3 sub-patch of one MST_PATCH surface at a fixed
// resolution and appends the result to the shared world vertex/normal/
// texcoord arrays - same flat, non-indexed triangle list as planar
// surfaces, so no new pipeline/buffer/draw-call plumbing is needed.
void RT_TessellatePatchSurface( dsurface_t *surf, drawVert_t *allVerts,
	std::vector<simd_float3> *outVerts, std::vector<simd_float3> *outNormals, std::vector<simd_float2> *outTexcoords )
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
	simd_float2 gridTex[RT_PATCH_TESSELLATION + 1][RT_PATCH_TESSELLATION + 1];

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
					RT_EvalBezierPatch3x3( ctrl, u, v, &gridPos[gv][gu], &gridNorm[gv][gu], &gridTex[gv][gu] );
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
					outTexcoords->push_back( gridTex[gv][gu] );
					outTexcoords->push_back( gridTex[gv][gu + 1] );
					outTexcoords->push_back( gridTex[gv + 1][gu + 1] );

					outVerts->push_back( gridPos[gv][gu] );
					outVerts->push_back( gridPos[gv + 1][gu + 1] );
					outVerts->push_back( gridPos[gv + 1][gu] );
					outNormals->push_back( gridNorm[gv][gu] );
					outNormals->push_back( gridNorm[gv + 1][gu + 1] );
					outNormals->push_back( gridNorm[gv + 1][gu] );
					outTexcoords->push_back( gridTex[gv][gu] );
					outTexcoords->push_back( gridTex[gv + 1][gu + 1] );
					outTexcoords->push_back( gridTex[gv + 1][gu] );
				}
			}
		}
	}
}

// Session 21: MoHAA's real heightmap-based terrain (LUMP_TERRAIN/
// LUMP_TERRAININDEXES, cTerraPatch_t) turned out to be a SEPARATE format
// from LUMP_SURFACES entirely - not one of dsurface_t's surfaceType
// values, so it was invisible to every session before this one despite
// MST_TERRAIN's enum value existing (this BSP format's actual surfaces
// never use it; terrain patches live in their own dedicated lump). This
// went unnoticed until a live visual bug report ("sheet of paper
// wrapping the road") turned out to be resolved-but-badly-lit sky-shader
// fallback fill in one spot, and led to checking for other geometry
// gaps - training.bsp has 80 real terrain patches (its outer hillsides)
// that were simply never read.
//
// Real terrain rendering (code/renderergl2/tr_terrain.c, ~1700 lines) is
// a recursive ROAM-style bintree with per-vertex view-dependent LOD and
// cross-patch neighbor stitching (iNorth/iEast/iSouth/iWest) - the same
// "real geometry, fixed tessellation instead of adaptive LOD" tradeoff
// already made for MST_PATCH above is applied here too: every patch
// always renders at full fixed resolution (9x9 heightmap samples, 8x8
// quads = 128 triangles), with vertex positions and the checkerboard
// diagonal split verified byte-for-byte against cm_terrain.c's
// CM_GenerateTerrainCollide (the collision code, which needs exactly
// the same positions the renderer does to be consistent) - not against
// tr_terrain.c's LOD-specific code, which only ever emits the full grid
// as an end state of recursive midpoint splitting, never directly.
// Per-vertex normals come from a central-difference heightmap slope
// (standard technique), not the real renderer's normal source, since
// cTerraPatch_t carries no per-vertex normal data of its own - a
// deliberate approximation, not an attempt to match tr_terrain.c's own
// (LOD-tree-dependent) normal computation.
void RT_TessellateTerrainPatch( const cTerraPatch_t *patch,
	std::vector<simd_float3> *outVerts, std::vector<simd_float3> *outNormals, std::vector<simd_float2> *outTexcoords )
{
	float x0 = (float)( (int)patch->x << 6 );
	float y0 = (float)( (int)patch->y << 6 );
	float z0 = (float)patch->iBaseHeight;

	simd_float3 gridPos[9][9];
	simd_float2 gridTex[9][9];
	simd_float3 gridNorm[9][9];

	simd_float2 uv00 = simd_make_float2( patch->texCoord[0][0][0], patch->texCoord[0][0][1] );
	simd_float2 uv10 = simd_make_float2( patch->texCoord[1][0][0], patch->texCoord[1][0][1] );
	simd_float2 uv01 = simd_make_float2( patch->texCoord[0][1][0], patch->texCoord[0][1][1] );
	simd_float2 uv11 = simd_make_float2( patch->texCoord[1][1][0], patch->texCoord[1][1][1] );

	for ( int row = 0; row < 9; row++ )
	{
		for ( int col = 0; col < 9; col++ )
		{
			float wx = x0 + col * 64.0f;
			float wy = y0 + row * 64.0f;
			float wz = z0 + 2.0f * (float)patch->heightmap[row * 9 + col];
			gridPos[row][col] = simd_make_float3( wx, wy, wz );

			// Bilinear across the patch's 4 corner UVs - matches what the
			// real renderer's recursive midpoint-averaging LOD split
			// converges to at full subdivision (repeated linear
			// interpolation of a bilinear field reproduces the same
			// field), see R_PreTessellateTerrain's s00/s01/s10/s11 corner
			// assignment (tr_terrain.c) for the corner/index correspondence
			// this mirrors: texCoord[0][0]=near corner, [1][0]/[0][1] the
			// two adjacent corners, [1][1] the far corner.
			float u = (float)col / 8.0f;
			float v = (float)row / 8.0f;
			simd_float2 top = uv00 + ( uv10 - uv00 ) * u;
			simd_float2 bottom = uv01 + ( uv11 - uv01 ) * u;
			gridTex[row][col] = top + ( bottom - top ) * v;
		}
	}

	for ( int row = 0; row < 9; row++ )
	{
		for ( int col = 0; col < 9; col++ )
		{
			int colL = ( col > 0 ) ? col - 1 : col;
			int colR = ( col < 8 ) ? col + 1 : col;
			int rowD = ( row > 0 ) ? row - 1 : row;
			int rowU = ( row < 8 ) ? row + 1 : row;

			simd_float3 tangentX = gridPos[row][colR] - gridPos[row][colL];
			simd_float3 tangentY = gridPos[rowU][col] - gridPos[rowD][col];
			simd_float3 normal = simd_cross( tangentX, tangentY );
			float len = simd_length( normal );
			gridNorm[row][col] = ( len > 0.0001f ) ? ( normal / len ) : simd_make_float3( 0.0f, 0.0f, 1.0f );
		}
	}

	// Checkerboard-alternating diagonal split, verified against
	// CM_GenerateTerrainCollide exactly (its (i+j)&1 branch, i=col,
	// j=row) - not a stylistic choice, a real heightmap mesh has a
	// visible directional bias if every quad splits the same way.
	for ( int row = 0; row < 8; row++ )
	{
		for ( int col = 0; col < 8; col++ )
		{
			simd_float3 v1 = gridPos[row][col];
			simd_float3 v2 = gridPos[row][col + 1];
			simd_float3 v3 = gridPos[row + 1][col + 1];
			simd_float3 v4 = gridPos[row + 1][col];
			simd_float3 n1 = gridNorm[row][col];
			simd_float3 n2 = gridNorm[row][col + 1];
			simd_float3 n3 = gridNorm[row + 1][col + 1];
			simd_float3 n4 = gridNorm[row + 1][col];
			simd_float2 t1 = gridTex[row][col];
			simd_float2 t2 = gridTex[row][col + 1];
			simd_float2 t3 = gridTex[row + 1][col + 1];
			simd_float2 t4 = gridTex[row + 1][col];

			if ( ( col + row ) & 1 )
			{
				outVerts->push_back( v2 ); outVerts->push_back( v4 ); outVerts->push_back( v3 );
				outNormals->push_back( n2 ); outNormals->push_back( n4 ); outNormals->push_back( n3 );
				outTexcoords->push_back( t2 ); outTexcoords->push_back( t4 ); outTexcoords->push_back( t3 );

				outVerts->push_back( v4 ); outVerts->push_back( v2 ); outVerts->push_back( v1 );
				outNormals->push_back( n4 ); outNormals->push_back( n2 ); outNormals->push_back( n1 );
				outTexcoords->push_back( t4 ); outTexcoords->push_back( t2 ); outTexcoords->push_back( t1 );
			}
			else
			{
				outVerts->push_back( v3 ); outVerts->push_back( v1 ); outVerts->push_back( v4 );
				outNormals->push_back( n3 ); outNormals->push_back( n1 ); outNormals->push_back( n4 );
				outTexcoords->push_back( t3 ); outTexcoords->push_back( t1 ); outTexcoords->push_back( t4 );

				outVerts->push_back( v1 ); outVerts->push_back( v3 ); outVerts->push_back( v2 );
				outNormals->push_back( n1 ); outNormals->push_back( n3 ); outNormals->push_back( n2 );
				outTexcoords->push_back( t1 ); outTexcoords->push_back( t3 ); outTexcoords->push_back( t2 );
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

	lump_t *shadersLump = Q_GetLumpByVersion( header, LUMP_SHADERS );
	lump_t *surfsLump = Q_GetLumpByVersion( header, LUMP_SURFACES );
	lump_t *vertsLump = Q_GetLumpByVersion( header, LUMP_DRAWVERTS );
	lump_t *indexLump = Q_GetLumpByVersion( header, LUMP_DRAWINDEXES );
	lump_t *terrainLump = Q_GetLumpByVersion( header, LUMP_TERRAIN );

	if ( shadersLump->filelen % sizeof( dshader_t ) || surfsLump->filelen % sizeof( dsurface_t )
		|| vertsLump->filelen % sizeof( drawVert_t ) || indexLump->filelen % sizeof( int )
		|| terrainLump->filelen % sizeof( cTerraPatch_t ) )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: LoadWorld: \"%s\" has malformed lump sizes\n", name );
		ri.FS_FreeFile( fileData );
		return;
	}

	int numShaders = shadersLump->filelen / sizeof( dshader_t );
	dshader_t *shaders = (dshader_t *)( fileData + shadersLump->fileofs );
	int numSurfaces = surfsLump->filelen / sizeof( dsurface_t );
	dsurface_t *surfaces = (dsurface_t *)( fileData + surfsLump->fileofs );
	drawVert_t *allVerts = (drawVert_t *)( fileData + vertsLump->fileofs );
	int *allIndexes = (int *)( fileData + indexLump->fileofs );
	int numTerrainPatches = terrainLump->filelen / sizeof( cTerraPatch_t );
	cTerraPatch_t *terrainPatches = (cTerraPatch_t *)( fileData + terrainLump->fileofs );

	// Counting pass purely for the summary log line below - doesn't
	// affect how the vectors are built (session 14 groups by shader
	// instead of processing surfaces in file order, so a single
	// up-front reservation size isn't meaningful the way it was before;
	// std::vector grows dynamically, a one-shot load-time cost).
	int numPlanarSurfaces = 0;
	int numPatchSurfaces = 0;
	int numSkippedSurfaces = 0;
	for ( int i = 0; i < numSurfaces; i++ )
	{
		if ( surfaces[i].surfaceType == MST_PLANAR )
			numPlanarSurfaces++;
		else if ( surfaces[i].surfaceType == MST_PATCH )
			numPatchSurfaces++;
		else if ( surfaces[i].surfaceType != MST_BAD )
			numSkippedSurfaces++;
	}

	if ( numSkippedSurfaces > 0 )
	{
		ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar, %d patch surfaces loaded, "
			"%d other surfaces (triangle-soup/flares) skipped - not implemented yet\n",
			name, numPlanarSurfaces, numPatchSurfaces, numSkippedSurfaces );
	}

	if ( numPlanarSurfaces == 0 && numPatchSurfaces == 0 && numTerrainPatches == 0 )
	{
		ri.FS_FreeFile( fileData );
		return;
	}

	// Flat, non-indexed triangle list - simplest thing that reuses the
	// existing entity pipeline's vertex layout (device float3
	// *positions, parallel device float3/float2 *normals/*texcoords)
	// unchanged. World-space already; BSP vertex positions/normals need
	// no per-surface transform.
	//
	// Session 14: built shader-by-shader rather than surface-by-surface
	// (the previous sessions' order) so that each shader's geometry
	// lands in one CONTIGUOUS range of these shared arrays - the
	// non-indexed equivalent of an index buffer's per-surface
	// offset/count, letting RT_DrawWorld issue one real-textured draw
	// call per shader via vertexStart/vertexCount instead of per-vertex
	// texture switching.
	std::vector<simd_float3> worldVerts;
	std::vector<simd_float3> worldNormals;
	std::vector<simd_float2> worldTexcoords;

	numRtWorldGroups = 0;
	int numTexturedGroups = 0;

	for ( int shaderIdx = 0; shaderIdx < numShaders; shaderIdx++ )
	{
		int groupStart = (int)worldVerts.size();

		for ( int i = 0; i < numSurfaces; i++ )
		{
			dsurface_t *surf = &surfaces[i];
			if ( surf->shaderNum != shaderIdx )
				continue;

			if ( surf->surfaceType == MST_PLANAR )
			{
				drawVert_t *surfVerts = allVerts + surf->firstVert;
				int *surfIndexes = allIndexes + surf->firstIndex;

				for ( int j = 0; j < surf->numIndexes; j++ )
				{
					int vertIndex = surfIndexes[j];
					if ( vertIndex < 0 || vertIndex >= surf->numVerts )
						continue; // malformed index - skip rather than read out of bounds

					const float *xyz = surfVerts[vertIndex].xyz;
					const float *normal = surfVerts[vertIndex].normal;
					const float *st = surfVerts[vertIndex].st;
					worldVerts.push_back( simd_make_float3( xyz[0], xyz[1], xyz[2] ) );
					worldNormals.push_back( simd_make_float3( normal[0], normal[1], normal[2] ) );
					worldTexcoords.push_back( simd_make_float2( st[0], st[1] ) );
				}
			}
			else if ( surf->surfaceType == MST_PATCH )
			{
				RT_TessellatePatchSurface( surf, allVerts, &worldVerts, &worldNormals, &worldTexcoords );
			}
		}

		// Session 21: terrain patches are keyed by their own iShader
		// field into this SAME shader lump - not a dsurface_t, so they
		// don't appear in the surfaces[] loop above, but they group into
		// this shaderIdx's contiguous vertex range exactly the same way.
		for ( int t = 0; t < numTerrainPatches; t++ )
		{
			if ( terrainPatches[t].iShader != shaderIdx )
				continue;
			RT_TessellateTerrainPatch( &terrainPatches[t], &worldVerts, &worldNormals, &worldTexcoords );
		}

		int groupCount = (int)worldVerts.size() - groupStart;
		if ( groupCount == 0 )
			continue; // no planar/patch surface in the map actually uses this shader

		// Real .shader-script/direct-image resolution, exactly like
		// rt_scene.mm's TIKI surface texturing (session 7-8) - most
		// world shaders are more complex than a single map/clampmap
		// stage (sky, fog, lightmap-blended multi-stage surfaces), so
		// a nil result here is expected for many, not a bug; those
		// groups draw through the flat-gray fallback pipeline instead,
		// same as every world surface did before this session.
		id<MTLTexture> texture = nil;
		rtBlendMode_t blendMode = RT_BLEND_OPAQUE;
		if ( shaders[shaderIdx].shader[0] != '\0' )
		{
			qhandle_t handle = RT_RegisterImageCommon( shaders[shaderIdx].shader );
			if ( handle != 0 )
			{
				texture = RT_GetImageTexture( handle );
				blendMode = RT_GetImageBlendMode( handle );
				numTexturedGroups++;
			}
		}

		if ( numRtWorldGroups < MAX_RT_WORLD_GROUPS )
		{
			rtWorldGroup_t *group = &rtWorldGroups[numRtWorldGroups++];
			group->texture = texture;
			group->blendMode = blendMode;
			group->vertexStart = groupStart;
			group->vertexCount = groupCount;
		}
		else
		{
			ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadWorld: \"%s\" hit MAX_RT_WORLD_GROUPS (%d), "
				"dropping shader \"%s\"'s geometry\n", name, MAX_RT_WORLD_GROUPS, shaders[shaderIdx].shader );
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
	rtWorldNormalBuffer = [RT_GetDevice() newBufferWithBytes:worldNormals.data()
	                                                   length:worldNormals.size() * sizeof( simd_float3 )
	                                                  options:MTLResourceStorageModeShared];
	rtWorldTexcoordBuffer = [RT_GetDevice() newBufferWithBytes:worldTexcoords.data()
	                                                     length:worldTexcoords.size() * sizeof( simd_float2 )
	                                                    options:MTLResourceStorageModeShared];

	ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar, %d patch surfaces, %d terrain patches, "
		"%d verts, %d/%d shader groups textured\n",
		name, numPlanarSurfaces, numPatchSurfaces, numTerrainPatches, rtWorldVertexCount, numTexturedGroups, numRtWorldGroups );
}

void RT_DrawWorld( simd_float4x4 viewProj )
{
	if ( rtWorldVertexBuffer == nil )
		return;

	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	// No entity transform - world vertices are already in world space,
	// so the model matrix is identity: MVP == viewProj, and normals need
	// no rotation either (identity 3x3).
	simd_float4x4 mvp = viewProj;
	simd_float3x3 identityNormalMatrix = {
		simd_make_float3( 1, 0, 0 ), simd_make_float3( 0, 1, 0 ), simd_make_float3( 0, 0, 1 )
	};
	simd_float3 lightDir = RT_GetLightDir();

	// Deliberately garish-distinct neutral gray (not the entity
	// placeholders' magenta) for any shader group with no resolvable
	// texture - most world shaders are more complex than this parser
	// understands yet (session 14's rt_local.h comment), so this is the
	// common case for many groups, not a bug.
	simd_float4 worldColor = simd_make_float4( 0.6f, 0.6f, 0.6f, 1.0f );

	// Session 14: real per-shader-group textures, mirroring
	// rt_scene.mm's per-surface entity texturing (sessions 7-8) - one
	// draw call per group, textured if a texture resolved, flat gray
	// otherwise, all reading from the SAME shared vertex/normal/texcoord
	// buffers via each group's own [vertexStart, vertexStart+vertexCount)
	// range (there's no index buffer to slice instead).
	bool haveTexturedPipeline = RT_EnsurePipelineTextured3D();

	for ( int i = 0; i < numRtWorldGroups; i++ )
	{
		rtWorldGroup_t *group = &rtWorldGroups[i];

		if ( group->texture != nil && haveTexturedPipeline )
		{
			RT_DrawTexturedGeometry( rtWorldVertexBuffer, rtWorldTexcoordBuffer, rtWorldNormalBuffer,
				group->vertexStart, group->vertexCount, mvp, identityNormalMatrix,
				group->texture, group->blendMode, lightDir );
		}
		else
		{
			[encoder setRenderPipelineState:RT_GetPipeline3D()];
			[encoder setDepthStencilState:RT_GetDepthState3D()];
			[encoder setVertexBuffer:rtWorldVertexBuffer offset:0 atIndex:0];
			[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
			[encoder setVertexBuffer:rtWorldNormalBuffer offset:0 atIndex:2];
			[encoder setVertexBytes:&identityNormalMatrix length:sizeof( identityNormalMatrix ) atIndex:3];
			[encoder setFragmentBytes:&worldColor length:sizeof( worldColor ) atIndex:0];
			[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:1];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle
			             vertexStart:group->vertexStart
			             vertexCount:group->vertexCount];
		}
	}
}

void RT_InitWorldFunctions( refexport_t *re )
{
	re->LoadWorld = RT_LoadWorld;
}
