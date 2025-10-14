#!/bin/bash
set -e

# Setup VC-LTL and xwin
if [ $TARGET_PLATFORM = windows-msvc ]; then
  # Setup VC-LTL
  curl -LO --output-dir ${RUNNER_TEMP} https://github.com/Chuyu-Team/VC-LTL5/releases/download/v${VCLTL_VERSION}/VC-LTL-Binary.7z
  mkdir ${RUNNER_TEMP}/VC-LTL
  bsdtar -xC ${RUNNER_TEMP}/VC-LTL -f ${RUNNER_TEMP}/VC-LTL-Binary.7z TargetPlatform

  # Setup xwin
  xwin --accept-license --arch $TARGET_ARCH --variant desktop --channel release --sdk-version ${XWIN_SDK_VERSION} splat --preserve-ms-arch-notation --output ${RUNNER_TEMP}/xwin
fi

# Build
zig_args=(
  -Dtarget=${TARGET_TRIPLE}
  -Doptimize=${OPTIMIZE_MODE}
)
if [ $TARGET_PLATFORM = linux-musl ]; then
  zig_args+=(
    -Dmimalloc
  )
elif [ $TARGET_PLATFORM = windows-msvc ]; then
  zig_args+=(
    -Dvc-ltl-dir=${RUNNER_TEMP}/VC-LTL/TargetPlatform/${VCLTL_TARGET_VERSION}
    -Dxwin-dir=${RUNNER_TEMP}/xwin
  )
elif [ $TARGET_PLATFORM = macos ]; then
  zig_args+=(
    --sysroot "/Applications/Xcode_${XCODE_VERSION}.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX${MACOS_SDK_VERSION}.sdk"
    -Dterms=aquaterm
  )
elif [ $TARGET_PLATFORM = wasi ]; then
  zig_args+=(
    -Dcpu="lime1+bulk_memory+reference_types+simd128"
    -Dmimalloc
  )
fi
zig build "${zig_args[@]}"

# Pack
mkdir dist
cp LICENSE dist
cd dist
curl -o 'COPYRIGHT' 'https://sourceforge.net/p/gnuplot/gnuplot-main/ci/6f43f417/tree/Copyright?format=raw'
cp ../zig-out/bin/gnuplot{,.exe,.wasm} . 2>/dev/null || :
if [ $TARGET_PLATFORM = windows-msvc ]; then
  bsdtar -a -cf ../gnuplot-${TARGET_TRIPLE}.zip *
else
  XZ_OPT=-9 bsdtar cJf ../gnuplot-${TARGET_TRIPLE}.tar.xz *
fi
