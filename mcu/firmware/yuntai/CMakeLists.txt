cmake_minimum_required(VERSION 3.22)

#
# This file is generated only once,
# and is not re-generated if converter is called multiple times.
#
# User is free to modify the file as much as necessary
#

# Setup compiler settings
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)


# Define the build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug")
endif()

# Set the project name
set(CMAKE_PROJECT_NAME yuntai)

# Enable compile command to ease indexing with e.g. clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)

# Core project settings
project(${CMAKE_PROJECT_NAME})
message("Build type: " ${CMAKE_BUILD_TYPE})

# Enable CMake support for ASM and C languages
enable_language(C ASM)

# Create an executable object type
add_executable(${CMAKE_PROJECT_NAME})

# Add STM32CubeMX generated sources
add_subdirectory(cmake/stm32cubemx)

# Link directories setup
target_link_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined library search paths
)

# Add sources to executable
# mpu6050.c is intentionally not built: pose fusion was dropped in favour of
# servo position feedback (see README). The driver and its host test stay.
target_sources(${CMAKE_PROJECT_NAME} PRIVATE
    Core/Src/ring_buffer.c
    Core/Src/uart_servo_lite.c
    Core/Src/host_console.c
    Core/Src/gimbal_test.c
    Core/Src/f1_link.c
    ../common/board.c
    ../common/wire.c
    ../common/pose.c
)

# Add include paths
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
    ../common
    # Add user defined include paths
)

# Add project symbols (macros)
# NOTE: the temporary bench move test (GIMBAL_BENCH_MOVE_TEST) has been removed
# after collecting its data. No diagnostic stamp is inserted into the IMU
# fields: current F1 STATE accelerometer/gyro/temperature values remain zero.
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
    MCU_F1
    # Add user defined symbols
)

# Remove wrong libob.a library dependency when using cpp files
# I2C1 HAL is not compiled any more: MPU6050 pose fusion was dropped.
list(REMOVE_ITEM CMAKE_C_IMPLICIT_LINK_LIBRARIES ob)

# Add linked libraries
target_link_libraries(${CMAKE_PROJECT_NAME}
    stm32cubemx

    # Add user defined libraries
)
