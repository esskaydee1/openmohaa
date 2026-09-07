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
#include <vector>

// rt_image.mm (not anonymous-namespace-scoped there, see its comments) -
// reused here to resolve a TIKI surface's shader name to a texture the
// same way DrawStretchPic resolves a UI image name, rather than
// duplicating the direct-image-file loader.
qhandle_t RT_RegisterImageCommon( const char *name );
id<MTLTexture> RT_GetImageTexture( qhandle_t handle );

namespace {

#define MAX_RT_MODEL_SURFACES 32

// One real mesh surface's worth of a model's shared index buffer, plus
// whichever texture its TIKI-level `surface <name> shader <name>` line
// resolved to (session 7) - nil means no resolvable texture (most
// .shader-script names still don't resolve, see RT_RegisterImageCommon's
// "no .shader script support yet" warning), in which case this surface
// draws through the flat-magenta fallback pipeline instead, same as
// every model did before this session.
struct rtModelSurface_t {
	uint32_t indexOffset; // element (not byte) offset into the model's indexBuffer
	uint32_t indexCount;
	id<MTLTexture> texture;
};

struct rtModel_t {
	char name[MAX_QPATH];
	// Real baked TIKI geometry (session 6) - nil/0 means "bake failed or
	// this model has no mesh data", in which case RT_RenderScene falls
	// back to the flat-magenta placeholder box, same as every model drew
	// before this session.
	id<MTLBuffer> vertexBuffer;
	// Parallel to vertexBuffer (same per-vertex indexing) - always baked
	// alongside positions since the source data's already right there
	// (skeletorVertex_t::texCoords), even for surfaces that end up with
	// no resolvable texture; cheap to keep unconditionally rather than
	// track whether any surface of this model ended up needing it.
	id<MTLBuffer> texcoordBuffer;
	id<MTLBuffer> indexBuffer;
	int indexCount;
	int numSurfaces;
	rtModelSurface_t surfaces[MAX_RT_MODEL_SURFACES];
};

#define MAX_RT_MODELS 1024
rtModel_t rtModels[MAX_RT_MODELS]; // index 0 unused - handle 0 is invalid
int numRtModels = 0;

struct rtSceneEntity_t {
	float origin[3];
	float axis[3][3];
	qhandle_t hModel;
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

id<MTLRenderPipelineState> rtPipelineTextured3D = nil;
id<MTLSamplerState> rtSamplerTextured3D = nil;

// Session 7: a real per-surface texture, reusing rt_vertex_3d's exact
// position/mvp handling (buffer 0/1) and only adding a second, separate
// per-vertex buffer (2) for texcoords - kept as a parallel array rather
// than interleaved with position so the untextured flat path above can
// keep reading a model's positions buffer completely unchanged.
const char *rtShaderSourceTextured3D =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOutTex { float4 position [[position]]; float2 texcoord; };\n"
	"vertex VertexOutTex rt_vertex_3d_tex(uint vertexID [[vertex_id]],\n"
	"    const device float3 *positions [[buffer(0)]],\n"
	"    constant float4x4 &mvp [[buffer(1)]],\n"
	"    const device float2 *texcoords [[buffer(2)]]) {\n"
	"    VertexOutTex out;\n"
	"    out.position = mvp * float4(positions[vertexID], 1.0);\n"
	"    out.texcoord = texcoords[vertexID];\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_3d_tex(VertexOutTex in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {\n"
	"    return tex.sample(samp, in.texcoord);\n"
	"}\n";

bool RT_EnsurePipelineTextured3D( void )
{
	if ( rtPipelineTextured3D != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSourceTextured3D]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile textured 3D shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"rt_vertex_3d_tex"];
	desc.fragmentFunction = [library newFunctionWithName:@"rt_fragment_3d_tex"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtPipelineTextured3D = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtPipelineTextured3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create textured 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
	samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
	samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
	rtSamplerTextured3D = [device newSamplerStateWithDescriptor:samplerDesc];

	return true;
}

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

// Matches a baked mesh surface's name (e.g. "ranger_top") against the
// TIKI-level `surface <name> shader <name>` mappings from the .tik
// script's setup block (dtiki_t::surfaces, a SEPARATE list from the mesh
// geometry surfaces being baked - matched by name, exactly how the real
// renderer's R_InitStaticModels resolves shaders for tr_model.cpp's
// RB_StaticMesh) and tries to resolve its first non-empty shader name to
// a real texture via the same direct-image-file loader DrawStretchPic
// uses. Most real shader names reference a .shader script this renderer
// can't parse yet (Phase 2), not a direct image file, so returning nil
// here is the common case, not a bug - RT_RenderScene falls back to the
// flat-magenta pipeline for any surface this returns nil for.
static id<MTLTexture> RT_ResolveSurfaceTexture( dtiki_t *tiki, const char *surfaceName )
{
	for ( int i = 0; i < tiki->num_surfaces; i++ )
	{
		dtikisurface_t *tikiSurf = &tiki->surfaces[i];
		if ( Q_stricmp( tikiSurf->name, surfaceName ) != 0 )
			continue;

		for ( int k = 0; k < MAX_TIKI_SHADER; k++ )
		{
			if ( tikiSurf->shader[k][0] == '\0' )
				continue;

			qhandle_t handle = RT_RegisterImageCommon( tikiSurf->shader[k] );
			if ( handle != 0 )
				return RT_GetImageTexture( handle );
		}
		break;
	}
	return nil;
}

// Bakes a dtiki_t's mesh data into one shared vertex/texcoord/index
// buffer set (one draw range + texture per real mesh surface), in the
// model's idle/frame-0 pose - no runtime skinning, no per-frame
// animation, matching the real renderer's own R_InitStaticModels
// (code/renderergl2/tr_staticmodels.cpp), which does the same one-time
// bake for non-animating map props. That function only reads each
// vertex's FIRST bone weight, which is only correct when a vertex has a
// single 1.0-weight bone (true for most static-prop meshes, wrong for
// anything smoothly multi-weighted); this sums over every weight instead,
// matching the fully-correct animated path's SkelWeightGetXyz
// (tr_model.cpp) - the small extra loop costs nothing at load time.
static void RT_BakeTikiModel( dtiki_t *tiki, rtModel_t *model )
{
	model->vertexBuffer = nil;
	model->texcoordBuffer = nil;
	model->indexBuffer = nil;
	model->indexCount = 0;
	model->numSurfaces = 0;

	if ( tiki == NULL || tiki->numMeshes <= 0 )
		return;

	skelBoneCache_t bones[128];
	float radius;
	vec3_t mins, maxs;
	ri.TIKI_GetSkelAnimFrame( tiki, bones, &radius, &mins, &maxs );

	std::vector<simd_float3> verts;
	std::vector<simd_float2> texcoords;
	std::vector<uint32_t> indices;

	for ( int meshIndex = 0; meshIndex < tiki->numMeshes; meshIndex++ )
	{
		skelHeaderGame_t *skelmodel = ri.TIKI_GetSkel( tiki->mesh[meshIndex] );
		if ( skelmodel == NULL )
			continue;

		skelSurfaceGame_t *surf = skelmodel->pSurfaces;
		for ( int s = 0; s < skelmodel->numSurfaces && surf != NULL; s++, surf = surf->pNext )
		{
			int baseVertex = (int)verts.size();
			skeletorVertex_t *vert = surf->pVerts;

			for ( int v = 0; v < surf->numVerts; v++ )
			{
				skelWeight_t *weight = (skelWeight_t *)( (byte *)vert + sizeof( skeletorVertex_t )
					+ vert->numMorphs * sizeof( skeletorMorph_t ) );

				vec3_t out = { 0.0f, 0.0f, 0.0f };
				for ( int w = 0; w < vert->numWeights; w++ )
				{
					// Multiple meshes in one TIKI can share a skeleton
					// via a channel indirection rather than a direct
					// bone index - mesh 0 doesn't need it, matching
					// R_InitStaticModels' identical branch.
					int boneNum;
					if ( meshIndex > 0 )
					{
						int channel = skelmodel->pBones[weight->boneIndex].channel;
						boneNum = ri.TIKI_GetLocalChannel( tiki, channel );
					}
					else
					{
						boneNum = weight->boneIndex;
					}

					skelBoneCache_t *bone = &bones[boneNum];
					out[0] += ( ( weight->offset[0] * bone->matrix[0][0] + weight->offset[1] * bone->matrix[1][0]
						+ weight->offset[2] * bone->matrix[2][0] ) + bone->offset[0] ) * weight->boneWeight;
					out[1] += ( ( weight->offset[0] * bone->matrix[0][1] + weight->offset[1] * bone->matrix[1][1]
						+ weight->offset[2] * bone->matrix[2][1] ) + bone->offset[1] ) * weight->boneWeight;
					out[2] += ( ( weight->offset[0] * bone->matrix[0][2] + weight->offset[1] * bone->matrix[1][2]
						+ weight->offset[2] * bone->matrix[2][2] ) + bone->offset[2] ) * weight->boneWeight;

					weight++;
				}

				verts.push_back( simd_make_float3(
					out[0] * tiki->load_scale, out[1] * tiki->load_scale, out[2] * tiki->load_scale ) );
				texcoords.push_back( simd_make_float2( vert->texCoords[0], vert->texCoords[1] ) );

				vert = (skeletorVertex_t *)( (byte *)vert + sizeof( skeletorVertex_t )
					+ sizeof( skeletorMorph_t ) * vert->numMorphs
					+ sizeof( skelWeight_t ) * vert->numWeights );
			}

			uint32_t baseIndex = (uint32_t)indices.size();
			skelIndex_t *tri = surf->pTriangles;
			for ( int t = 0; t < surf->numTriangles * 3; t++ )
				indices.push_back( (uint32_t)( baseVertex + tri[t] ) );
			uint32_t surfIndexCount = (uint32_t)indices.size() - baseIndex;

			if ( surfIndexCount > 0 )
			{
				if ( model->numSurfaces < MAX_RT_MODEL_SURFACES )
				{
					rtModelSurface_t *modelSurf = &model->surfaces[model->numSurfaces++];
					modelSurf->indexOffset = baseIndex;
					modelSurf->indexCount = surfIndexCount;
					modelSurf->texture = RT_ResolveSurfaceTexture( tiki, surf->name );
				}
				else
				{
					ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: \"%s\" hit "
						"MAX_RT_MODEL_SURFACES (%d), dropping surface \"%s\"\n",
						tiki->name, MAX_RT_MODEL_SURFACES, surf->name );
				}
			}
		}
	}

	if ( verts.empty() || indices.empty() )
	{
		model->numSurfaces = 0;
		return;
	}

	model->vertexBuffer = [RT_GetDevice() newBufferWithBytes:verts.data()
	                                                    length:verts.size() * sizeof( simd_float3 )
	                                                   options:MTLResourceStorageModeShared];
	model->texcoordBuffer = [RT_GetDevice() newBufferWithBytes:texcoords.data()
	                                                      length:texcoords.size() * sizeof( simd_float2 )
	                                                     options:MTLResourceStorageModeShared];
	model->indexBuffer = [RT_GetDevice() newBufferWithBytes:indices.data()
	                                                   length:indices.size() * sizeof( uint32_t )
	                                                  options:MTLResourceStorageModeShared];
	model->indexCount = (int)indices.size();
}

// Shared by RegisterModel/RegisterServerModel/SpawnEffectModel - the real
// renderer funnels all three through one R_RegisterModelInternal
// (tr_model.cpp) for the same reason: it's the identical registration
// contract, just reached from different game-code contexts
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
		// scope once this needs to grow beyond TIKI models.
		RT_STUB_ONCE();
		return 0;
	}

	// ri.TIKI_RegisterTikiFlags is the same client-side entry point the
	// real renderer's R_RegisterModelInternal uses - a full text .tik +
	// binary .skd parse (PK3-aware; it's backed by the same FS_ReadFile
	// this file used to call directly for a bare existence check before
	// this session). Returns NULL on any parse/file failure.
	dtiki_t *tiki = ri.TIKI_RegisterTikiFlags( name, qfalse );
	if ( tiki == NULL )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: \"%s\" failed to load\n", name );
		return 0;
	}

	if ( numRtModels + 1 >= MAX_RT_MODELS )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: MAX_RT_MODELS (%d) hit, dropping \"%s\"\n",
			MAX_RT_MODELS, name );
		return 0;
	}

	numRtModels++;
	rtModel_t *model = &rtModels[numRtModels];
	Q_strncpyz( model->name, name, sizeof( model->name ) );
	RT_BakeTikiModel( tiki, model );

	if ( model->vertexBuffer != nil )
	{
		ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered model \"%s\" -> handle %d "
			"(%d real indices baked)\n", name, numRtModels, model->indexCount );
	}
	else
	{
		ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered model \"%s\" -> handle %d "
			"(placeholder box - no mesh data to bake)\n", name, numRtModels );
	}

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
		entity->hModel = handle;
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
	entity->hModel = re->hModel;
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

	// Session 7: real per-surface textures where a surface's shader name
	// resolved to one (see RT_ResolveSurfaceTexture) - degrades cleanly
	// to the flat pipeline for this whole frame if the textured pipeline
	// itself somehow fails to compile (kept as a real, checked failure
	// path rather than assumed to always succeed).
	bool haveTexturedPipeline = RT_EnsurePipelineTextured3D();

	// Deliberately garish, unmissable placeholder color for any surface
	// with no resolvable texture (most .shader-script names still don't
	// resolve, see rt_image.mm's "no .shader script support yet"
	// warning) and for any model that failed to bake real geometry at
	// all (draws the box fallback instead) - not meant to be mistaken
	// for final art either way.
	simd_float4 entityColor = simd_make_float4( 1.0f, 0.0f, 1.0f, 1.0f );

	for ( int i = 0; i < numRtSceneEntities; i++ )
	{
		simd_float4x4 model = RT_BuildModelMatrix( rtSceneEntities[i].origin, rtSceneEntities[i].axis );
		simd_float4x4 mvp = simd_mul( viewProj, model );

		qhandle_t hModel = rtSceneEntities[i].hModel;
		rtModel_t *m = ( hModel >= 1 && hModel <= numRtModels ) ? &rtModels[hModel] : NULL;

		if ( m != NULL && m->vertexBuffer != nil && m->indexBuffer != nil && m->numSurfaces > 0 )
		{
			for ( int s = 0; s < m->numSurfaces; s++ )
			{
				rtModelSurface_t *surf = &m->surfaces[s];

				if ( surf->texture != nil && haveTexturedPipeline )
				{
					[encoder setRenderPipelineState:rtPipelineTextured3D];
					[encoder setDepthStencilState:rtDepthState3D];
					[encoder setVertexBuffer:m->vertexBuffer offset:0 atIndex:0];
					[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
					[encoder setVertexBuffer:m->texcoordBuffer offset:0 atIndex:2];
					[encoder setFragmentTexture:surf->texture atIndex:0];
					[encoder setFragmentSamplerState:rtSamplerTextured3D atIndex:0];
				}
				else
				{
					[encoder setRenderPipelineState:rtPipeline3D];
					[encoder setDepthStencilState:rtDepthState3D];
					[encoder setVertexBuffer:m->vertexBuffer offset:0 atIndex:0];
					[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
					[encoder setFragmentBytes:&entityColor length:sizeof( entityColor ) atIndex:0];
				}

				[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
				                     indexCount:surf->indexCount
				                      indexType:MTLIndexTypeUInt32
				                    indexBuffer:m->indexBuffer
				              indexBufferOffset:surf->indexOffset * sizeof( uint32_t )];
			}
		}
		else
		{
			[encoder setRenderPipelineState:rtPipeline3D];
			[encoder setDepthStencilState:rtDepthState3D];
			[encoder setVertexBuffer:rtBoxVertexBuffer offset:0 atIndex:0];
			[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
			[encoder setFragmentBytes:&entityColor length:sizeof( entityColor ) atIndex:0];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:rtBoxVertexCount];
		}
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
