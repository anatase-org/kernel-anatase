ARG BUILDER_IMAGE
FROM ${BUILDER_IMAGE} AS build

WORKDIR /workspace

COPY . /workspace

ARG FEDORA_VERSION=44
ARG TARFILE_RELEASE
ARG NVIDIA_RELEASE
ARG NVIDIA_RELEASE_REL
ARG NVIDIA_RELEASE_LTS
ARG ZFS_RELEASE
ARG ARCH
ARG PE_SIGNING_TOKEN=
ARG PE_SIGNING_CERT=
ARG PE_SIGNING_PIN=0
ARG GCP_KMS_KEY_RING=

RUN --mount=type=secret,id=pe_signing_pin \
    --mount=type=secret,id=google_application_credentials \
    --mount=type=secret,id=gcp_kms_certificate \
    set -eux; \
    if [ -n "${GCP_KMS_KEY_RING}" ]; then \
        install -d -m 0700 /run/kmsp11; \
        { \
            printf '%s\n' '---' 'tokens:' "  - key_ring: \"${GCP_KMS_KEY_RING}\"" "    label: \"${PE_SIGNING_TOKEN}\""; \
            if [ -s /run/secrets/gcp_kms_certificate ]; then \
                printf '%s\n' '    certs:' '      - |'; \
                sed 's/^/        /' /run/secrets/gcp_kms_certificate; \
            fi; \
        } > /run/kmsp11/config.yaml; \
        chmod 0600 /run/kmsp11/config.yaml; \
        export KMS_PKCS11_CONFIG=/run/kmsp11/config.yaml; \
        if [ -s /run/secrets/google_application_credentials ]; then export GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/google_application_credentials; fi; \
    fi; \
    if [ -s /run/secrets/pe_signing_pin ]; then \
        PE_SIGNING_PIN_VALUE="$(cat /run/secrets/pe_signing_pin)"; \
        export PE_SIGNING_PIN_VALUE; \
    fi; \
    export FEDORA_VERSION TARFILE_RELEASE NVIDIA_RELEASE NVIDIA_RELEASE_REL NVIDIA_RELEASE_LTS ZFS_RELEASE ARCH; \
    export PE_SIGNING_TOKEN PE_SIGNING_CERT PE_SIGNING_PIN; \
    /workspace/compile.sh

RUN find /artifacts/RPMS -type f \( -name '*debuginfo*.rpm' -o -name '*debugsource*.rpm' \) -delete

FROM scratch

ARG ARCH

COPY --from=build /artifacts/RPMS/$ARCH /rpms
COPY --from=build /artifacts/SRPMS /srpms

ENTRYPOINT [ "env" ]
