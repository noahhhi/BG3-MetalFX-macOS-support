cmake_minimum_required(VERSION 3.20)
project(bg3metalfx LANGUAGES C CXX OBJCXX)

set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)

if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES arm64)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

file(MAKE_DIRECTORY "${CMAKE_SOURCE_DIR}/runs")

add_library(bg3mf_probe SHARED
  src/LoadProbe.mm
  src/MetalObserver.mm
  src/TraceWriter.mm
  src/TemporalBridge.mm
  src/ScalePatch.mm
  src/SettingsPolicy.mm
)
set_target_properties(bg3mf_probe PROPERTIES
  PREFIX "lib"
  SUFFIX ".dylib"
  MACOSX_RPATH ON
  INSTALL_NAME_DIR "@rpath"
)
target_compile_options(bg3mf_probe PRIVATE -fobjc-arc -Os -Wall -Wextra)
target_link_libraries(bg3mf_probe PRIVATE "-framework Foundation" "-framework Metal" "-framework MetalFX")

# arm64 上链接器默认 ad-hoc 签名；显式重签保证确定性。
add_custom_command(TARGET bg3mf_probe POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_FILE:bg3mf_probe>"
  VERBATIM
)

add_executable(bg3mf_steam_launcher src/SteamLauncher.c)
set_target_properties(bg3mf_steam_launcher PROPERTIES OUTPUT_NAME "bg3mf_steam_launcher")
add_custom_command(TARGET bg3mf_steam_launcher POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_FILE:bg3mf_steam_launcher>"
  VERBATIM
)

# ---- 阶段 C：MetalFX Temporal 独立 smoke test ----
find_program(XCRUN xcrun REQUIRED)
set(SMOKE_METALLIB "${CMAKE_BINARY_DIR}/smokeinputs.metallib")
add_custom_command(
  OUTPUT "${SMOKE_METALLIB}"
  COMMAND ${XCRUN} -sdk macosx metal -O2 -o "${CMAKE_BINARY_DIR}/smokeinputs.air"
          -c "${CMAKE_SOURCE_DIR}/shaders/SmokeInputs.metal"
  COMMAND ${XCRUN} -sdk macosx metallib "${CMAKE_BINARY_DIR}/smokeinputs.air"
          -o "${SMOKE_METALLIB}"
  DEPENDS "${CMAKE_SOURCE_DIR}/shaders/SmokeInputs.metal"
  VERBATIM
)
add_custom_target(smoke_shaders DEPENDS "${SMOKE_METALLIB}")

add_executable(bg3mf_temporal_smoke tests/TemporalSmoke.mm)
add_dependencies(bg3mf_temporal_smoke smoke_shaders)
target_compile_options(bg3mf_temporal_smoke PRIVATE -fobjc-arc -O2 -Wall)
target_compile_definitions(bg3mf_temporal_smoke PRIVATE
  SMOKE_METALLIB_PATH="${SMOKE_METALLIB}")
target_link_libraries(bg3mf_temporal_smoke PRIVATE
  "-framework Foundation" "-framework Metal" "-framework MetalFX")

add_executable(bg3mf_render_dump_sim tests/RenderDumpSim.mm)
add_dependencies(bg3mf_render_dump_sim smoke_shaders)
target_compile_options(bg3mf_render_dump_sim PRIVATE -fobjc-arc -O2)
target_compile_definitions(bg3mf_render_dump_sim PRIVATE
  SMOKE_METALLIB_PATH="${SMOKE_METALLIB}")
target_link_libraries(bg3mf_render_dump_sim PRIVATE
  "-framework Foundation" "-framework Metal")

add_executable(bg3mf_temporal_bridge_sim tests/TemporalBridgeSim.mm)
add_dependencies(bg3mf_temporal_bridge_sim smoke_shaders)
target_compile_options(bg3mf_temporal_bridge_sim PRIVATE -fobjc-arc -O2)
target_compile_definitions(bg3mf_temporal_bridge_sim PRIVATE
  SMOKE_METALLIB_PATH="${SMOKE_METALLIB}")
target_link_libraries(bg3mf_temporal_bridge_sim PRIVATE
  "-framework Foundation" "-framework Metal")

add_executable(bg3mf_installer src/Installer.mm)
target_compile_options(bg3mf_installer PRIVATE -fobjc-arc -Os -Wall -Wextra)
target_link_libraries(bg3mf_installer PRIVATE "-framework Foundation" "-framework AppKit")
add_custom_command(TARGET bg3mf_installer POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_FILE:bg3mf_installer>" VERBATIM)
