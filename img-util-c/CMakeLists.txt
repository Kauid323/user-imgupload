cmake_minimum_required(VERSION 3.16)
project(img_util_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(CURL REQUIRED)

add_executable(img-util-c
  src/main.c
)

target_link_libraries(img-util-c PRIVATE CURL::libcurl)
