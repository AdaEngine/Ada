# Benchmark app

set(BOX3D_BENCHMARK_FILES
	main.c
)

add_executable(benchmark ${BOX3D_BENCHMARK_FILES})

set_target_properties(benchmark PROPERTIES C_STANDARD 17)

target_link_libraries(benchmark PRIVATE box3d shared)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "" FILES ${BOX3D_BENCHMARK_FILES})