#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

ARCH=${ARCH:-$(uname -m)}
FEDORA_VERSION=${FEDORA_VERSION:-44}
CCACHE_USE=${CCACHE_USE:-1}
PE_SIGNING_PIN=${PE_SIGNING_PIN:-0}
PE_SIGNING_TOKEN=${PE_SIGNING_TOKEN:-}
PE_SIGNING_CERT=${PE_SIGNING_CERT:-}
PE_SIGNING_PIN_VALUE=${PE_SIGNING_PIN_VALUE:-}
GCP_KMS_KEY=${GCP_KMS_KEY:-}
GCP_KMS_CERT=${GCP_KMS_CERT:-}
PUSH_IMAGE=${PUSH_IMAGE:-0}
IMAGE_REF=${IMAGE_REF:-ghcr.io/anatase-org/kernel:f${FEDORA_VERSION}-${ARCH}}
BUILDER_IMAGE=${BUILDER_IMAGE:-ghcr.io/anatase-org/sb-builder:f${FEDORA_VERSION}-${ARCH}}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

normalize_bool() {
    case "${2}" in
        1|true|TRUE|yes|YES|on|ON)
            printf -v "$1" 1
            ;;
        0|false|FALSE|no|NO|off|OFF|'')
            printf -v "$1" 0
            ;;
        *)
            die "${1} must be 0 or 1"
            ;;
    esac
}

case "${FEDORA_VERSION}" in
    ''|*[!0-9]*)
        die "FEDORA_VERSION must be a Fedora release number"
        ;;
esac

normalize_bool PE_SIGNING_PIN "${PE_SIGNING_PIN}"
normalize_bool PUSH_IMAGE "${PUSH_IMAGE}"
normalize_bool CCACHE_USE "${CCACHE_USE}"

TARFILE_RELEASE=$(sed -n 's/^%define[[:space:]]\+tarfile_release[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE=$(sed -n 's/^%define[[:space:]]\+nvidia_version[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE_REL=$(sed -n 's/^%define[[:space:]]\+nvidia_version_rel[[:space:]]\+//p' kernel.spec)
NVIDIA_RELEASE_LTS=$(sed -n 's/^%define[[:space:]]\+nvidia_version_lts[[:space:]]\+//p' kernel.spec)
ZFS_RELEASE=$(sed -n 's/^%define[[:space:]]\+zfs_version[[:space:]]\+//p' kernel.spec)

[ -n "${TARFILE_RELEASE}" ] || die "Could not determine tarfile_release from kernel.spec"
[ -n "${NVIDIA_RELEASE}" ] || die "Could not determine nvidia_version from kernel.spec"
[ -n "${NVIDIA_RELEASE_REL}" ] || die "Could not determine nvidia_version_rel from kernel.spec"
[ -n "${NVIDIA_RELEASE_LTS}" ] || die "Could not determine nvidia_version_lts from kernel.spec"
[ -n "${ZFS_RELEASE}" ] || die "Could not determine zfs_version from kernel.spec"

printf 'Using builder image %s\n' "${BUILDER_IMAGE}"
printf 'Building kernel artifact image %s\n' "${IMAGE_REF}"
printf 'TARFILE_RELEASE is %s\n' "${TARFILE_RELEASE}"
printf 'NVIDIA_RELEASE is %s\n' "${NVIDIA_RELEASE}"
printf 'NVIDIA_RELEASE_LTS is %s\n' "${NVIDIA_RELEASE_LTS}"
printf 'ZFS_RELEASE is %s\n' "${ZFS_RELEASE}"

command -v podman >/dev/null 2>&1 || die "podman is required"

IMAGE_REPOSITORY="${IMAGE_REF%:*}"
KERNEL_IMAGE_REF="${IMAGE_REPOSITORY}:f${FEDORA_VERSION}-${ARCH}-${TARFILE_RELEASE}"
printf 'Tagging kernel version image %s\n' "${KERNEL_IMAGE_REF}"

mkdir -p ./cache

secret_opts=()
volume_opts=(-v "$(pwd)/cache:/cache:Z")
gcp_kms_key_ring=

if [ -n "${GCP_KMS_KEY}" ]; then
    [ -n "${PE_SIGNING_TOKEN}" ] || die "PE_SIGNING_TOKEN is required for signing"
    [ -n "${PE_SIGNING_CERT}" ] || die "PE_SIGNING_CERT is required for signing"
    [ "${PE_SIGNING_PIN}" = 0 ] || die "PE_SIGNING_PIN must be 0 when using GCP_KMS_KEY"
    [ -n "${GCP_KMS_CERT}" ] || die "GCP_KMS_CERT is required when using GCP_KMS_KEY"
    [ -f "${GCP_KMS_CERT}" ] || die "GCP_KMS_CERT does not exist: ${GCP_KMS_CERT}"

    case "${GCP_KMS_KEY}" in
        projects/*/locations/*/keyRings/*/cryptoKeys/*)
            gcp_kms_key_ring="${GCP_KMS_KEY%%/cryptoKeys/*}"
            ;;
        *)
            die "GCP_KMS_KEY must look like projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/KEY[/cryptoKeyVersions/VERSION]"
            ;;
    esac

    adc_file="${GOOGLE_APPLICATION_CREDENTIALS:-${HOME}/.config/gcloud/application_default_credentials.json}"
    [ -f "${adc_file}" ] || die "Google ADC file not found at ${adc_file}; run gcloud auth application-default login or set GOOGLE_APPLICATION_CREDENTIALS"

    secret_opts+=(
        --secret "id=gcp_kms_certificate,src=${GCP_KMS_CERT}"
        --secret "id=google_application_credentials,src=${adc_file}"
    )
elif [ -n "${PE_SIGNING_TOKEN}" ] || [ -n "${PE_SIGNING_CERT}" ]; then
    [ -n "${PE_SIGNING_TOKEN}" ] || die "PE_SIGNING_TOKEN is required when PE_SIGNING_CERT is set"
    [ -n "${PE_SIGNING_CERT}" ] || die "PE_SIGNING_CERT is required when PE_SIGNING_TOKEN is set"
    [ -z "${GCP_KMS_CERT}" ] || die "GCP_KMS_CERT requires GCP_KMS_KEY"
    [ -S /run/pcscd/pcscd.comm ] || die "pcscd socket not found at /run/pcscd/pcscd.comm"

    volume_opts+=(-v /run/pcscd:/run/pcscd --security-opt label=disable)

    if [ "${PE_SIGNING_PIN}" = 1 ]; then
        if [ -z "${PE_SIGNING_PIN_VALUE}" ]; then
            read -r -s -p "Enter Pin: " PE_SIGNING_PIN_VALUE
            printf '\n'
        fi
        export PE_SIGNING_PIN_VALUE
        secret_opts+=(--secret "id=pe_signing_pin,env=PE_SIGNING_PIN_VALUE")
    fi
else
    [ "${PE_SIGNING_PIN}" = 0 ] || die "PE_SIGNING_PIN=1 requires PE_SIGNING_TOKEN and PE_SIGNING_CERT"
    [ -z "${GCP_KMS_CERT}" ] || die "GCP_KMS_CERT requires GCP_KMS_KEY"
fi

podman build \
    --pull=always \
    --build-arg "BUILDER_IMAGE=${BUILDER_IMAGE}" \
    --build-arg "FEDORA_VERSION=${FEDORA_VERSION}" \
    --build-arg "CCACHE_USE=${CCACHE_USE}" \
    --build-arg "TARFILE_RELEASE=${TARFILE_RELEASE}" \
    --build-arg "NVIDIA_RELEASE=${NVIDIA_RELEASE}" \
    --build-arg "NVIDIA_RELEASE_REL=${NVIDIA_RELEASE_REL}" \
    --build-arg "NVIDIA_RELEASE_LTS=${NVIDIA_RELEASE_LTS}" \
    --build-arg "ZFS_RELEASE=${ZFS_RELEASE}" \
    --build-arg "ARCH=${ARCH}" \
    --build-arg "PE_SIGNING_TOKEN=${PE_SIGNING_TOKEN}" \
    --build-arg "PE_SIGNING_CERT=${PE_SIGNING_CERT}" \
    --build-arg "PE_SIGNING_PIN=${PE_SIGNING_PIN}" \
    --build-arg "GCP_KMS_KEY_RING=${gcp_kms_key_ring}" \
    "${secret_opts[@]}" \
    "${volume_opts[@]}" \
    --label "org.anatase.kernel.version=${TARFILE_RELEASE}" \
    --label "org.anatase.kernel.nvidia=${NVIDIA_RELEASE}" \
    --label "org.anatase.kernel.nvidia_lts=${NVIDIA_RELEASE_LTS}" \
    --label "org.anatase.kernel.zfs=${ZFS_RELEASE}" \
    -f Containerfile \
    -t "${IMAGE_REF}" \
    .

podman tag "${IMAGE_REF}" "${KERNEL_IMAGE_REF}"

if [ "${PUSH_IMAGE}" = 1 ]; then
    digest_file=$(mktemp)
    trap 'rm -f "${digest_file:-}"' EXIT

    printf 'Pushing kernel artifact image %s\n' "${IMAGE_REF}"
    podman push --digestfile "${digest_file}" "${IMAGE_REF}"

    printf 'Pushing kernel artifact image %s\n' "${KERNEL_IMAGE_REF}"
    podman push "${KERNEL_IMAGE_REF}"

    digest=$(cat "${digest_file}")
    printf 'digest=%s\n' "${digest}"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'digest=%s\n' "${digest}" >> "${GITHUB_OUTPUT}"
    fi
fi
