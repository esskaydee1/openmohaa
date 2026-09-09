if(NOT BUILD_TOOLS_OMMAP)
    return()
endif()

include(utils/set_output_dirs)

# ommap: a q3map-derived BSP compiler (-bsp/-light/-vis), vendored from the
# original MoHAA SDK tools but never previously wired into this project's
# build. Its own common/cmdlib.h, common/mathlib.h etc. share qboolean/
# vec3_t/SIDE_*/... with the real engine's qcommon/q_shared.h (see that
# file's Q_SHARED_H sentinel and the matching "Q_SHARED_H deferral" notes
# throughout code/tools/ommap) so the maps it writes stay binary-compatible
# with what the engine actually loads, rather than drifting against a
# second, stale copy of the same struct layouts.
set(OMMAP_DIR ${SOURCE_DIR}/tools/ommap)

set(OMMAP_SOURCES
    ${OMMAP_DIR}/bsp.c
    ${OMMAP_DIR}/brush.c
    ${OMMAP_DIR}/brush_primit.c
    ${OMMAP_DIR}/facebsp.c
    ${OMMAP_DIR}/fog.c
    ${OMMAP_DIR}/glfile.c
    ${OMMAP_DIR}/leakfile.c
    ${OMMAP_DIR}/light.c
    ${OMMAP_DIR}/light_trace.c
    ${OMMAP_DIR}/lightmaps.c
    ${OMMAP_DIR}/lightv.c
    ${OMMAP_DIR}/soundv.c
    ${OMMAP_DIR}/map.c
    ${OMMAP_DIR}/mesh.c
    ${OMMAP_DIR}/misc_model.c
    ${OMMAP_DIR}/nodraw.c
    ${OMMAP_DIR}/patch.c
    ${OMMAP_DIR}/portals.c
    ${OMMAP_DIR}/prtfile.c
    ${OMMAP_DIR}/shaders.c
    ${OMMAP_DIR}/surface.c
    ${OMMAP_DIR}/terrain.c
    ${OMMAP_DIR}/tjunction.c
    ${OMMAP_DIR}/tree.c
    ${OMMAP_DIR}/vis.c
    ${OMMAP_DIR}/visflow.c
    ${OMMAP_DIR}/writebsp.c
    ${OMMAP_DIR}/common/cmdlib.c
    ${OMMAP_DIR}/common/mathlib.c
    ${OMMAP_DIR}/common/scriplib.c
    ${OMMAP_DIR}/common/polylib.c
    ${OMMAP_DIR}/common/imagelib.c
    ${OMMAP_DIR}/common/threads.c
    ${OMMAP_DIR}/common/mutex.c
    ${OMMAP_DIR}/common/bspfile.c
    ${OMMAP_DIR}/common/aselib.c
)

# gldraw.c is an alternative to nodraw.c (a live OpenGL debug-view window
# vs. a headless no-op stub) - both define the same symbols, so exactly one
# of them is compiled in. nodraw.c is the one that needs no windowing/GL
# dependency, which is all this build has been validated against so far.
#
# common/l3dslib.c/common/trilib.c (3DS/legacy-triangle model import) are
# left out entirely: real, pre-existing portability bugs (Windows-only
# strlwr/stricmp etc.) that nothing in this tool's own -bsp/-light/-vis
# paths actually calls, per an explicit call-site check.

set(OMMAP_BINARY ommap)

add_executable(${OMMAP_BINARY} ${OMMAP_SOURCES})

target_include_directories(${OMMAP_BINARY} PRIVATE
    ${OMMAP_DIR}
    ${OMMAP_DIR}/common
    ${OMMAP_DIR}/libs/cmdlib
    ${OMMAP_DIR}/libs/jpeg6
    ${OMMAP_DIR}/libs/pak)

find_package(Threads REQUIRED)
target_link_libraries(${OMMAP_BINARY} PRIVATE Threads::Threads)

set_output_dirs(${OMMAP_BINARY})
set_target_properties(${OMMAP_BINARY} PROPERTIES DEBUG_POSTFIX ${CMAKE_DEBUG_POSTFIX})

INSTALL(TARGETS ${OMMAP_BINARY} DESTINATION ${INSTALL_BINDIR_FULL})
