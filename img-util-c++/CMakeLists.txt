cmake_minimum_required(VERSION 3.16)
project(img_util_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(CURL REQUIRED)

add_executable(img-util-cpp
  src/main.cpp
)

target_link_libraries(img-util-cpp PRIVATE CURL::libcurl)
