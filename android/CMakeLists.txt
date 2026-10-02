cmake_minimum_required(VERSION 3.22.1)
project("dartnative_file_picker" C CXX)

add_library(dartnative_file_picker SHARED
    src/main/cpp/dn_file_picker_bridge.cpp
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# find_library, never find_package(JNI): the NDK supplies the JNI headers during
# cross-compilation, while find_package looks for a host JDK and fails.
find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(dartnative_file_picker
    ${log-lib}
    ${android-lib}
)
