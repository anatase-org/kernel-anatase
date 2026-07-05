#!/usr/bin/bash
set -eux

#
# Key preparation
#

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

load_secret_env() {
    local name="$1"
    local secret="/run/secrets/$name"

    if [ -z "${!name:-}" ] && [ -f "$secret" ]; then
        printf -v "$name" '%s' "$(cat "$secret")"
        export "$name"
    fi
}

load_secret_env PE_SIGNING_TOKEN
load_secret_env PE_SIGNING_CERT
load_secret_env PE_SIGNING_PIN_VALUE

CCACHE_USE=${CCACHE_USE:-1}
PE_SIGNING_TOKEN=${PE_SIGNING_TOKEN:-}
PE_SIGNING_CERT=${PE_SIGNING_CERT:-}
PE_SIGNING_PIN_VALUE=${PE_SIGNING_PIN_VALUE:-}
KMS_PKCS11_CONFIG=${KMS_PKCS11_CONFIG:-}

pin_file=''
cleanup() {
    if [ -n "$pin_file" ]; then
        rm -f "$pin_file"
    fi
}
trap cleanup EXIT

# Check we are in a container before we nuke the pesign dir
if [ -z "$container" ]; then
    echo "Error: This script should be run inside the build container."
    exit 1
fi

rpmbuild_signing_opts=()

if [ -n "$PE_SIGNING_TOKEN" ] || [ -n "$PE_SIGNING_CERT" ]; then
    [ -n "$PE_SIGNING_TOKEN" ] || { echo "Error: PE_SIGNING_TOKEN is required when PE_SIGNING_CERT is set"; exit 1; }
    [ -n "$PE_SIGNING_CERT" ] || { echo "Error: PE_SIGNING_CERT is required when PE_SIGNING_TOKEN is set"; exit 1; }
    if [ -z "$KMS_PKCS11_CONFIG" ]; then
        [ -S /run/pcscd/pcscd.comm ] || { echo "Error: pcscd socket not found at /run/pcscd/pcscd.comm"; exit 1; }
    fi

    rm -rf /etc/pki/pesign
    install -d -m 0755 /etc/pki/pesign
    certutil -N -d sql:/etc/pki/pesign --empty-password
    modutil -dbdir sql:/etc/pki/pesign -list
    rm -f /run/pesign/socket /var/run/pesign/socket

    cat > ~/.rpmmacros <<EOF
%pe_signing_token $PE_SIGNING_TOKEN
%pe_signing_cert $PE_SIGNING_CERT
EOF

    if [ -n "$KMS_PKCS11_CONFIG" ]; then
        tee /usr/local/bin/pesign-with-pin >/dev/null <<EOF
#!/usr/bin/env bash
exec /usr/bin/pesign "\$@"
EOF
        chmod 0755 /usr/local/bin/pesign-with-pin
        cat >> ~/.rpmmacros <<EOF
%_pesign /usr/local/bin/pesign-with-pin
EOF
        echo "Secure Boot signing enabled with Google Cloud KMS token '$PE_SIGNING_TOKEN' and cert '$PE_SIGNING_CERT'"
    elif [ -n "$PE_SIGNING_PIN_VALUE" ]; then
        pin_file=$(mktemp)
        chmod 600 "$pin_file"
        printf '%s\n' "$PE_SIGNING_PIN_VALUE" > "$pin_file"
        unset PE_SIGNING_PIN_VALUE

        tee /usr/local/bin/pesign-with-pin >/dev/null <<EOF
#!/usr/bin/env bash
exec /usr/bin/pesign --pinfile "$pin_file" "\$@"
EOF
        chmod 0755 /usr/local/bin/pesign-with-pin
        cat >> ~/.rpmmacros <<EOF
%_pesign /usr/local/bin/pesign-with-pin
EOF
        echo "Secure Boot signing enabled with token '$PE_SIGNING_TOKEN' and cert '$PE_SIGNING_CERT'"
    else
        echo "Secure Boot signing enabled with token '$PE_SIGNING_TOKEN' and cert '$PE_SIGNING_CERT'"
    fi

    rpmbuild_signing_opts+=(--with anatase_signing)
else
    echo "Secure Boot signing disabled; building unsigned kernel images"
fi

#
# Sources preparation
#

pushd /cache

if [ -z "$TARFILE_RELEASE" ] || [ -z "$NVIDIA_RELEASE" ] || [ -z "$ZFS_RELEASE" ]; then
    echo "Error: Could not determine TARFILE_RELEASE, NVIDIA_RELEASE, or ZFS_RELEASE from kernel.spec"
    exit 1
fi

linuxfn="linux-${TARFILE_RELEASE}.tar.xz"
zfsfn="zfs-${ZFS_RELEASE}.tar.gz"

if [ ! -f "$linuxfn" ]; then
    echo "Downloading $linuxfn"
    kernel_major=${TARFILE_RELEASE%%.*}
    curl -L -o "$linuxfn" "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/linux-${TARFILE_RELEASE}.tar.xz"
fi
if [ ! -f "$zfsfn" ]; then
    echo "Downloading $zfsfn"
    curl -L -o "$zfsfn" \
        "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_RELEASE}/zfs-${ZFS_RELEASE}.tar.gz"
fi

nvreleases=($NVIDIA_RELEASE)
if [ "$NVIDIA_RELEASE" != "$NVIDIA_RELEASE_LTS" ]; then
    nvreleases+=($NVIDIA_RELEASE_LTS)
fi

#
# Open source driver
#

ofn="nvidia-kmod-${ARCH}-${NVIDIA_RELEASE}-${NVIDIA_RELEASE_REL}.tar.gz"
if [ ! -f "$ofn" ]; then
    echo "Downloading open source NVIDIA driver for release $NVIDIA_RELEASE"
    curl -L -o nvidia-kmod-${ARCH}-${NVIDIA_RELEASE}-${NVIDIA_RELEASE_REL}.tar.gz\
        https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${NVIDIA_RELEASE}.tar.gz 
fi

#
# Closed legacy driver
#

nvrelease=$NVIDIA_RELEASE_LTS
# We need to do this to strip the driver from the srpm. Keeping two of
# Them would be a nice 800MB, here we drop to 160MB. We could halve
# that if we only keep the closed for LTS.
echo "Processing NVIDIA release $nvrelease for arch $ARCH"
RUN_FN="NVIDIA-Linux-$ARCH-${nvrelease}.run"
tarfn="nvidia-kmod-${ARCH}-${nvrelease}.tar.xz"

if [ ! -f "$RUN_FN" ]; then
    echo "Downloading $RUN_FN"
    curl -L -o $RUN_FN \
                "https://download.nvidia.com/XFree86/Linux-$ARCH/${nvrelease}/NVIDIA-Linux-$ARCH-${nvrelease}.run"
fi

if [ ! -f "$tarfn" ]; then
    rm -rf build/nvidia
    mkdir -p build/nvidia/kmod

    chmod +x $RUN_FN
    ./$RUN_FN --extract-only --target build/nvidia/extract

    mv build/nvidia/extract/kernel/* build/nvidia/kmod

    XZ_OPT='-T0' tar --remove-files -cJf $tarfn -C build/nvidia/kmod .
    echo "Created $tarfn"
    rm -rf build/nvidia
fi

popd

cp /cache/$linuxfn /cache/$zfsfn /cache/$ofn /cache/$tarfn .

#
# Build
#

echo "Starting build for Fedora $FEDORA_VERSION, arch $ARCH"
unset ARCH # There seems to be an issue here

if [ "$CCACHE_USE" -eq 1 ]; then
    echo "Using ccache for build"
    export PATH="/usr/lib64/ccache:/usr/lib/ccache:$PATH"
    export CC="ccache gcc"
    export CXX="ccache g++"
    export CCACHE_MAXSIZE="5G"
    export CCACHE_DIR="/cache/ccache"
fi

rpmbuild \
  --define '_topdir    /build' \
  --define '_builddir  /build' \
  --define '_rpmdir    /artifacts/RPMS' \
  --define '_srcrpmdir /artifacts/SRPMS' \
  --define '_sourcedir %(pwd)/' \
  --define '_specdir   %(pwd)/' \
  --with anatase "${rpmbuild_signing_opts[@]}" --with nvidia --with zfs \
  -ba kernel.spec &
rpmbuild_pid=$!

trap 'pkill --signal=SIGKILL -P $$; cleanup; exit 130' INT
set +e
wait "$rpmbuild_pid"
rpmbuild_status=$?
set -e
# Remove /build dir so we do not commit it
rm -rf /build
exit "$rpmbuild_status"
