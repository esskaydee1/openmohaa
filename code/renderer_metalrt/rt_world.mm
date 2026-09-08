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
// Session 23: real per-surface lightmaps - see rt_scene.mm.
bool RT_EnsurePipelineLightmap3D( void );
void RT_DrawLightmappedGeometry( id<MTLBuffer> vertexBuffer, id<MTLBuffer> texcoordBuffer, id<MTLBuffer> lightmapTexcoordBuffer,
	int vertexStart, int vertexCount, simd_float4x4 mvp, id<MTLTexture> texture, id<MTLTexture> lightmapTexture );
// Session 24: real ray tracing - see rt_raytrace.mm. Built once per
// LoadWorld (world geometry doesn't change mid-map), from the same
// vertex buffer rasterization already produces.
void RT_BuildWorldAccelStructure( void );

// rt_image.mm (not anonymous-namespace-scoped there) - session 14
// reuses these to resolve a world surface's shader name to a texture
// the exact same way rt_scene.mm's TIKI surfaces already do.
qhandle_t RT_RegisterImageCommon( const char *name );
id<MTLTexture> RT_GetImageTexture( qhandle_t handle );
rtBlendMode_t RT_GetImageBlendMode( qhandle_t handle );

// rt_image.mm - session 22's skybox needs both the raw pixel loader
// (for its 6 cube faces, not registered as ordinary 2D shader handles)
// and the sky-specific shader-script scan (a sky shader has no map/
// clampmap stage, so RT_RegisterImageCommon above correctly never
// resolves one to a texture handle).
byte *RT_LoadImageFile( const char *name, int *width, int *height );
bool RT_FindShaderSkyParms( const char *shaderName, char *outBasePath, size_t outBasePathSize );
// Session 23: also reused directly for lightmap tiles (RGBA upload,
// same as any other 2D texture) - no reason to duplicate this.
id<MTLTexture> RT_CreateTexture( const byte *rgba, int width, int height );

namespace {

id<MTLBuffer> rtWorldVertexBuffer = nil;
id<MTLBuffer> rtWorldNormalBuffer = nil;
// Session 14: parallel to rtWorldVertexBuffer/rtWorldNormalBuffer -
// always baked (from drawVert_t::st, already present in the BSP data),
// same reasoning as rt_scene.mm's TIKI texcoord buffer.
id<MTLBuffer> rtWorldTexcoordBuffer = nil;
// Session 23: parallel again - drawVert_t::lightmap, the SECOND (real,
// pre-baked) set of texcoords every lightmapped surface's vertices
// already carry. Always baked alongside worldTexcoords regardless of
// whether a given group ends up using it (simplest - a group without a
// real lightmap for this shader just never binds this buffer/pipeline).
id<MTLBuffer> rtWorldLightmapTexcoordBuffer = nil;
// Session 24: one simd_float3 per TRIANGLE (not per vertex) - see
// RT_GetAverageTextureColor below.
id<MTLBuffer> rtWorldTriangleColorBuffer = nil;
int rtWorldVertexCount = 0;

// Session 23: real per-tile lightmap textures, see RT_LoadWorld's lump
// read - one real Metal texture per LUMP_LIGHTMAPS tile, indexed
// directly by dsurface_t::lightmapNum/cTerraPatch_t::iLightMap.
#define RT_LIGHTMAP_SIZE 128
#define MAX_RT_LIGHTMAPS 256
id<MTLTexture> rtLightmapTextures[MAX_RT_LIGHTMAPS];
int numRtLightmapTextures = 0;

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
// Session 23: now grouped by (shaderIdx, lightmapNum) pairs, not just
// shaderIdx - two surfaces can share a diffuse shader but use different
// baked lightmap tiles, and each needs its own draw call to bind the
// right lightmap texture. lightmapTexture is nil for groups with no
// real lightmap (LIGHTMAP_NONE, or terrain - see RT_LoadWorld), which
// keep using the existing flat-directional-light path unchanged.
struct rtWorldGroup_t {
	id<MTLTexture> texture;
	id<MTLTexture> lightmapTexture;
	rtBlendMode_t blendMode;
	int vertexStart;
	int vertexCount;
};

#define MAX_RT_WORLD_GROUPS 2048
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
	simd_float3 *outPos, simd_float3 *outNormal, simd_float2 *outTexcoord, simd_float2 *outLightmapCoord )
{
	float bu[3] = { ( 1.0f - u ) * ( 1.0f - u ), 2.0f * u * ( 1.0f - u ), u * u };
	float bv[3] = { ( 1.0f - v ) * ( 1.0f - v ), 2.0f * v * ( 1.0f - v ), v * v };

	simd_float3 pos = simd_make_float3( 0.0f, 0.0f, 0.0f );
	simd_float3 normal = simd_make_float3( 0.0f, 0.0f, 0.0f );
	simd_float2 texcoord = simd_make_float2( 0.0f, 0.0f );
	simd_float2 lightmapCoord = simd_make_float2( 0.0f, 0.0f );
	for ( int j = 0; j < 3; j++ )
	{
		for ( int i = 0; i < 3; i++ )
		{
			float weight = bu[i] * bv[j];
			const float *xyz = ctrl[j][i]->xyz;
			const float *n = ctrl[j][i]->normal;
			const float *st = ctrl[j][i]->st;
			const float *lm = ctrl[j][i]->lightmap;
			pos += weight * simd_make_float3( xyz[0], xyz[1], xyz[2] );
			normal += weight * simd_make_float3( n[0], n[1], n[2] );
			texcoord += weight * simd_make_float2( st[0], st[1] );
			lightmapCoord += weight * simd_make_float2( lm[0], lm[1] );
		}
	}

	*outPos = pos;
	float normalLen = simd_length( normal );
	*outNormal = ( normalLen > 0.0001f ) ? ( normal / normalLen ) : simd_make_float3( 0.0f, 0.0f, 1.0f );
	*outTexcoord = texcoord;
	*outLightmapCoord = lightmapCoord;
}

// Tessellates every 3x3 sub-patch of one MST_PATCH surface at a fixed
// resolution and appends the result to the shared world vertex/normal/
// texcoord arrays - same flat, non-indexed triangle list as planar
// surfaces, so no new pipeline/buffer/draw-call plumbing is needed.
void RT_TessellatePatchSurface( dsurface_t *surf, drawVert_t *allVerts,
	std::vector<simd_float3> *outVerts, std::vector<simd_float3> *outNormals, std::vector<simd_float2> *outTexcoords,
	std::vector<simd_float2> *outLightmapTexcoords )
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
	simd_float2 gridLightmap[RT_PATCH_TESSELLATION + 1][RT_PATCH_TESSELLATION + 1];

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
					RT_EvalBezierPatch3x3( ctrl, u, v, &gridPos[gv][gu], &gridNorm[gv][gu], &gridTex[gv][gu], &gridLightmap[gv][gu] );
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
					outLightmapTexcoords->push_back( gridLightmap[gv][gu] );
					outLightmapTexcoords->push_back( gridLightmap[gv][gu + 1] );
					outLightmapTexcoords->push_back( gridLightmap[gv + 1][gu + 1] );

					outVerts->push_back( gridPos[gv][gu] );
					outVerts->push_back( gridPos[gv + 1][gu + 1] );
					outVerts->push_back( gridPos[gv + 1][gu] );
					outNormals->push_back( gridNorm[gv][gu] );
					outNormals->push_back( gridNorm[gv + 1][gu + 1] );
					outNormals->push_back( gridNorm[gv + 1][gu] );
					outTexcoords->push_back( gridTex[gv][gu] );
					outTexcoords->push_back( gridTex[gv + 1][gu + 1] );
					outTexcoords->push_back( gridTex[gv + 1][gu] );
					outLightmapTexcoords->push_back( gridLightmap[gv][gu] );
					outLightmapTexcoords->push_back( gridLightmap[gv + 1][gu + 1] );
					outLightmapTexcoords->push_back( gridLightmap[gv + 1][gu] );
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

// Session 22: real skybox rendering for shaders that use `skyParms
// <basePath> <cloudHeight> <box>` instead of a map/clampmap stage
// (textures/sky/mohday2 -> skyParms env/mohday2 512 -). The real
// renderer (tr_sky.c) warps a curved sky dome generated from the sky
// surface's own BSP geometry; this renders a fixed-size cube around the
// camera instead (rotation-only view matrix, so it's always centered on
// the player - the camera's position never reaches its faces) sampling
// a real MTLTextureTypeCube built from the shader's 6 face images
// (env/mohday2_{ft,bk,lf,rt,up,dn} - standard idtech3 skybox naming,
// real JPGs already loadable since session 15). Simpler than the real
// dome, and loses the sky surface's own silhouette (a skybox always
// fills 100% of the screen the surface's hole would have shown it
// through) - acceptable for a first pass; matches the same
// real-geometry/simplified-technique tradeoff as MST_PATCH and terrain
// above.
id<MTLTexture> rtSkyCubeTexture = nil;
id<MTLRenderPipelineState> rtSkyPipeline = nil;
id<MTLDepthStencilState> rtSkyDepthState = nil;
id<MTLSamplerState> rtSkySampler = nil;
id<MTLBuffer> rtSkyVertexBuffer = nil;
bool rtHasSky = false;

const char *rtShaderSourceSky =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOutSky { float4 position [[position]]; float3 direction; };\n"
	"vertex VertexOutSky rt_vertex_sky(uint vertexID [[vertex_id]],\n"
	"    const device float3 *positions [[buffer(0)]],\n"
	"    constant float4x4 &viewProj [[buffer(1)]]) {\n"
	"    VertexOutSky out;\n"
	"    float3 pos = positions[vertexID];\n"
	"    out.position = viewProj * float4(pos, 1.0);\n"
	"    out.direction = pos;\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_sky(VertexOutSky in [[stage_in]],\n"
	"    texturecube<float> skyTex [[texture(0)]], sampler samp [[sampler(0)]]) {\n"
	"    return skyTex.sample(samp, in.direction);\n"
	"}\n";

bool RT_EnsureSkyPipeline( void )
{
	if ( rtSkyPipeline != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSourceSky]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile sky shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"rt_vertex_sky"];
	desc.fragmentFunction = [library newFunctionWithName:@"rt_fragment_sky"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtSkyPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtSkyPipeline == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create sky pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	// Drawn first, behind everything - never tested against (nothing
	// could occlude it yet) and never written (so every real opaque
	// surface, however close, correctly draws over it via ITS OWN
	// normal depth test against the still-cleared-to-far depth buffer).
	MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
	depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
	depthDesc.depthWriteEnabled = NO;
	rtSkyDepthState = [device newDepthStencilStateWithDescriptor:depthDesc];

	MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
	samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
	samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
	rtSkySampler = [device newSamplerStateWithDescriptor:samplerDesc];

	// A cube centered on the origin, comfortably inside [nearZ, farZ]
	// (RT_RenderScene uses 4/8192) regardless of camera position, since
	// the view matrix used to draw it has its translation stripped -
	// only its rotation ever applies, so these LOCAL coordinates are
	// also directly the sample direction (see the vertex shader above).
	const float s = 100.0f;
	static const simd_float3 skyVerts[36] = {
		// +X (forward - engine axis convention, RT_BuildViewMatrix)
		{ s, -s, -s }, { s, s, -s }, { s, s, s }, { s, -s, -s }, { s, s, s }, { s, -s, s },
		// -X
		{ -s, s, -s }, { -s, -s, -s }, { -s, -s, s }, { -s, s, -s }, { -s, -s, s }, { -s, s, s },
		// +Y (left)
		{ s, s, -s }, { -s, s, -s }, { -s, s, s }, { s, s, -s }, { -s, s, s }, { s, s, s },
		// -Y (right)
		{ -s, -s, -s }, { s, -s, -s }, { s, -s, s }, { -s, -s, -s }, { s, -s, s }, { -s, -s, s },
		// +Z (up)
		{ -s, -s, s }, { s, -s, s }, { s, s, s }, { -s, -s, s }, { s, s, s }, { -s, s, s },
		// -Z (down)
		{ -s, s, -s }, { s, s, -s }, { s, -s, -s }, { -s, s, -s }, { s, -s, -s }, { -s, -s, -s },
	};
	rtSkyVertexBuffer = [device newBufferWithBytes:skyVerts length:sizeof( skyVerts ) options:MTLResourceStorageModeShared];

	return true;
}

// Loads the shader's 6 face images into one real MTLTextureTypeCube.
// Metal's fixed cube-slice order is +X,-X,+Y,-Y,+Z,-Z, in WORLD space -
// the sky cube's LOCAL coordinates above are literally world-axis-
// aligned (no extra rotation) and get sampled with the direction
// unchanged (RT_DrawSky only ever rotates them by the camera's current
// orientation, never remaps which axis means what), so this is really
// asking "which face image goes with world +X/-X/+Y/-Y/+Z/-Z" - a
// WORLD-space question, unrelated to which way the camera happens to
// be facing (a first attempt at this table wrongly reasoned from
// RT_BuildViewMatrix's "forward=X" comment, which describes the
// CAMERA's per-frame view axes, not a fixed world direction - there is
// no such thing as a fixed "world forward" in a free-look game, so that
// reasoning didn't even apply). Fixed by reading the real answer
// straight out of the reference engine instead of re-deriving it:
// tr_shader.c's ParseSkyParms loads suf[6]={"rt","bk","lf","ft","up","dn"}
// into shader.sky.outerbox[0..5], and tr_sky.c's MakeSkyVec's
// st_to_vec[axis] table (cross-referenced through sky_texorder) gives,
// for each world-space axis, which outerbox[] index (thus which face
// name) DrawSkySide binds there: +X=outerbox[0]="rt", -X=outerbox[2]="lf",
// +Y=outerbox[1]="bk", -Y=outerbox[3]="ft", +Z=outerbox[4]="up",
// -Z=outerbox[5]="dn" - both renderers load the same .bsp, so world
// axes mean the same thing in both and this table is directly portable,
// not just a guess to verify by eye. A live A/B against the user's own
// report that the original renderer's sky has no visible seams (this
// renderer's first attempt did) is what caught the original table being
// wrong in the first place.
// A real, common asset choice this renderer has to tolerate: the "down"
// face of a skybox is often authored much smaller than the other five
// (players rarely look straight down at it) - env/mohday2_dn is 16x16
// against the other faces' 512x512. Metal requires every face of one
// MTLTextureTypeCube to be identical size, so a mismatched face is
// upscaled (nearest-neighbor - blurrier than the real content deserves,
// but simple, and this face is barely seen) to the size of the first
// face loaded, rather than rejecting the whole sky over one small face.
byte *RT_ResizeRGBANearest( const byte *src, int srcW, int srcH, int dstW, int dstH )
{
	byte *dst = (byte *)ri.Malloc( dstW * dstH * 4 );
	for ( int y = 0; y < dstH; y++ )
	{
		int sy = ( y * srcH ) / dstH;
		if ( sy >= srcH )
			sy = srcH - 1;
		for ( int x = 0; x < dstW; x++ )
		{
			int sx = ( x * srcW ) / dstW;
			if ( sx >= srcW )
				sx = srcW - 1;
			Com_Memcpy( dst + ( y * dstW + x ) * 4, src + ( sy * srcW + sx ) * 4, 4 );
		}
	}
	return dst;
}

bool RT_LoadSkyCubemap( const char *basePath )
{
	struct SkyFaceSpec {
		int slice;
		const char *suffix;
	};
	static const SkyFaceSpec skyFaces[6] = {
		{ 0, "rt" }, { 1, "lf" }, { 2, "bk" }, { 3, "ft" }, { 4, "up" }, { 5, "dn" },
	};

	byte *facePixels[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
	int faceWidth = 0, faceHeight = 0;
	bool ok = true;

	for ( int i = 0; i < 6 && ok; i++ )
	{
		char facePath[MAX_QPATH];
		Com_sprintf( facePath, sizeof( facePath ), "%s_%s", basePath, skyFaces[i].suffix );

		int w = 0, h = 0;
		byte *pixels = RT_LoadImageFile( facePath, &w, &h );
		if ( pixels == NULL )
		{
			ri.Printf( PRINT_WARNING, "renderer_metalrt: sky: couldn't load face \"%s\"\n", facePath );
			ok = false;
			break;
		}

		if ( i == 0 )
		{
			faceWidth = w;
			faceHeight = h;
		}
		else if ( w != faceWidth || h != faceHeight )
		{
			ri.Printf( PRINT_WARNING, "renderer_metalrt: sky: face \"%s\" is %dx%d, resizing to match "
				"the first face's %dx%d\n", facePath, w, h, faceWidth, faceHeight );
			byte *resized = RT_ResizeRGBANearest( pixels, w, h, faceWidth, faceHeight );
			ri.Free( pixels );
			pixels = resized;
		}

		facePixels[skyFaces[i].slice] = pixels;
	}

	if ( !ok )
	{
		for ( int i = 0; i < 6; i++ )
			if ( facePixels[i] != NULL )
				ri.Free( facePixels[i] );
		return false;
	}

	MTLTextureDescriptor *desc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
	                                                                                    size:faceWidth
	                                                                               mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead;
	rtSkyCubeTexture = [RT_GetDevice() newTextureWithDescriptor:desc];

	MTLRegion region = MTLRegionMake2D( 0, 0, faceWidth, faceHeight );
	for ( int slice = 0; slice < 6; slice++ )
	{
		[rtSkyCubeTexture replaceRegion:region
		                     mipmapLevel:0
		                           slice:slice
	                           withBytes:facePixels[slice]
	                         bytesPerRow:faceWidth * 4
	                       bytesPerImage:faceWidth * faceHeight * 4];
		ri.Free( facePixels[slice] );
	}

	return true;
}

// Session 24: the ray-traced pass shades every hit by real geometric
// normal + a real traced shadow ray (see rt_raytrace.mm) - it computes
// its own lighting from the actual scene, so it never needs the
// lightmap approximation the rasterized path relies on. It does still
// need a base albedo color per surface, though, and doesn't yet have
// real per-pixel texture sampling (no bindless texture array wired up
// this session) - so this samples a small grid of a group's already-
// resolved diffuse texture and averages it into one representative
// color, real material color (grass reads green, wood reads brown, sky
// reads whatever the clear color is) instead of one uniform flat gray
// for every surface. Coarser than real texturing, but a meaningfully
// fairer comparison than no color information at all - a real, if
// low-resolution, fact about each surface, not a placeholder.
simd_float3 RT_GetAverageTextureColor( id<MTLTexture> texture )
{
	if ( texture == nil )
		return simd_make_float3( 0.6f, 0.6f, 0.6f ); // matches RT_DrawWorld's flat-fallback gray

	const int sampleGrid = 8;
	int width = (int)texture.width;
	int height = (int)texture.height;
	if ( width <= 0 || height <= 0 )
		return simd_make_float3( 0.6f, 0.6f, 0.6f );

	long sumR = 0, sumG = 0, sumB = 0;
	int numSamples = 0;
	byte pixel[4];
	for ( int gy = 0; gy < sampleGrid; gy++ )
	{
		int y = ( gy * height ) / sampleGrid;
		for ( int gx = 0; gx < sampleGrid; gx++ )
		{
			int x = ( gx * width ) / sampleGrid;
			MTLRegion region = MTLRegionMake2D( x, y, 1, 1 );
			[texture getBytes:pixel bytesPerRow:4 fromRegion:region mipmapLevel:0];
			sumR += pixel[0];
			sumG += pixel[1];
			sumB += pixel[2];
			numSamples++;
		}
	}

	return simd_make_float3( (float)sumR / ( numSamples * 255.0f ),
		(float)sumG / ( numSamples * 255.0f ),
		(float)sumB / ( numSamples * 255.0f ) );
}

} // namespace

void RT_DrawSky( simd_float4x4 view, simd_float4x4 proj )
{
	if ( !rtHasSky || rtSkyCubeTexture == nil )
		return;
	if ( !RT_EnsureSkyPipeline() )
		return;

	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	// Strip translation - the sky must always appear centered on the
	// camera regardless of where in the map it's standing, only ever
	// rotating with the view.
	simd_float4x4 viewNoTranslation = view;
	viewNoTranslation.columns[3] = simd_make_float4( 0.0f, 0.0f, 0.0f, 1.0f );
	simd_float4x4 skyViewProj = simd_mul( proj, viewNoTranslation );

	[encoder setRenderPipelineState:rtSkyPipeline];
	[encoder setDepthStencilState:rtSkyDepthState];
	[encoder setVertexBuffer:rtSkyVertexBuffer offset:0 atIndex:0];
	[encoder setVertexBytes:&skyViewProj length:sizeof( skyViewProj ) atIndex:1];
	[encoder setFragmentTexture:rtSkyCubeTexture atIndex:0];
	[encoder setFragmentSamplerState:rtSkySampler atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];
}

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
	lump_t *lightmapsLump = Q_GetLumpByVersion( header, LUMP_LIGHTMAPS );

	if ( shadersLump->filelen % sizeof( dshader_t ) || surfsLump->filelen % sizeof( dsurface_t )
		|| vertsLump->filelen % sizeof( drawVert_t ) || indexLump->filelen % sizeof( int )
		|| terrainLump->filelen % sizeof( cTerraPatch_t )
		|| lightmapsLump->filelen % ( RT_LIGHTMAP_SIZE * RT_LIGHTMAP_SIZE * 3 ) )
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
	int numLightmapTiles = lightmapsLump->filelen / ( RT_LIGHTMAP_SIZE * RT_LIGHTMAP_SIZE * 3 );
	byte *lightmapData = fileData + lightmapsLump->fileofs;

	// Session 23: real per-surface lightmaps. LUMP_LIGHTMAPS is a raw,
	// headerless array of RT_LIGHTMAP_SIZE^2*3 (RGB, no alpha) tiles -
	// one real Metal texture per tile, converted to RGBA (Metal has no
	// 3-channel format worth the complexity of a second code path for
	// just this). Every dsurface_t/cTerraPatch_t's lightmapNum/iLightMap
	// is simply an index into this array (LIGHTMAP_NONE = -1 means "no
	// lightmap" - a real, valid case, not a bug, e.g. sky). Freed and
	// rebuilt every LoadWorld like everything else here - not kept
	// across map loads.
	for ( int i = 0; i < numRtLightmapTextures; i++ )
		rtLightmapTextures[i] = nil;
	numRtLightmapTextures = 0;
	for ( int i = 0; i < numLightmapTiles && i < MAX_RT_LIGHTMAPS; i++ )
	{
		byte *rgb = lightmapData + i * RT_LIGHTMAP_SIZE * RT_LIGHTMAP_SIZE * 3;
		static byte rgba[RT_LIGHTMAP_SIZE * RT_LIGHTMAP_SIZE * 4];
		for ( int p = 0; p < RT_LIGHTMAP_SIZE * RT_LIGHTMAP_SIZE; p++ )
		{
			rgba[p * 4 + 0] = rgb[p * 3 + 0];
			rgba[p * 4 + 1] = rgb[p * 3 + 1];
			rgba[p * 4 + 2] = rgb[p * 3 + 2];
			rgba[p * 4 + 3] = 255;
		}
		rtLightmapTextures[i] = RT_CreateTexture( rgba, RT_LIGHTMAP_SIZE, RT_LIGHTMAP_SIZE );
		numRtLightmapTextures++;
	}
	if ( numLightmapTiles > MAX_RT_LIGHTMAPS )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadWorld: \"%s\" has %d lightmap tiles, "
			"MAX_RT_LIGHTMAPS (%d) hit - surfaces past that index draw unlit\n",
			name, numLightmapTiles, MAX_RT_LIGHTMAPS );
	}

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
	std::vector<simd_float2> worldLightmapTexcoords;

	numRtWorldGroups = 0;
	int numTexturedGroups = 0;
	int numLightmappedGroups = 0;

	// Reset per-map, not left over from whatever the previous LoadWorld
	// (a different map, or a vid_restart of this one) set - a map with
	// no sky shader at all must not keep rendering the last one's.
	rtHasSky = false;
	rtSkyCubeTexture = nil;

	// Adds a group spanning [groupStart, current end) if it's non-empty,
	// resolving lightmapNum to a real texture (nil if none/out of
	// range). Shared by the terrain sub-group and every (shaderIdx,
	// lightmapNum) sub-group below - factored out once restructuring for
	// per-lightmap sub-grouping made "add a group" a multi-line, easy-
	// to-typo-twice operation instead of the single assignment it used
	// to be.
	auto addGroup = [&]( int groupStart, id<MTLTexture> texture, rtBlendMode_t blendMode, int lightmapNum )
	{
		int groupCount = (int)worldVerts.size() - groupStart;
		if ( groupCount == 0 )
			return;

		id<MTLTexture> lightmapTexture = nil;
		if ( lightmapNum >= 0 && lightmapNum < numRtLightmapTextures )
		{
			lightmapTexture = rtLightmapTextures[lightmapNum];
			numLightmappedGroups++;
		}

		if ( numRtWorldGroups < MAX_RT_WORLD_GROUPS )
		{
			rtWorldGroup_t *group = &rtWorldGroups[numRtWorldGroups++];
			group->texture = texture;
			group->lightmapTexture = lightmapTexture;
			group->blendMode = blendMode;
			group->vertexStart = groupStart;
			group->vertexCount = groupCount;
		}
		else
		{
			ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadWorld: \"%s\" hit MAX_RT_WORLD_GROUPS (%d), "
				"dropping a group's geometry\n", name, MAX_RT_WORLD_GROUPS );
		}
	};

	for ( int shaderIdx = 0; shaderIdx < numShaders; shaderIdx++ )
	{
		// Real .shader-script/direct-image resolution, exactly like
		// rt_scene.mm's TIKI surface texturing (session 7-8) - most
		// world shaders are more complex than a single map/clampmap
		// stage (fog, procedural stages), so a nil result here is
		// expected for some, not a bug; those groups draw through the
		// flat-gray fallback pipeline instead, same as every world
		// surface did before session 14.
		id<MTLTexture> texture = nil;
		rtBlendMode_t blendMode = RT_BLEND_OPAQUE;
		bool isSky = false;
		if ( shaders[shaderIdx].shader[0] != '\0' )
		{
			qhandle_t handle = RT_RegisterImageCommon( shaders[shaderIdx].shader );
			if ( handle != 0 )
			{
				texture = RT_GetImageTexture( handle );
				blendMode = RT_GetImageBlendMode( handle );
				numTexturedGroups++;
			}
			else
			{
				// Session 22: a sky shader never resolves via
				// RT_RegisterImageCommon above (it has no map/clampmap
				// stage) - check separately whether that's WHY it failed.
				// One skybox per map (the common case, matching the real
				// renderer's own "current sky" concept) - first one found
				// wins; a map with more than one sky shader in actual use
				// is a real, separate gap, not something silently wrong
				// here.
				char skyBasePath[MAX_QPATH];
				if ( !rtHasSky && RT_FindShaderSkyParms( shaders[shaderIdx].shader, skyBasePath, sizeof( skyBasePath ) ) )
				{
					rtHasSky = RT_LoadSkyCubemap( skyBasePath );
					if ( rtHasSky )
						isSky = true;
				}
			}
		}

		if ( isSky )
		{
			// The skybox render (RT_DrawSky) replaces this shader's
			// surfaces entirely - it fills the whole view, not just this
			// specific surface's own silhouette, so its real BSP geometry
			// would only ever draw over/under the skybox for no visible
			// benefit. No geometry has been gathered yet at this point
			// (moved the texture/sky resolution before gathering,
			// session 23), so there's nothing to roll back.
			continue;
		}

		// Terrain patches are keyed by their own iShader field into this
		// SAME shader lump (session 21) - not a dsurface_t, so they
		// don't appear in the surfaces[] scan below. Grouped separately
		// from the (shaderIdx, lightmapNum) sub-groups below: terrain's
		// own lightmap UV convention (cTerraPatch_t::lmapStep/lmapSize,
		// tr_terrain.c) is a different, more involved system than
		// drawVert_t's simple per-vertex lightmap UV - real, separate
		// work, so terrain keeps the existing flat-directional-light
		// path unchanged (lightmapNum always -1 here) rather than
		// pushing wrong/meaningless lightmap texcoords.
		{
			int terrainGroupStart = (int)worldVerts.size();
			for ( int t = 0; t < numTerrainPatches; t++ )
			{
				if ( terrainPatches[t].iShader != shaderIdx )
					continue;
				RT_TessellateTerrainPatch( &terrainPatches[t], &worldVerts, &worldNormals, &worldTexcoords );
				worldLightmapTexcoords.resize( worldVerts.size(), simd_make_float2( 0.0f, 0.0f ) );
			}
			addGroup( terrainGroupStart, texture, blendMode, -1 );
		}

		// Session 23: regular surfaces sub-grouped by lightmapNum, not
		// just shaderIdx - two surfaces can share a diffuse shader but
		// use different baked lightmap tiles (very common: each maps to
		// wherever the level compiler happened to pack its lightmap),
		// and each combination needs its own draw call to bind the
		// right lightmap texture. Collecting the small set of DISTINCT
		// lightmapNum values this shaderIdx's surfaces actually use
		// first, rather than looping every possible lightmap index
		// against every surface, keeps this to roughly one pass over
		// numSurfaces per shader instead of one pass per (shader,
		// lightmap) pair.
		std::vector<int> lightmapNumsForShader;
		for ( int i = 0; i < numSurfaces; i++ )
		{
			if ( surfaces[i].shaderNum != shaderIdx )
				continue;
			int lm = surfaces[i].lightmapNum;
			bool seen = false;
			for ( int existing : lightmapNumsForShader )
			{
				if ( existing == lm )
				{
					seen = true;
					break;
				}
			}
			if ( !seen )
				lightmapNumsForShader.push_back( lm );
		}

		for ( int lightmapNum : lightmapNumsForShader )
		{
			int groupStart = (int)worldVerts.size();

			for ( int i = 0; i < numSurfaces; i++ )
			{
				dsurface_t *surf = &surfaces[i];
				if ( surf->shaderNum != shaderIdx || surf->lightmapNum != lightmapNum )
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
						const float *lm = surfVerts[vertIndex].lightmap;
						worldVerts.push_back( simd_make_float3( xyz[0], xyz[1], xyz[2] ) );
						worldNormals.push_back( simd_make_float3( normal[0], normal[1], normal[2] ) );
						worldTexcoords.push_back( simd_make_float2( st[0], st[1] ) );
						worldLightmapTexcoords.push_back( simd_make_float2( lm[0], lm[1] ) );
					}
				}
				else if ( surf->surfaceType == MST_PATCH )
				{
					RT_TessellatePatchSurface( surf, allVerts, &worldVerts, &worldNormals, &worldTexcoords, &worldLightmapTexcoords );
				}
			}

			addGroup( groupStart, texture, blendMode, lightmapNum );
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
	rtWorldLightmapTexcoordBuffer = [RT_GetDevice() newBufferWithBytes:worldLightmapTexcoords.data()
	                                                             length:worldLightmapTexcoords.size() * sizeof( simd_float2 )
	                                                            options:MTLResourceStorageModeShared];

	// Session 24: one real average-albedo color per TRIANGLE (not per
	// vertex - the ray tracer indexes this by primitive_id), filled from
	// each group's own already-resolved texture. A cache keyed by
	// texture pointer avoids re-reading the same texture's pixels for
	// every group that happens to share it (e.g. the same wood texture
	// used across many separate surfaces).
	{
		int numTriangles = rtWorldVertexCount / 3;
		std::vector<simd_float3> triangleColors( numTriangles, simd_make_float3( 0.6f, 0.6f, 0.6f ) );
		std::vector<id<MTLTexture>> seenTextures;
		std::vector<simd_float3> seenColors;
		for ( int g = 0; g < numRtWorldGroups; g++ )
		{
			rtWorldGroup_t *group = &rtWorldGroups[g];
			simd_float3 color;
			bool found = false;
			for ( size_t s = 0; s < seenTextures.size(); s++ )
			{
				if ( seenTextures[s] == group->texture )
				{
					color = seenColors[s];
					found = true;
					break;
				}
			}
			if ( !found )
			{
				color = RT_GetAverageTextureColor( group->texture );
				seenTextures.push_back( group->texture );
				seenColors.push_back( color );
			}

			int firstTri = group->vertexStart / 3;
			int lastTri = ( group->vertexStart + group->vertexCount ) / 3;
			for ( int t = firstTri; t < lastTri && t < numTriangles; t++ )
				triangleColors[t] = color;
		}

		rtWorldTriangleColorBuffer = [RT_GetDevice() newBufferWithBytes:triangleColors.data()
		                                                          length:triangleColors.size() * sizeof( simd_float3 )
		                                                         options:MTLResourceStorageModeShared];
	}

	// Session 23 note: numTexturedGroups/numShaders counts DISTINCT
	// SHADERS that resolved a texture (unchanged meaning since session
	// 14); numRtWorldGroups is now draw-call groups after per-lightmap
	// sub-grouping, a bigger and unrelated number - reported separately
	// so the two don't get compared against each other misleadingly.
	ri.Printf( PRINT_ALL, "renderer_metalrt: LoadWorld: \"%s\": %d planar, %d patch surfaces, %d terrain patches, "
		"%d verts, %d/%d shaders resolved, %d draw groups (%d lightmapped), %d lightmap tiles\n",
		name, numPlanarSurfaces, numPatchSurfaces, numTerrainPatches, rtWorldVertexCount, numTexturedGroups, numShaders,
		numRtWorldGroups, numLightmappedGroups, numRtLightmapTextures );

	// Session 24: real ray tracing, built from the exact same non-indexed
	// world triangle soup rasterization has used since session 4 - the
	// geometry extraction work was never the part that needed replacing,
	// only the lighting model on top of it.
	RT_BuildWorldAccelStructure();
}

id<MTLBuffer> RT_GetWorldVertexBuffer( void )
{
	return rtWorldVertexBuffer;
}

int RT_GetWorldVertexCount( void )
{
	return rtWorldVertexCount;
}

id<MTLBuffer> RT_GetWorldTriangleColorBuffer( void )
{
	return rtWorldTriangleColorBuffer;
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
	bool haveLightmapPipeline = RT_EnsurePipelineLightmap3D();

	for ( int i = 0; i < numRtWorldGroups; i++ )
	{
		rtWorldGroup_t *group = &rtWorldGroups[i];

		if ( group->texture != nil && group->lightmapTexture != nil && haveLightmapPipeline )
		{
			// Session 23: a real lightmap replaces the flat directional
			// light entirely for this group - it already encodes real,
			// pre-baked shading (including self-occlusion a single
			// global light direction can't represent) computed from the
			// actual level geometry at compile time.
			RT_DrawLightmappedGeometry( rtWorldVertexBuffer, rtWorldTexcoordBuffer, rtWorldLightmapTexcoordBuffer,
				group->vertexStart, group->vertexCount, mvp, group->texture, group->lightmapTexture );
		}
		else if ( group->texture != nil && haveTexturedPipeline )
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
