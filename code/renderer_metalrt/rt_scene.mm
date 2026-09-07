/*
===========================================================================
renderer_metalrt - Phase 1 session 3: minimal RegisterModel + a real 3D
scene path (ClearScene/AddRefEntityToScene/RenderScene).

Deliberately a placeholder, not real model rendering: RegisterModel only
checks that a named .tik file exists (real TIKI parsing/skinning is its
own, much bigger session - see docs/ARCHITECTURE.md's port-scope notes
on TIKI). Every RT_MODEL entity submitted with a valid handle draws as a
flat magenta box at its correct world position/orientation, viewed
through a real camera built from the refdef_t the game actually submits
(fov_x/fov_y, vieworg, viewaxis) - this proves the whole real data path
(registration -> submission -> per-frame scene -> camera -> depth-tested
3D draw) end to end before any real geometry exists to put through it.
===========================================================================
*/
#include "rt_local.h"

#include <math.h>
#include <simd/simd.h>

namespace {

struct rtModel_t {
	char name[MAX_QPATH];
};

#define MAX_RT_MODELS 1024
rtModel_t rtModels[MAX_RT_MODELS]; // index 0 unused - handle 0 is invalid
int numRtModels = 0;

struct rtSceneEntity_t {
	float origin[3];
	float axis[3][3];
};

#define MAX_RT_SCENE_ENTITIES 1024
rtSceneEntity_t rtSceneEntities[MAX_RT_SCENE_ENTITIES];
int numRtSceneEntities = 0;

id<MTLRenderPipelineState> rtPipeline3D = nil;
id<MTLDepthStencilState> rtDepthState3D = nil;
id<MTLBuffer> rtBoxVertexBuffer = nil;
int rtBoxVertexCount = 0;

// Shared by both entity placeholders (magenta) and world geometry (gray,
// see rt_world.mm) - same vertex function, one fragment color uniform
// so both can reuse this one pipeline/depth state rather than each
// needing their own.
const char *rtShaderSource3D =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOut { float4 position [[position]]; };\n"
	"vertex VertexOut rt_vertex_3d(uint vertexID [[vertex_id]],\n"
	"    const device float3 *positions [[buffer(0)]],\n"
	"    constant float4x4 &mvp [[buffer(1)]]) {\n"
	"    VertexOut out;\n"
	"    out.position = mvp * float4(positions[vertexID], 1.0);\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_3d(VertexOut in [[stage_in]],\n"
	"    constant float4 &color [[buffer(0)]]) {\n"
	"    return color;\n"
	"}\n";

} // namespace

// Non-static so rt_world.mm can reuse the same pipeline/depth state
// (world geometry and entity placeholders share both) rather than
// standing up a second, near-identical copy.
bool RT_EnsurePipeline3D( void )
{
	if ( rtPipeline3D != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSource3D]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile 3D shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"rt_vertex_3d"];
	desc.fragmentFunction = [library newFunctionWithName:@"rt_fragment_3d"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtPipeline3D = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtPipeline3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
	depthDesc.depthCompareFunction = MTLCompareFunctionLess;
	depthDesc.depthWriteEnabled = YES;
	rtDepthState3D = [device newDepthStencilStateWithDescriptor:depthDesc];

	// A simple axis-aligned box, roughly player-sized (Quake units),
	// standing on its origin: X/Y +-16, Z from 0 to 64. Non-indexed
	// triangle list (36 verts, 12 tris) - simplest to hardcode directly.
	static const simd_float3 boxVerts[36] = {
		// -Y face
		{ -16, -16, 0 }, { 16, -16, 0 }, { 16, -16, 64 },
		{ -16, -16, 0 }, { 16, -16, 64 }, { -16, -16, 64 },
		// +Y face
		{ 16, 16, 0 }, { -16, 16, 0 }, { -16, 16, 64 },
		{ 16, 16, 0 }, { -16, 16, 64 }, { 16, 16, 64 },
		// -X face
		{ -16, 16, 0 }, { -16, -16, 0 }, { -16, -16, 64 },
		{ -16, 16, 0 }, { -16, -16, 64 }, { -16, 16, 64 },
		// +X face
		{ 16, -16, 0 }, { 16, 16, 0 }, { 16, 16, 64 },
		{ 16, -16, 0 }, { 16, 16, 64 }, { 16, -16, 64 },
		// bottom (-Z)
		{ -16, -16, 0 }, { -16, 16, 0 }, { 16, 16, 0 },
		{ -16, -16, 0 }, { 16, 16, 0 }, { 16, -16, 0 },
		// top (+Z)
		{ -16, 16, 64 }, { -16, -16, 64 }, { 16, -16, 64 },
		{ -16, 16, 64 }, { 16, -16, 64 }, { 16, 16, 64 },
	};
	rtBoxVertexCount = 36;
	rtBoxVertexBuffer = [device newBufferWithBytes:boxVerts length:sizeof( boxVerts ) options:MTLResourceStorageModeShared];

	return true;
}

id<MTLRenderPipelineState> RT_GetPipeline3D( void )
{
	return rtPipeline3D;
}

id<MTLDepthStencilState> RT_GetDepthState3D( void )
{
	return rtDepthState3D;
}

// See code/renderergl2/tr_main.c R_RotateForViewer's s_flipMatrix comment
// ("convert from our coordinate system (looking down X) to OpenGL's
// coordinate system (looking down -Z)") for the derivation this matches:
// viewaxis[0]=forward, viewaxis[1]=left, viewaxis[2]=up: view-space
// right=-left, up=up, back(-Z direction)=-forward.
simd_float4x4 RT_BuildViewMatrix( const vec3_t vieworg, const vec3_t viewaxis[3] )
{
	simd_float3 forward = simd_make_float3( viewaxis[0][0], viewaxis[0][1], viewaxis[0][2] );
	simd_float3 left = simd_make_float3( viewaxis[1][0], viewaxis[1][1], viewaxis[1][2] );
	simd_float3 up = simd_make_float3( viewaxis[2][0], viewaxis[2][1], viewaxis[2][2] );
	simd_float3 right = -left;
	simd_float3 back = -forward;
	simd_float3 eye = simd_make_float3( vieworg[0], vieworg[1], vieworg[2] );

	simd_float4 row0 = simd_make_float4( right.x, right.y, right.z, -simd_dot( right, eye ) );
	simd_float4 row1 = simd_make_float4( up.x, up.y, up.z, -simd_dot( up, eye ) );
	simd_float4 row2 = simd_make_float4( back.x, back.y, back.z, -simd_dot( back, eye ) );

	simd_float4x4 m;
	m.columns[0] = simd_make_float4( row0.x, row1.x, row2.x, 0 );
	m.columns[1] = simd_make_float4( row0.y, row1.y, row2.y, 0 );
	m.columns[2] = simd_make_float4( row0.z, row1.z, row2.z, 0 );
	m.columns[3] = simd_make_float4( row0.w, row1.w, row2.w, 1 );
	return m;
}

// Standard Metal right-handed perspective, NDC z in [0,1], camera
// looking down -Z (matches RT_BuildViewMatrix above). fov_x/fov_y come
// straight from refdef_t, already separate per axis, so no aspect-ratio
// derivation is needed here.
simd_float4x4 RT_BuildProjectionMatrix( float fovXDeg, float fovYDeg, float nearZ, float farZ )
{
	float xs = 1.0f / tanf( fovXDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	float ys = 1.0f / tanf( fovYDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	float zs = farZ / ( nearZ - farZ );

	simd_float4x4 m;
	m.columns[0] = simd_make_float4( xs, 0, 0, 0 );
	m.columns[1] = simd_make_float4( 0, ys, 0, 0 );
	m.columns[2] = simd_make_float4( 0, 0, zs, -1 );
	m.columns[3] = simd_make_float4( 0, 0, nearZ * zs, 0 );
	return m;
}

// See code/renderergl2/tr_main.c R_RotateForEntity: model-matrix columns
// 0/1/2 are the entity's axis vectors as-is (w=0), column 3 is origin
// (w=1) - a symmetric placeholder box doesn't visually distinguish a
// rotation-convention mistake here, so this isn't independently verified
// live the way the camera convention above was; revisit once a real,
// asymmetric model needs it.
simd_float4x4 RT_BuildModelMatrix( const float origin[3], const float axis[3][3] )
{
	simd_float4x4 m;
	m.columns[0] = simd_make_float4( axis[0][0], axis[0][1], axis[0][2], 0 );
	m.columns[1] = simd_make_float4( axis[1][0], axis[1][1], axis[1][2], 0 );
	m.columns[2] = simd_make_float4( axis[2][0], axis[2][1], axis[2][2], 0 );
	m.columns[3] = simd_make_float4( origin[0], origin[1], origin[2], 1 );
	return m;
}

// Shared by RegisterModel/RegisterServerModel/SpawnEffectModel - the real
// renderer funnels all three through one R_RegisterModelInternal
// (tr_model.cpp) for the same reason: it's the identical ".tik exists?"
// registration contract, just reached from different game-code contexts
// (client-registered vs. server-preloaded vs. a one-shot effect that
// registers-and-spawns in the same call).
static qhandle_t RT_RegisterModelInternal( const char *name )
{
	if ( !name || !name[0] )
		return 0;

	for ( int i = 1; i <= numRtModels; i++ )
	{
		if ( !Q_stricmp( rtModels[i].name, name ) )
			return i;
	}

	const char *ext = COM_GetExtension( name );
	if ( Q_stricmp( ext, "tik" ) != 0 )
	{
		// Sprites (.spr) and anything else real content uses are a
		// separate, later session - see tr_model.cpp's real dispatch
		// (".spr" -> MOD_SPRITE, ".tik" -> MOD_TIKI) for the actual
		// scope once this needs to grow beyond TIKI placeholders.
		RT_STUB_ONCE();
		return 0;
	}

	// ri.FS_FileExists only checks the loose homepath data directory, not
	// the PK3-mounted virtual filesystem where real game assets actually
	// live (it's wired to FS_FileExists_HomeData in cl_main.cpp) - which
	// is why every real .tik in a pk3 would otherwise show as "not
	// found". FS_ReadFile(name, NULL) is the actual PK3-aware existence
	// check (returns -1 if missing, the file's length otherwise without
	// reading it) - the same mechanism the image loaders already use.
	if ( ri.FS_ReadFile( name, NULL ) < 0 )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: \"%s\" not found\n", name );
		return 0;
	}

	if ( numRtModels + 1 >= MAX_RT_MODELS )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: MAX_RT_MODELS (%d) hit, dropping \"%s\"\n",
			MAX_RT_MODELS, name );
		return 0;
	}

	numRtModels++;
	Q_strncpyz( rtModels[numRtModels].name, name, sizeof( rtModels[numRtModels].name ) );

	ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered model \"%s\" -> handle %d "
		"(placeholder box - no real TIKI loading yet)\n", name, numRtModels );

	return numRtModels;
}

static qhandle_t RT_RegisterModel( const char *name )
{
	return RT_RegisterModelInternal( name );
}

static qhandle_t RT_RegisterServerModel( const char *name )
{
	return RT_RegisterModelInternal( name );
}

// Registers a model AND immediately submits a one-shot placeholder
// entity at the given position/orientation - mirrors RE_SpawnEffectModel
// (tr_model.cpp), which does the same (register, then hand the new
// entity straight to CG_ProcessInitCommands) rather than waiting for a
// separate AddRefEntityToScene call.
static qhandle_t RT_SpawnEffectModel( const char *name, vec3_t pos, vec3_t axis[3] )
{
	qhandle_t handle = RT_RegisterModelInternal( name );
	if ( handle == 0 )
		return 0;

	if ( numRtSceneEntities < MAX_RT_SCENE_ENTITIES )
	{
		rtSceneEntity_t *entity = &rtSceneEntities[numRtSceneEntities++];
		VectorCopy( pos, entity->origin );
		if ( axis )
		{
			for ( int i = 0; i < 3; i++ )
				VectorCopy( axis[i], entity->axis[i] );
		}
		else
		{
			AxisClear( entity->axis );
		}
	}

	return handle;
}

static void RT_ClearScene( void )
{
	numRtSceneEntities = 0;
}

static void RT_AddRefEntityToScene( const refEntity_t *re, int parentEntityNumber )
{
	if ( re->reType != RT_MODEL )
		return;

	if ( re->hModel <= 0 || re->hModel > numRtModels )
		return;

	if ( numRtSceneEntities >= MAX_RT_SCENE_ENTITIES )
		return;

	{
		static bool loggedOnce = false;
		if ( !loggedOnce )
		{
			loggedOnce = true;
			ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: AddRefEntityToScene: first valid RT_MODEL "
				"entity (model \"%s\") at origin (%.1f %.1f %.1f)\n",
				rtModels[re->hModel].name, re->origin[0], re->origin[1], re->origin[2] );
		}
	}

	rtSceneEntity_t *entity = &rtSceneEntities[numRtSceneEntities++];
	VectorCopy( re->origin, entity->origin );
	for ( int i = 0; i < 3; i++ )
		VectorCopy( re->axis[i], entity->axis[i] );
}

// rt_world.mm - reuses this file's shared 3D pipeline/depth state
// (RT_GetPipeline3D/RT_GetDepthState3D/RT_EnsurePipeline3D) rather than
// standing up a second, near-identical one for world geometry.
void RT_DrawWorld( simd_float4x4 viewProj );

static void RT_RenderScene( const refdef_t *fd )
{
	if ( !RT_EnsurePipeline3D() )
		return;

	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	// Reasonable placeholder near/far - refdef_t doesn't carry these
	// directly in this fork (farplane_distance is fog, not a hard clip
	// plane); revisit once real world geometry needs a principled value.
	const float nearZ = 4.0f;
	const float farZ = 8192.0f;

	simd_float4x4 view = RT_BuildViewMatrix( fd->vieworg, fd->viewaxis );
	simd_float4x4 proj = RT_BuildProjectionMatrix( fd->fov_x, fd->fov_y, nearZ, farZ );
	simd_float4x4 viewProj = simd_mul( proj, view );

	// World geometry first (see rt_world.mm) - it's the background;
	// entity placeholders draw on top of it, correctly depth-tested
	// against it either way since both go through the same depth state.
	RT_DrawWorld( viewProj );

	if ( numRtSceneEntities == 0 )
		return;

	[encoder setRenderPipelineState:rtPipeline3D];
	[encoder setDepthStencilState:rtDepthState3D];
	[encoder setVertexBuffer:rtBoxVertexBuffer offset:0 atIndex:0];

	// Deliberately garish, unmissable placeholder color - these boxes
	// stand in for real models, not meant to be mistaken for one.
	simd_float4 entityColor = simd_make_float4( 1.0f, 0.0f, 1.0f, 1.0f );
	[encoder setFragmentBytes:&entityColor length:sizeof( entityColor ) atIndex:0];

	for ( int i = 0; i < numRtSceneEntities; i++ )
	{
		simd_float4x4 model = RT_BuildModelMatrix( rtSceneEntities[i].origin, rtSceneEntities[i].axis );
		simd_float4x4 mvp = simd_mul( viewProj, model );

		[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:rtBoxVertexCount];
	}
}

void RT_InitSceneFunctions( refexport_t *re )
{
	re->RegisterModel = RT_RegisterModel;
	re->RegisterServerModel = RT_RegisterServerModel;
	re->SpawnEffectModel = RT_SpawnEffectModel;
	re->ClearScene = RT_ClearScene;
	re->AddRefEntityToScene = RT_AddRefEntityToScene;
	re->RenderScene = RT_RenderScene;
}
