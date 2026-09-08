/*
===========================================================================
renderer_metalrt - Phase 2 session 24: real ray tracing, replacing the
rasterized world/sky draw with a genuine hardware-accelerated ray-traced
pass (M3 Ultra confirms MTLDevice.supportsRaytracing) - the actual point
of this renderer (the "rt" in its name), as opposed to every session
before this one, which was spent reproducing the original 2002 GL1/GL2
renderer's rasterization techniques (lightmaps, alpha-test cutout,
cubemap skies) from scratch. Those sessions were not wasted - the real
geometry extraction (world triangle soup, already in rtWorldVertexBuffer
since session 4) is exactly the scene data a ray tracer needs too - but
continuing to deepen that rasterization pipeline's fidelity was heading
away from, not toward, this.

Scope of this first session: world geometry only, primary rays plus one
real traced shadow ray per pixel (genuine dynamic shadows, geometrically
correct, not baked/replayed from 2002 - something the rasterization path
could not do without a whole separate shadow-map system). No per-surface
texturing yet (shaded by geometric normal only) - proving the
acceleration-structure/ray-generation/shading pipeline reaches the
screen correctly first, the same "real data, simplest possible technique"
approach every other real feature in this renderer started with.
Entities (TIKI models) are NOT part of the acceleration structure yet -
rt_scene.mm still rasterizes them on top of this pass's output, same as
they currently draw on top of rasterized world geometry.
===========================================================================
*/
#include "rt_local.h"

#include <simd/simd.h>
#include <vector>

id<MTLBuffer> RT_GetWorldVertexBuffer( void );
int RT_GetWorldVertexCount( void );
id<MTLBuffer> RT_GetWorldTriangleColorBuffer( void );

namespace {

id<MTLAccelerationStructure> rtWorldAccelStructure = nil;
id<MTLComputePipelineState> rtRayTracePipeline = nil;
id<MTLTexture> rtRayTraceOutputTexture = nil;
int rtRayTraceOutputWidth = 0;
int rtRayTraceOutputHeight = 0;

// Composite pass: draws rtRayTraceOutputTexture as a full-screen quad
// into the frame's real render encoder (the compute pass that produced
// it runs on its own command buffer beforehand - see RT_DrawRayTracedWorld).
id<MTLRenderPipelineState> rtCompositePipeline = nil;
id<MTLSamplerState> rtCompositeSampler = nil;

const char *rtShaderSourceRayTrace =
	"#include <metal_stdlib>\n"
	"#include <metal_raytracing>\n"
	"using namespace metal;\n"
	"using namespace raytracing;\n"
	"struct RTCamera {\n"
	"    float3 origin;\n"
	"    float3 forward;\n"
	"    float3 right;\n"
	"    float3 up;\n"
	"    float tanHalfFovX;\n"
	"    float tanHalfFovY;\n"
	"    float3 lightDir;\n"
	"};\n"
	"kernel void rt_raygen_world(\n"
	"    uint2 tid [[thread_position_in_grid]],\n"
	"    texture2d<float, access::write> outTex [[texture(0)]],\n"
	"    instance_acceleration_structure unusedAS [[buffer(0)]],\n"
	"    constant RTCamera &camera [[buffer(1)]],\n"
	"    const device float3 *positions [[buffer(2)]],\n"
	"    primitive_acceleration_structure accelStruct [[buffer(3)]],\n"
	"    const device float3 *triangleColors [[buffer(4)]]) {\n"
	"    uint w = outTex.get_width();\n"
	"    uint h = outTex.get_height();\n"
	"    if (tid.x >= w || tid.y >= h) return;\n"
	"\n"
	"    float2 uv = (float2(tid) + 0.5) / float2(w, h);\n"
	"    float2 ndc = uv * 2.0 - 1.0;\n"
	"    ndc.y = -ndc.y;\n"
	"    float3 dir = normalize(camera.forward + camera.right * (ndc.x * camera.tanHalfFovX)\n"
	"        + camera.up * (ndc.y * camera.tanHalfFovY));\n"
	"\n"
	"    ray r;\n"
	"    r.origin = camera.origin;\n"
	"    r.direction = dir;\n"
	"    r.min_distance = 1.0;\n"
	"    r.max_distance = 65536.0;\n"
	"\n"
	"    intersector<triangle_data> isect;\n"
	"    intersection_result<triangle_data> result = isect.intersect(r, accelStruct);\n"
	"\n"
	"    if (result.type == intersection_type::none) {\n"
	"        outTex.write(float4(0.0, 0.15, 0.2, 1.0), tid);\n"
	"        return;\n"
	"    }\n"
	"\n"
	"    uint primIdx = result.primitive_id;\n"
	"    float3 v0 = positions[primIdx * 3 + 0];\n"
	"    float3 v1 = positions[primIdx * 3 + 1];\n"
	"    float3 v2 = positions[primIdx * 3 + 2];\n"
	"    float3 normal = normalize(cross(v1 - v0, v2 - v0));\n"
	"\n"
	"    float ndotl = max(dot(normal, camera.lightDir), 0.0);\n"
	"    float lighting = mix(0.2, 1.0, ndotl);\n"
	"\n"
	"    float3 hitPoint = r.origin + r.direction * result.distance;\n"
	"    ray shadowRay;\n"
	"    shadowRay.origin = hitPoint + normal * 2.0;\n"
	"    shadowRay.direction = camera.lightDir;\n"
	"    shadowRay.min_distance = 1.0;\n"
	"    shadowRay.max_distance = 65536.0;\n"
	"    intersection_result<triangle_data> shadowResult = isect.intersect(shadowRay, accelStruct);\n"
	"    if (shadowResult.type != intersection_type::none) {\n"
	"        lighting = 0.2;\n"
	"    }\n"
	"\n"
	"    float3 albedo = triangleColors[primIdx];\n"
	"    float3 color = albedo * lighting;\n"
	"    outTex.write(float4(color, 1.0), tid);\n"
	"}\n";

const char *rtShaderSourceComposite =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOutComposite { float4 position [[position]]; float2 texcoord; };\n"
	"vertex VertexOutComposite rt_vertex_composite(uint vertexID [[vertex_id]]) {\n"
	"    float2 positions[6] = { float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1) };\n"
	"    VertexOutComposite out;\n"
	"    float2 p = positions[vertexID];\n"
	"    out.position = float4(p, 0.0, 1.0);\n"
	"    out.texcoord = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_composite(VertexOutComposite in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {\n"
	"    return tex.sample(samp, in.texcoord);\n"
	"}\n";

bool RT_EnsureRayTracePipeline( void )
{
	if ( rtRayTracePipeline != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();
	if ( !device.supportsRaytracing )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: device does not support ray tracing\n" );
		return false;
	}

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSourceRayTrace]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile ray trace kernel: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	id<MTLFunction> fn = [library newFunctionWithName:@"rt_raygen_world"];
	rtRayTracePipeline = [device newComputePipelineStateWithFunction:fn error:&error];
	if ( rtRayTracePipeline == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create ray trace pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	return true;
}

bool RT_EnsureCompositePipeline( void )
{
	if ( rtCompositePipeline != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSourceComposite]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile composite shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"rt_vertex_composite"];
	desc.fragmentFunction = [library newFunctionWithName:@"rt_fragment_composite"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	// No depth attachment bound for this pipeline - it's drawn first,
	// covering the whole screen, before depth-tested geometry.

	rtCompositePipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtCompositePipeline == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create composite pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
	samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
	samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
	rtCompositeSampler = [device newSamplerStateWithDescriptor:samplerDesc];

	return true;
}

void RT_EnsureOutputTexture( int width, int height )
{
	if ( rtRayTraceOutputTexture != nil && rtRayTraceOutputWidth == width && rtRayTraceOutputHeight == height )
		return;

	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                                 width:width
	                                                                                height:height
	                                                                             mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rtRayTraceOutputTexture = [RT_GetDevice() newTextureWithDescriptor:desc];
	rtRayTraceOutputWidth = width;
	rtRayTraceOutputHeight = height;
}

} // namespace

void RT_BuildWorldAccelStructure( void )
{
	id<MTLBuffer> vertexBuffer = RT_GetWorldVertexBuffer();
	int vertexCount = RT_GetWorldVertexCount();
	if ( vertexBuffer == nil || vertexCount < 3 )
	{
		rtWorldAccelStructure = nil;
		return;
	}

	id<MTLDevice> device = RT_GetDevice();
	if ( !device.supportsRaytracing )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: device does not support ray tracing - "
			"world will not be ray traced\n" );
		rtWorldAccelStructure = nil;
		return;
	}

	MTLAccelerationStructureTriangleGeometryDescriptor *geomDesc =
		[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
	geomDesc.vertexBuffer = vertexBuffer;
	geomDesc.vertexStride = sizeof( simd_float3 );
	geomDesc.triangleCount = vertexCount / 3;

	MTLPrimitiveAccelerationStructureDescriptor *accelDesc =
		[MTLPrimitiveAccelerationStructureDescriptor descriptor];
	accelDesc.geometryDescriptors = @[ geomDesc ];

	MTLAccelerationStructureSizes sizes = [device accelerationStructureSizesWithDescriptor:accelDesc];
	rtWorldAccelStructure = [device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
	id<MTLBuffer> scratchBuffer = [device newBufferWithLength:sizes.buildScratchBufferSize
	                                                   options:MTLResourceStorageModePrivate];

	id<MTLCommandBuffer> cmdBuf = [RT_GetQueue() commandBuffer];
	id<MTLAccelerationStructureCommandEncoder> accelEncoder = [cmdBuf accelerationStructureCommandEncoder];
	[accelEncoder buildAccelerationStructure:rtWorldAccelStructure
	                               descriptor:accelDesc
	                            scratchBuffer:scratchBuffer
	                      scratchBufferOffset:0];
	[accelEncoder endEncoding];
	[cmdBuf commit];
	// One-time build at map load, same as every other one-time buffer
	// upload in RT_LoadWorld - blocking here is fine, this isn't a
	// per-frame cost.
	[cmdBuf waitUntilCompleted];

	ri.Printf( PRINT_ALL, "renderer_metalrt: built world acceleration structure (%d triangles)\n", vertexCount / 3 );
}

// Dispatches the ray trace compute pass on its own command buffer
// (can't share RE_BeginFrame's already-open render encoder - a compute
// encoder needs the render encoder to not be active), then draws the
// result as a full-screen quad into the frame's real render encoder.
// Submitting the compute command buffer to the SAME queue before the
// main per-frame command buffer guarantees it completes first (same-
// queue command buffers execute in commit order) without needing an
// explicit fence for this first, single-dependency case.
void RT_DrawRayTracedWorld( const vec3_t vieworg, const vec3_t viewaxis[3], float fovXDeg, float fovYDeg, simd_float3 lightDir )
{
	if ( rtWorldAccelStructure == nil )
		return;
	if ( !RT_EnsureRayTracePipeline() || !RT_EnsureCompositePipeline() )
		return;

	id<MTLBuffer> vertexBuffer = RT_GetWorldVertexBuffer();
	id<MTLBuffer> triangleColorBuffer = RT_GetWorldTriangleColorBuffer();
	if ( vertexBuffer == nil || triangleColorBuffer == nil )
		return;

	id<MTLRenderCommandEncoder> renderEncoder = RT_GetCurrentEncoder();
	if ( renderEncoder == nil )
		return;

	int width = (int)rtRayTraceOutputWidth;
	int height = (int)rtRayTraceOutputHeight;
	// Match the drawable's actual size - read from the render pass's own
	// color attachment via the encoder isn't directly exposable, so this
	// takes it from rtGlConfig (kept up to date by window setup/resize),
	// same source RT_DrawStretchPic's screen mapping already trusts.
	width = rtGlConfig.vidWidth;
	height = rtGlConfig.vidHeight;
	RT_EnsureOutputTexture( width, height );

	struct RTCamera {
		simd_float3 origin;
		simd_float3 forward;
		simd_float3 right;
		simd_float3 up;
		float tanHalfFovX;
		float tanHalfFovY;
		simd_float3 lightDir;
	} camera;

	camera.origin = simd_make_float3( vieworg[0], vieworg[1], vieworg[2] );
	camera.forward = simd_make_float3( viewaxis[0][0], viewaxis[0][1], viewaxis[0][2] );
	simd_float3 left = simd_make_float3( viewaxis[1][0], viewaxis[1][1], viewaxis[1][2] );
	camera.right = -left;
	camera.up = simd_make_float3( viewaxis[2][0], viewaxis[2][1], viewaxis[2][2] );
	camera.tanHalfFovX = tanf( fovXDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	camera.tanHalfFovY = tanf( fovYDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	camera.lightDir = lightDir;

	id<MTLCommandBuffer> computeCmdBuf = [RT_GetQueue() commandBuffer];
	id<MTLComputeCommandEncoder> computeEncoder = [computeCmdBuf computeCommandEncoder];
	[computeEncoder setComputePipelineState:rtRayTracePipeline];
	[computeEncoder setTexture:rtRayTraceOutputTexture atIndex:0];
	// buffer(0) (instance_acceleration_structure) is unused by this
	// primitive-only first pass - bound with a tiny placeholder buffer
	// purely so the argument table has something at that index; only
	// buffer(3)'s primitive_acceleration_structure is actually read.
	static id<MTLBuffer> dummyBuffer = nil;
	if ( dummyBuffer == nil )
		dummyBuffer = [RT_GetDevice() newBufferWithLength:16 options:MTLResourceStorageModeShared];
	[computeEncoder setBuffer:dummyBuffer offset:0 atIndex:0];
	[computeEncoder setBytes:&camera length:sizeof( camera ) atIndex:1];
	[computeEncoder setBuffer:vertexBuffer offset:0 atIndex:2];
	[computeEncoder setAccelerationStructure:rtWorldAccelStructure atBufferIndex:3];
	[computeEncoder setBuffer:triangleColorBuffer offset:0 atIndex:4];
	[computeEncoder useResource:vertexBuffer usage:MTLResourceUsageRead];
	[computeEncoder useResource:triangleColorBuffer usage:MTLResourceUsageRead];

	MTLSize gridSize = MTLSizeMake( width, height, 1 );
	NSUInteger w = rtRayTracePipeline.threadExecutionWidth;
	NSUInteger h = rtRayTracePipeline.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadgroupSize = MTLSizeMake( w, h, 1 );
	[computeEncoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
	[computeEncoder endEncoding];
	[computeCmdBuf commit];

	[renderEncoder setRenderPipelineState:rtCompositePipeline];
	[renderEncoder setFragmentTexture:rtRayTraceOutputTexture atIndex:0];
	[renderEncoder setFragmentSamplerState:rtCompositeSampler atIndex:0];
	[renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}
