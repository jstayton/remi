# Builds only UxPlay's AirPlay protocol library (no GStreamer renderers) as
# static libraries that the Remi Xcode target links against. Run through
# bin/build-uxplay, which prepares the patched sources and libplist.
cmake_minimum_required(VERSION 3.13)
project(remi_uxplay C)

set(UXPLAY_DIR "" CACHE PATH "Patched copy of UxPlay sources")

add_subdirectory(${UXPLAY_DIR}/lib/llhttp llhttp)
add_subdirectory(${UXPLAY_DIR}/lib/playfair playfair)
add_subdirectory(${UXPLAY_DIR}/lib airplay)

# Tests of the patches, built and run by bin/test. Excluded from the default build so a
# broken test never breaks the app's build.
find_package(PkgConfig REQUIRED)
pkg_check_modules(TEST_OPENSSL REQUIRED openssl>=3)
pkg_check_modules(TEST_PLIST REQUIRED libplist-2.0)
add_library(test_support STATIC EXCLUDE_FROM_ALL tests/check.c tests/client.c tests/receiver.c
            tests/srp_client.c)
target_include_directories(test_support PUBLIC ${UXPLAY_DIR}/lib ${TEST_OPENSSL_INCLUDE_DIRS} ${TEST_PLIST_INCLUDE_DIRS})
target_compile_options(test_support PUBLIC -Wall -Werror)
target_link_libraries(test_support PUBLIC airplay)
foreach(test pairing_test srp_test)
  add_executable(${test} EXCLUDE_FROM_ALL tests/${test}.c)
  target_link_libraries(${test} test_support)
endforeach()
