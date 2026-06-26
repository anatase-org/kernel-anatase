#!/bin/bash

set -e

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

ARCH=${ARCH:-$(uname -m)}
FEDORA_VERSION=${FEDORA_VERSION:-44}
PE_SIGNING_PIN=${PE_SIGNING_PIN:-}
PE_SIGNING_TOKEN=${PE_SIGNING_TOKEN:-}
PE_SIGNING_CERT=${PE_SIGNING_CERT:-}
PE_SIGNING_PIN_VALUE=${PE_SIGNING_PIN_VALUE:-}

case "$PE_SIGNING_PIN" in
    1|true|TRUE|yes|YES|on|ON)
        PE_SIGNING_PIN=1
        if [ -z "$PE_SIGNING_PIN_VALUE" ]; then
            read -r -s -p "Enter Pin: " PE_SIGNING_PIN_VALUE
            printf '\n'
        fi
        ;;
    0|false|FALSE|no|NO|off|OFF|'')
        PE_SIGNING_PIN=0
        PE_SIGNING_PIN_VALUE=
        ;;
    *)
        echo "Error: PE_SIGNING_PIN must be 0 or 1"
        exit 1
        ;;
esac

export PE_SIGNING_PIN_VALUE PE_SIGNING_TOKEN PE_SIGNING_CERT

secret_opts=(
    --secret "id=PE_SIGNING_TOKEN,env=PE_SIGNING_TOKEN"
    --secret "id=PE_SIGNING_CERT,env=PE_SIGNING_CERT"
)

if [ -n "$PE_SIGNING_PIN_VALUE" ]; then
    secret_opts+=(--secret "id=PE_SIGNING_PIN_VALUE,env=PE_SIGNING_PIN_VALUE")
fi

card_opts=()

if [ -n "$PE_SIGNING_TOKEN" ] || [ -n "$PE_SIGNING_CERT" ]; then
    [ -S /run/pcscd/pcscd.comm ] || { echo "Error: pcscd socket not found at /run/pcscd/pcscd.comm"; exit 1; }
    card_opts+=(-v /run/pcscd:/run/pcscd --security-opt label=disable)
fi

TARFILE_RELEASE=$(sed -n 's/^%define[[:space:]]\+tarfile_release[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE=$(sed -n 's/^%define[[:space:]]\+nvidia_version[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE_REL=$(sed -n 's/^%define[[:space:]]\+nvidia_version_rel[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE_LTS=$(sed -n 's/^%define[[:space:]]\+nvidia_version_lts[[:space:]]\+//p' kernel.spec)
ZFS_RELEASE=$(sed -n 's/^%define[[:space:]]\+zfs_version[[:space:]]\+//p' kernel.spec)

echo "TARFILE_RELEASE is $TARFILE_RELEASE"
echo "NVIDIA_RELEASE is $NVIDIA_RELEASE"
echo "NVIDIA_RELEASE_LTS is $NVIDIA_RELEASE_LTS"
echo "ZFS_RELEASE is $ZFS_RELEASE"

mkdir -p ./cache

podman build \
    --build-arg="FEDORA_VERSION=$FEDORA_VERSION" \
    --build-arg "TARFILE_RELEASE=$TARFILE_RELEASE" \
    --build-arg "NVIDIA_RELEASE=$NVIDIA_RELEASE" \
    --build-arg "NVIDIA_RELEASE_REL=$NVIDIA_RELEASE_REL" \
    --build-arg "NVIDIA_RELEASE_LTS=$NVIDIA_RELEASE_LTS" \
    --build-arg "ZFS_RELEASE=$ZFS_RELEASE" \
    --build-arg "ARCH=$ARCH" \
    "${secret_opts[@]}" \
    -v "$(pwd)/cache:/cache" \
    "${card_opts[@]}" \
    --label "org.anatase.kernel.version=$TARFILE_RELEASE" \
    --label "org.anatase.kernel.nvidia=$NVIDIA_RELEASE" \
    --label "org.anatase.kernel.nvidia_lts=$NVIDIA_RELEASE_LTS" \
    --label "org.anatase.kernel.zfs=$ZFS_RELEASE" \
    . --tag "kernel:f$FEDORA_VERSION-$ARCH"
