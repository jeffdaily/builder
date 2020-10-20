#!/bin/bash

set -ex

ROCM_VERSION=$1

if [[ -z $ROCM_VERSION ]]; then
    echo "missing ROCM_VERSION"
    exit 1;
fi

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

yum update -y
yum install -y kmod
yum install -y wget
yum install -y openblas-devel

yum install -y epel-release
yum install -y dkms kernel-headers-`uname -r` kernel-devel-`uname -r`

echo "[ROCm]" > /etc/yum.repos.d/rocm.repo
echo "name=ROCm" >> /etc/yum.repos.d/rocm.repo
echo "baseurl=http://repo.radeon.com/rocm/yum/${ROCM_VERSION}" >> /etc/yum.repos.d/rocm.repo
echo "enabled=1" >> /etc/yum.repos.d/rocm.repo
echo "gpgcheck=0" >> /etc/yum.repos.d/rocm.repo

yum update -y

yum install -y \
                 rocm-dev \
                 rocm-utils \
                 rocfft \
                 miopen-hip \
                 rocblas \
                 hipsparse \
                 rocrand \
                 rccl \
                 hipcub \
                 rocthrust \
                 rocprofiler-dev \
                 roctracer-dev

# Build custom MIOpen to use comgr for offline compilation.

## Need a sanitized ROCM_VERSION without patchlevel; patchlevel version 0 must be added to paths.
ROCM_DOTS=$(echo ${ROCM_VERSION} | tr -d -c '.' | wc -c)
if [[ ${ROCM_DOTS} == 1 ]]; then
    ROCM_VERSION_NOPATCH="${ROCM_VERSION}"
    ROCM_INSTALL_PATH="/opt/rocm-${ROCM_VERSION}.0"
else
    ROCM_VERSION_NOPATCH="${ROCM_VERSION%.*}"
    ROCM_INSTALL_PATH="/opt/rocm-${ROCM_VERSION}"
fi

## MIOpen minimum requirements

### Boost; No viable yum package exists. Must use static linking with PIC.
retry wget https://dl.bintray.com/boostorg/release/1.72.0/source/boost_1_72_0.tar.gz
tar xzf boost_1_72_0.tar.gz
pushd boost_1_72_0
./bootstrap.sh
./b2 -j $(nproc) threading=multi link=static cxxflags=-fPIC --with-system --with-filesystem install
popd
rm -rf boost_1_72_0
rm -f  boost_1_72_0.tar.gz

### sqlite; No viable yum package exists. Must be at least version 3.14.
retry wget https://sqlite.org/2017/sqlite-autoconf-3170000.tar.gz
tar xzf sqlite-autoconf-3170000.tar.gz
pushd sqlite-autoconf-3170000
./configure --with-pic
make -j $(nproc)
make install
popd
rm -rf sqlite-autoconf-3170000
rm -f  sqlite-autoconf-3170000.tar.gz

### half header
retry curl -fsSL https://raw.githubusercontent.com/ROCmSoftwarePlatform/half/master/include/half.hpp -o /usr/include/half.hpp

### bzip2
yum install -y bzip2-devel

## Build MIOpen
git clone https://github.com/ROCmSoftwarePlatform/MIOpen -b rocm-${ROCM_VERSION_NOPATCH}.x
pushd MIOpen
mkdir -p build
cd build
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig CXX=${ROCM_INSTALL_PATH}/llvm/bin/clang++ cmake .. -DMIOPEN_USE_COMGR=ON -DMIOPEN_BACKEND=HIP -DCMAKE_PREFIX_PATH="${ROCM_INSTALL_PATH}/hip;${ROCM_INSTALL_PATH}"
make MIOpen -j $(nproc)
# Copy MIOpen library on top of package location, e.g., libMIOpen.so.1.0.30700
cp lib/libMIOpen.so ${ROCM_INSTALL_PATH}/miopen/lib/libMIOpen.so.*.*
popd
rm -rf MIOpen

# Cleanup
yum clean all
rm -rf /var/cache/yum
rm -rf /var/lib/yum/yumdb
rm -rf /var/lib/yum/history
