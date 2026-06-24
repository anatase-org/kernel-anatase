ARG FEDORA_VERSION=44

FROM fedora:${FEDORA_VERSION} AS build

RUN dnf install -y fedpkg fedora-packager rpmdevtools ncurses-devel pesign opensc \
    asciidoc audit-libs-devel bc bindgen binutils-devel bison clang dwarves \
    elfutils-devel flex fuse-devel gcc gcc-c++ gettext glibc-static hostname \
    java-devel kernel-rpm-macros libbabeltrace-devel libbpf-devel ccache \
    libcap-devel libcap-ng-devel libmnl-devel libnl3-devel libtraceevent-devel \
    libtracefs-devel lld llvm-devel lvm2 m4 make net-tools newt-devel \
    numactl-devel openssl openssl-devel pciutils-devel perl perl-devel \
    perl-generators python3-devel python3-docutils rsync rust rust-src \
    systemd-boot-unsigned systemd-ukify which xmlto xz-devel zlib-devel \
    python3-requests hmaccalc dracut tpm2-tools rustfmt clippy bpftool \
    python3-jsonschema libxml2-devel swig opencsd-devel automake \
    libtool libtirpc libtirpc-devel && dnf clean all

WORKDIR /workspace

COPY . /workspace

ARG FEDORA_VERSION
ARG TARFILE_RELEASE
ARG NVIDIA_RELEASE
ARG NVIDIA_RELEASE_REL
ARG NVIDIA_RELEASE_LTS
ARG ZFS_RELEASE
ARG ARCH

RUN --mount=type=secret,id=PE_SIGNING_TOKEN \
    --mount=type=secret,id=PE_SIGNING_CERT \
    --mount=type=secret,id=PE_SIGNING_PIN_VALUE \
    /workspace/build.sh

RUN find /artifacts/RPMS -type f \( -name '*debuginfo*.rpm' -o -name '*debugsource*.rpm' \) -delete

FROM scratch

ARG ARCH

COPY --from=build /artifacts/RPMS/$ARCH /rpms
COPY --from=build /artifacts/SRPMS /srpms

ENTRYPOINT [ "env" ]
