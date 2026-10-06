#!/bin/bash
rm -r build
mkdir build
set -e
set -x
autoreconf --install >>build/1_autoreconf.log 2>&1
./configure  >>build/2_configure.log 2>&1
make all -j25  >>build/3_make_all.log 2>&1
cd images
./getresources >>../build/4_getresources.log 2>&1
./buildpbaroot >>../build/5_buildpbaroot.log 2>&1
./buildbios >>../build/6_buildbios.log 2>&1
./buildUEFI64 >>../build/7_buildUEFI64.log 2>&1
./buildrescue Rescue32 >>../build/8_buildRescue32.log 2>&1
# Rescue64 (syslinux, unsigned) is superseded: boot the UEFI64 image from USB instead (docs/TPM_CIK.md)
cd ..
echo "Build done"