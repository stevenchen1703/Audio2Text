cmake_minimum_required(VERSION 3.20)
project(DoubaoMinutesWinCpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if (MSVC)
  add_compile_options(/utf-8 /W4 /EHsc)
else()
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

add_executable(DoubaoMinutesWinCpp WIN32
  src/main.cpp
  src/AppSettings.cpp
  src/TranscriptionService.cpp
)

target_include_directories(DoubaoMinutesWinCpp PRIVATE include)

target_link_libraries(DoubaoMinutesWinCpp
  PRIVATE
    comctl32
    winhttp
    bcrypt
)
