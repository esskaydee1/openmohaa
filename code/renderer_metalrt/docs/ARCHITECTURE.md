# Architecture

## Boundary
Game logic (server, game, cgame, ui) talks to the renderer only through a
fixed C interface: the client calls `GetRefAPI()` on the renderer shared
library, gets back a `refexport_t` vtable, and never touches a graphics
API directly. `renderer_metalrt` is a new implementation of that vtable.
Nothing on the game side changes.

## The refexport_t / refimport_t contract
Ground truth is `code/renderercommon/tr_public.h` — read it before
writing renderer_metalrt's header, and treat the checklist below as a
starting point, not the full scope: `refexport_t` has **84** function
pointers unconditionally (85 if the build defines `__USEA3D`, which gates
one legacy Aureal3D geometry-hint entry, `A3D_RenderGeometry` — almost
certainly dead in a modern build and safe to skip). `REF_API_VERSION` is
14. The list below covers roughly 20 of the 84; see "Everything else"
below for the rest. `refimport_t` (the renderer's imports *from* the
engine) is similarly large, ~90 members, with its own TIKI/Skeletor
import block worth accounting for if this project needs engine-side
interop beyond what's listed here.

- Lifecycle: `R_Shutdown`, `R_BeginRegistration`, `R_EndRegistration`.
  **Not `R_Init`** — that doesn't exist as a struct member. Renderer
  construction happens implicitly inside the single exported entry point,
  `refexport_t* GetRefAPI(int apiVersion, refimport_t *rimp)`, which
  returns `NULL` on failure. Whatever `R_Init`-shaped setup this project
  needs goes inside `GetRefAPI`, not a separate callback.
- Registration: `R_RegisterModel`, `R_RegisterSkin`, `R_RegisterShader`,
  `R_RegisterShaderNoMip`, `R_LoadWorld` (the world-map load entry
  point), `R_SetWorldVisData`.
- Scene submission: `R_ClearScene`, `R_AddRefEntityToScene` (carries a
  MOHAA-specific `parentEntityNumber` param, not stock Quake3),
  `R_AddPolyToScene`, `R_AddLightToScene`, `R_AddAdditiveLightToScene`,
  `R_LightForPoint`, `R_RenderScene`.
- 2D/UI: `R_SetColor`, `R_DrawStretchPic`. **No gradient variant exists**
  — stock ioquake3's `DrawStretchPicGradient` isn't part of this fork's
  interface; don't plan a session around porting one. Real stretch/tile
  variants that do exist: `R_DrawStretchPic2` (adds scroll params),
  `R_DrawStretchRaw` (cinematic raw-image blit, see "Cutscenes" below),
  `R_DrawTilePic`, `R_DrawTilePicOffset`, `R_DrawTrianglePic`,
  `R_DrawBackground`.
- Frame: `R_BeginFrame`, `R_EndFrame`.
- Query: `R_ModelBounds`, `R_LerpTag`, `R_inPVS`.

**Everything else (~64 entries, unmentioned above but required for a
real implementation):**
- TIKI/skeletal model support: `R_Model_GetHandle` (returns a
  `dtiki_t*`), `ForceUpdatePose`, `TIKI_Orientation`, `TIKI_IsOnGround`,
  `ModelRadius`, `SpawnEffectModel`, `RegisterServerModel` /
  `UnregisterServerModel`, `FreeModels`, `GetRenderEntity`,
  `SetFrameNumber`.
- Terrain: `AddTerrainMarkToScene` (terrain decal marks).
- Lighting/decal helpers: `GetLightingForDecal`, `GetLightingForSmoke`,
  `R_GatherLightSources`.
- A UI/font/swipe subsystem: `DrawString`, `GetFontHeight`,
  `GetFontStringWidth`, `LoadFont`, `SwipeBegin`/`SwipePoint`/`SwipeEnd`
  (weapon-trail swipe effects), `Set2DWindow`, `Set2DInitialShaderTime`,
  `DrawBox`, `AddBox`, `Scissor`, `DrawLineLoop`, `DebugLine`.
- Mode/graphics-info: `SetMode`, `SetFullscreen`, `GetGraphicsInfo`,
  `GetShaderWidth`/`GetShaderHeight`/`GetShaderName`/`GetModelName`,
  `ImageExists`, `CountTextureMemory`, `LoadRawImage`/`FreeRawImage`.
- Misc: `MarkFragmentsForInlineModel` and `GetInlineModelBounds`
  (inline-BSP-model specific, distinct from the plain `MarkFragments`/
  `ModelBounds`), `PrintBSPFileSizes`, `MapVersion`,
  `SavePerformanceCounters`, `Noise`.

Track implemented vs. stubbed functions in
`code/renderer_metalrt/CLAUDE.md`'s status log — update it every session.
Given the real count, expect Phase 1 to genuinely be dozens of small
sessions, not the handful the original ~20-function sketch implied — but
also expect many of the 64 to be thin/mechanical (queries, UI draw
calls), not each a multi-session effort.

## Material translation layer
Original `.shader` scripts describe multitexture blend stages, not PBR.
Build a parser that reads the existing shader scripts and produces:
albedo (from the diffuse stage), a default roughness/metalness per
surface-type keyword inferred from existing shader flags (`surfaceparm`
metal, water, glass, skin, foliage, etc.), and an emissive flag where a
shader already has a glow/light stage. Back it with a per-shader-name
override file so specific surfaces can be hand-tuned without touching the
parser. Don't try to infer PBR values from pixel color alone — a wrong
material response reads worse than a plain, honest default.

**Terrain confirmed to need no separate path.** Each terrain patch (a
small heightfield tile — 512×512 units, not the whole landscape) carries
exactly one shader index, resolved through the identical BSP shader-name
lookup used by every other surface type (`ShaderForShaderNum`). There is
no engine-level splat/blend-weight mechanism, no per-texel alpha layers,
no third/fourth UV channel — `tr_shader.c` has zero terrain-aware code.
Apparent multi-texture variety across a landscape comes from ordinary
mechanisms this parser already needs to handle anyway: many small
patches each independently using a different (single) shader, and/or
ordinary multi-stage authoring within one patch's shader (base + detail
blend stage, same as any wall/floor shader). Do not attempt to read a
terrain patch's heightmap or variance-tree data as material information
— that's pure geometric LOD data (Real-time Optimally Adapting Mesh
split/merge), entirely unrelated to texturing, and belongs to the
geometry importer, not this parser.

## Acceleration structures
- **Static BLAS**: one per map, built once from BSP brush surfaces,
  tessellated patches, and terrain, cached to disk keyed by map checksum.
  Rebuild only if the map or tessellation settings change.
- **Dynamic BLAS**: one per skinned entity (TIKI models). A GPU skinning
  compute pass writes deformed vertex positions each frame; the BLAS is
  refit against the new positions using Metal's
  `MTLAccelerationStructureUsageRefit` flag and the
  `MTLAccelerationStructureCommandEncoder.refit(...)` call. Refit only
  moves existing vertices — it cannot add or remove geometry, and
  repeated refits without a rebuild progressively degrade BVH traversal
  quality as the tree drifts from an optimal partition. Define an
  explicit policy: refit every frame, full rebuild on a fixed cadence
  (every N frames) or immediately on a topology change (LOD swap,
  dismemberment) — refit alone cannot handle those.
  - Note on where the source data actually comes from: bone-hierarchy
    animation *blending* (keyframe interpolation, multi-channel weighting)
    is not renderer code — it lives in `code/skeletor/`, reached only
    through `refimport_t` (`TIKI_SetPoseInternal`, `TIKI_GetSkeletor`,
    etc.). The renderer receives already-blended per-bone matrices for
    the frame; today's GL2 renderer does the actual vertex/normal skin on
    the CPU (`tr_model.cpp`, ~1000 lines: `R_AddSkelSurfaces` +
    `RB_SkelMesh`) from variable-stride, pointer-walked weight records.
    Moving this to a GPU compute skinning pass means designing a
    fixed-stride vertex-weight layout as a preprocessing step — this is
    new design work, not a recompile of the existing CPU path.
- **TLAS**: rebuilt every frame from current entity transforms and
  visible static instances. Metal's instance acceleration structure
  (`MTLInstanceAccelerationStructureDescriptor`) is cheap to rebuild
  per-frame by design — only transforms and BLAS references, not raw
  geometry — so a full rebuild every frame is the normal, low-risk
  default, consistent with Apple's own scaling guidance. Metal also
  supports refit for the instance structure for very large instance
  counts where a transform-only update is preferred, but treat full
  rebuild-per-frame as the default, not the fallback.
- **Static-model props** (non-skinned) get their own small per-model
  BLAS, instanced via TLAS — this is also where added visual density
  from content work (docs/CONTENT_STRATEGY.md) lands, without touching
  world BSP data. This matches the engine's own existing pattern:
  `tr_staticmodels.cpp` isn't a separate static-mesh format — it's a
  caching layer on top of ordinary TIKI data that bakes one rest-pose
  vertex buffer per *unique* TIKI mesh (shared across every map placement
  of it), then applies a per-instance rigid transform + frustum/LOD
  culling at draw time. Key a static-prop BLAS the same way: per unique
  mesh, not per placement, with per-instance data going into the TLAS.

## Render pipeline
Scene submit (existing refEntity_t / poly / light data from cgame,
unchanged) → G-buffer raster pass → RT shadows → RT reflections → RT
AO/GI → denoise (temporal + spatial) → MetalFX temporal upscale →
present.

Effects ship in that order, each a complete working milestone before the
next starts:
1. RT shadows (dynamic lights — muzzle flash, explosions, tracers — plus
   sun/sky)
2. RT reflections (wet surfaces, glass, metal)
3. RT ambient occlusion
4. RT global illumination (single- or two-bounce diffuse)

**Feasibility note:** no known shipping Apple Silicon title runs all
four of these simultaneously at full quality in real time — this
combination is an aggressive target even on discrete desktop GPUs well
above M3 Ultra's per-core RT throughput. Treat "all four effects at once
on M3 Ultra" as the ambition, not the fixed target from day one: define a
scalability ladder alongside the milestones above — which effect
degrades first under load, per-effect ray-budget/resolution knobs,
whether GI runs at reduced resolution or update-rate relative to direct
lighting. Build that ladder as part of Phase 4, not as an afterthought if
Phase 4 turns out to be too slow.

## Fidelity surfaces easy to miss
Beyond the material/BLAS/pipeline work above, these are real rendering
paths in the existing engine that a straightforward refexport_t port can
still get wrong or skip entirely:

- **Sky / portal-sky.** Distant sky rendering and, on some outdoor maps,
  a small window ("portal sky") showing separately-rendered distant
  geometry. Different depth handling than normal world surfaces — port
  the existing pass, don't rebuild it from the shader spec alone. Also
  see "Fog," below — portal-sky sub-views get their own distinct fog
  parameters.
- **Fog.** More than one global setting. Two subsystems coexist: (a) a
  legacy per-BSP-brush volumetric fog, fully implemented in the existing
  renderer but currently dead code — its load call is commented out, so
  per-volume fog brushes are inactive today; (b) the fog that's actually
  active, a distance/farplane "depth fog" computed per view from cvars/
  refdef fields (`farplane_distance`, `farplane_bias`, `farplane_color`).
  This active fog is server-authoritative and can change live mid-level
  (a worldspawn command updates it), and — critically — it differs
  between the main view and a portal-sky sub-view: separate cvars,
  separate cull mode, evaluated per sub-scene rather than once per level.
  Match that per-portal behavior if "visually indistinguishable" is
  meant literally, not just the single active-fog value.
- **Scoped-weapon rendering.** Confirmed: exactly one `R_RenderScene`
  call per frame handles this, not two. The scope "look" comes from (1)
  a server-driven FOV change on the *same* camera (a zoom event sets the
  player's FOV, which flows into the one render call's `refdef`), (2)
  hiding the view-model while zoomed, and (3) a 2D full-screen overlay
  quad drawn in the ordinary HUD pass (a per-weapon vignette/letterbox/
  binoculars-mask shader). Do not budget a second camera / masked
  composite pass for this — it isn't how the engine does it.
- **View-model (first-person weapon) rendering.** Confirmed: no FOV
  difference from the world at all — world and weapon share one
  projection. The classic idTech3 wall-clipping fix here is a depth-range
  hack: the weapon entity carries `RF_DEPTHHACK`, which compresses its
  OpenGL depth range to `(0, 0.3)` versus the world's `(0, 1.0)`, plus a
  separate LOD-cap curve for depth-hacked entities. Port the depth-range
  compression (equivalent depth-clamp/viewport-depth-range control in
  Metal) and the LOD-curve override — not a second FOV or projection.
- **Cutscenes.** Confirmed present: this fork plays `.roq` cutscenes via
  a full custom decoder in `code/client/cl_cin.cpp` (fully CPU-decoded,
  client-side — `cl_avi.cpp` is unrelated demo/video *capture*, not
  playback). This is not a rendering-backend concern beyond ordinary 2D
  texture upload: decoded frames reach the renderer as a plain RGBA
  buffer through `R_DrawStretchRaw`/the cinematic-upload path, which
  every backend implements as a standard texture upload + textured-quad
  draw — the same capability already needed for UI/HUD. No RoQ-specific
  renderer work is expected; just smoke-test actual `.roq` playback (and
  the `videoMap` shader keyword, which drives an in-world use of the same
  path) once far enough into Phase 1.
- **Terrain materials.** Resolved — see "Material translation layer"
  above. Terrain uses ordinary shader stages exactly like other surfaces;
  no separate blending path or extra UV channel is needed.
- **Static (non-skeletal) prop models.** Resolved — see "Acceleration
  structures" above. Everything placeable, including static props, goes
  through TIKI; there is no second, simpler format to support. (The
  legacy `MOD_MESH`/`MOD_MDR`/`MOD_IQM` code paths are present in the
  tree — inherited ioquake3/RTCW lineage — but dead: nothing in the
  compiled engine ever produces those model types. Exclude them from
  scope entirely.)
- **Procedural "ghost" particle textures.** Not in the original doc, and
  genuinely renderer-owned: `code/renderergl2/tr_ghost.cpp` (~1,960
  lines) is a self-contained particle-*physics* simulation (velocity/
  acceleration integration, gravity wells, recursive lightning
  generation) — distinct from cgame's gameplay sprite particles, which
  remain correctly out of scope. It renders into a CPU pixel buffer and
  uploads that as a live-updating 2D texture, producing animated
  procedural surface textures (fire/energy effects, MOHAA's `.ghost`
  format). The simulation classes are portable C++; only the final
  texture-upload call is backend-coupled. Port the simulation, don't
  reimplement the physics from scratch.
- **Decal fragment clipping.** Also genuinely renderer-owned:
  `code/renderergl2/tr_marks.c` (479 lines) implements the BSP
  polygon-clip algorithm (Sutherland-Hodgman against world planes) that
  determines which surface fragments a decal touches. cgame calls into
  this before building the final decal poly and handing it to
  `R_AddPolyToScene` — small, pure CPU geometry, no GL calls, but real
  logic to port rather than assume is "just cgame's problem."

## Denoise & upscale
Real-time RT at low sample counts needs a real denoiser — budget a proper
temporal+spatial pass (SVGF-style) or ReSTIR for area-light shadows,
given how many dynamic point lights MOHAA throws per frame. Render below
native resolution and use MetalFX temporal upscaling to reach display
resolution — full native-resolution path tracing is not the target even
on an M3 Ultra.

**Known footgun, not a minor detail:** `MTLFXTemporalScaler` expects an
input that's already denoised and noise-free, and performs its own
independent temporal accumulation/reprojection on top (its own history
buffer, its own disocclusion handling, driven by the motion-vector
texture you supply). A custom SVGF or ReSTIR denoiser is itself a
temporally-accumulating filter with its own history and disocclusion
logic. Stacking the two means two independently-tuned temporal
integrators — a well-documented source of compounded ghosting on fast
motion and disocclusion edges, not something to discover only at Phase
5's final check. Investigate Apple's Metal 4 (WWDC25) unified denoise +
upscale API before hand-building two separate systems — it exists
specifically to collapse this into one integrator, and its existence is
itself a signal that the two-stage approach is a recognized pain point.
If a custom denoiser must stay separate for OS-version reasons: share the
same jitter pattern and motion vectors between both stages, and bias the
custom denoiser toward a short, aggressive history clamp so it doesn't
bake in lag before MetalFX's own accumulation runs on top of it.

## New cvars
`r_rtShadows`, `r_rtReflections`, `r_rtGI`, `r_renderScale` — registered
additively through the existing cvar system, exposed in menus the same
way existing renderer cvars are. No new menu framework. Renderer
selection is `cl_renderer "metalrt"` — `"metal"` is already the existing
ANGLE-backed renderer, so don't reuse that value.

## Multiplayer fairness — resolved, not a constraint
Single-player and co-op only (CLAUDE.md rule 7). No lighting-driven-
visibility clamping anywhere in this pipeline — RT shadows, reflections,
AO, and GI all ship at whatever fidelity looks best, full stop. FOV and
aspect-ratio handling are ordinary rendering preferences, not
fairness-gated decisions — the only reason either was ever treated as a
"decision" was the possibility of playing against other people, which
isn't in scope. If multiplayer support gets added later, this is where
to reopen the question — the original concern (better lighting or a
wider FOV creating a spotting/visibility advantage) is still real, just
not relevant to what's being built now.
