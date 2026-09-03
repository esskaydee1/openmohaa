if(NOT BUILD_CLIENT OR NOT BUILD_RENDERER_METAL)
    return()
endif()

if(NOT APPLE)
    message(FATAL_ERROR "BUILD_RENDERER_METAL is only supported on macOS")
endif()

include(utils/set_output_dirs)
include(renderer_common)

# Reuses code/renderergl2/'s sources unchanged: the only thing that differs
# from renderer_opengl2 is how the window/context gets created and how qgl*
# procs get resolved (sdl_metalimp.c, driving ANGLE's Metal backend through
# EGL, instead of sdl_glimp.c's real SDL_GL_CreateContext path). GL2's actual
# GL usage is entirely within GLES3-class semantics, so the shared renderer
# code needs no changes for this to work.
set(RENDERER_METAL_SOURCES
    ${SOURCE_DIR}/renderergl2/tr_animation.c
    ${SOURCE_DIR}/renderergl2/tr_backend.c
    ${SOURCE_DIR}/renderergl2/tr_bsp.c
    ${SOURCE_DIR}/renderergl2/tr_cmds.c
    ${SOURCE_DIR}/renderergl2/tr_curve.c
    ${SOURCE_DIR}/renderergl2/tr_draw.c
    ${SOURCE_DIR}/renderergl2/tr_dsa.c
    ${SOURCE_DIR}/renderergl2/tr_extramath.c
    ${SOURCE_DIR}/renderergl2/tr_extensions.c
    ${SOURCE_DIR}/renderergl2/tr_fbo.c
    ${SOURCE_DIR}/renderergl2/tr_flares.c
    ${SOURCE_DIR}/renderergl2/tr_font.cpp
    ${SOURCE_DIR}/renderergl2/tr_ghost.cpp
    ${SOURCE_DIR}/renderergl2/tr_glsl.c
    ${SOURCE_DIR}/renderergl2/tr_image.c
    ${SOURCE_DIR}/renderergl2/tr_image_dds.c
    ${SOURCE_DIR}/renderergl2/tr_init.c
    ${SOURCE_DIR}/renderergl2/tr_light.c
    ${SOURCE_DIR}/renderergl2/tr_main.c
    ${SOURCE_DIR}/renderergl2/tr_marks_permanent.c
    ${SOURCE_DIR}/renderergl2/tr_marks.c
    ${SOURCE_DIR}/renderergl2/tr_mesh.c
    ${SOURCE_DIR}/renderergl2/tr_model_iqm.c
    ${SOURCE_DIR}/renderergl2/tr_model.cpp
    ${SOURCE_DIR}/renderergl2/tr_postprocess.c
    ${SOURCE_DIR}/renderergl2/tr_scene.c
    ${SOURCE_DIR}/renderergl2/tr_shade_calc.c
    ${SOURCE_DIR}/renderergl2/tr_shade.c
    ${SOURCE_DIR}/renderergl2/tr_shader.c
    ${SOURCE_DIR}/renderergl2/tr_shadows.c
    ${SOURCE_DIR}/renderergl2/tr_sky_portal.cpp
    ${SOURCE_DIR}/renderergl2/tr_sky.c
    ${SOURCE_DIR}/renderergl2/tr_sphere_shade.cpp
    ${SOURCE_DIR}/renderergl2/tr_sprite.c
    ${SOURCE_DIR}/renderergl2/tr_staticmodels.cpp
    ${SOURCE_DIR}/renderergl2/tr_sun_flare.cpp
    ${SOURCE_DIR}/renderergl2/tr_surface.c
    ${SOURCE_DIR}/renderergl2/tr_swipe.cpp
    ${SOURCE_DIR}/renderergl2/tr_terrain.c
    ${SOURCE_DIR}/renderergl2/tr_util.cpp
    ${SOURCE_DIR}/renderergl2/tr_vbo.c
    ${SOURCE_DIR}/renderergl2/tr_vis.cpp
    ${SOURCE_DIR}/renderergl2/tr_world.c
)

file(GLOB RENDERER_METAL_SHADER_SOURCES ${SOURCE_DIR}/renderergl2/glsl/*.glsl)

# Separate output directory from renderer_gl2's shaders.dir: both targets
# stringify the exact same .glsl files, and CMake doesn't allow two custom
# commands to share one OUTPUT path, so this must not collide with GL2's when
# both renderers are built in the same configure.
set(SHADERS_METAL_DIR ${CMAKE_BINARY_DIR}/shaders-metal.dir)
file(MAKE_DIRECTORY ${SHADERS_METAL_DIR})

foreach(SHADER_FILE IN LISTS RENDERER_METAL_SHADER_SOURCES)
    get_filename_component(SHADER_NAME ${SHADER_FILE} NAME_WE)
    set(SHADER_C_FILE ${SHADERS_METAL_DIR}/${SHADER_NAME}.c)

    string(REPLACE "${CMAKE_BINARY_DIR}/" "" SHADER_C_FILE_COMMENT ${SHADER_C_FILE})

    add_custom_command(
        OUTPUT ${SHADER_C_FILE}
        COMMAND ${CMAKE_COMMAND}
            -DINPUT_FILE=${SHADER_FILE}
            -DOUTPUT_FILE=${SHADER_C_FILE}
            -DSHADER_NAME=${SHADER_NAME}
            -P ${CMAKE_SOURCE_DIR}/cmake/utils/stringify_shader.cmake
        DEPENDS ${SHADER_FILE}
        COMMENT "Stringify shader ${SHADER_C_FILE_COMMENT}")

    list(APPEND RENDERER_METAL_SHADER_C_SOURCES ${SHADER_C_FILE})
endforeach()

set(RENDERER_METAL_BASENAME renderer_metal)
set(RENDERER_METAL_BINARY ${RENDERER_METAL_BASENAME})

set(ANGLE_DIR ${SOURCE_DIR}/thirdparty/angle)
set(ANGLE_LIB_DIR ${SOURCE_DIR}/thirdparty/libs/macos/angle)
set(ANGLE_LIBRARIES
    ${ANGLE_LIB_DIR}/libEGL.dylib
    ${ANGLE_LIB_DIR}/libGLESv2.dylib)

list(APPEND RENDERER_METAL_BINARY_SOURCES
    ${RENDERER_COMMON_SOURCES}
    ${RENDERER_METAL_SOURCES}
    ${RENDERER_METAL_SHADER_C_SOURCES}
    ${SDL_METAL_RENDERER_SOURCES}
    ${RENDERER_LIBRARY_SOURCES})

if(USE_RENDERER_DLOPEN)
    list(APPEND RENDERER_METAL_BINARY_SOURCES ${DYNAMIC_RENDERER_SOURCES})

    add_library(${RENDERER_METAL_BINARY} SHARED ${RENDERER_METAL_BINARY_SOURCES})

    # The vendored ANGLE build is arm64-only (built natively on this Mac; see
    # code/thirdparty/angle/README - there's no x86_64 slice, and no need for
    # one on Apple Silicon). Restrict just this target so it doesn't break the
    # client's universal (arm64;x86_64) build; it's loaded via dlopen at
    # runtime like the other renderers, so this doesn't affect them.
    set_target_properties(${RENDERER_METAL_BINARY} PROPERTIES OSX_ARCHITECTURES "arm64")

    target_link_libraries(      ${RENDERER_METAL_BINARY} PRIVATE ${RENDERER_LIBRARIES} ${ANGLE_LIBRARIES})
    target_include_directories( ${RENDERER_METAL_BINARY} PRIVATE ${RENDERER_INCLUDE_DIRS} ${ANGLE_DIR}/include)
    target_compile_definitions( ${RENDERER_METAL_BINARY} PRIVATE ${RENDERER_DEFINITIONS})
    target_compile_options(     ${RENDERER_METAL_BINARY} PRIVATE ${RENDERER_COMPILE_OPTIONS})
    target_link_options(        ${RENDERER_METAL_BINARY} PRIVATE ${RENDERER_LINK_OPTIONS})

    set_output_dirs(${RENDERER_METAL_BINARY})

    INSTALL(TARGETS ${RENDERER_METAL_BINARY} DESTINATION ${INSTALL_LIBDIR_FULL})

    # ANGLE's dylibs need to sit next to the client binary, same as the
    # vendored SDL2 dylib (see cmake/libraries/sdl.cmake); their install
    # names were already rewritten to @executable_path when vendored.
    list(APPEND CLIENT_DEPLOY_LIBRARIES ${ANGLE_LIBRARIES})
endif()
