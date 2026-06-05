# syntax=docker/dockerfile:1.7

ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:9.6
ARG UBI_OPENJDK_IMAGE=registry.access.redhat.com/ubi9/openjdk-21:1.24
ARG GRADLE_VERSION=8.14.5
ARG GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854

FROM ${UBI_MINIMAL_IMAGE} AS gradle-dist

ARG GRADLE_VERSION
ARG GRADLE_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER 0

RUN microdnf -y update \
 && microdnf -y --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install ca-certificates curl unzip coreutils findutils \
 && microdnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/*

RUN test -n "${GRADLE_VERSION}" \
 && test -n "${GRADLE_SHA256}" \
 && curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
      --output /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && echo "${GRADLE_SHA256}  /tmp/gradle.zip" | sha256sum -c - \
 && unzip -q /tmp/gradle.zip -d /opt \
 && mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
 && rm -f /tmp/gradle.zip \
 && find /opt/gradle -type f \( -name "*.bat" -o -name "*.cmd" \) -delete \
 && rm -rf /opt/gradle/docs /opt/gradle/samples /opt/gradle/src

FROM ${UBI_OPENJDK_IMAGE}

ARG GRADLE_VERSION
ARG GRADLE_SHA256

LABEL org.opencontainers.image.title="UBI9 JDK 21 Gradle 8 hardened build image" \
      org.opencontainers.image.description="Red Hat UBI9 OpenJDK 21 builder image with pinned Gradle 8 distribution" \
      org.opencontainers.image.version="${GRADLE_VERSION}" \
      org.opencontainers.image.vendor="local" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/openjdk-21:1.24" \
      org.opencontainers.image.licenses="Apache-2.0"

USER 0

ENV GRADLE_HOME=/opt/gradle \
    GRADLE_USER_HOME=/tmp/gradle-user-home \
    PATH=/opt/gradle/bin:$PATH \
    JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

COPY --from=gradle-dist --chown=185:0 /opt/gradle /opt/gradle

RUN mkdir -p /workspace /tmp/gradle-user-home \
 && chgrp -R 0 /workspace /tmp/gradle-user-home /opt/gradle \
 && chmod -R g=u /workspace /tmp/gradle-user-home /opt/gradle \
 && find /opt/gradle -type d -exec chmod 0555 {} + \
 && find /opt/gradle -type f -exec chmod 0444 {} + \
 && chmod 0555 /opt/gradle/bin/gradle \
 && rm -rf /tmp/* /var/tmp/*

WORKDIR /workspace

USER 185

ENTRYPOINT ["gradle"]
CMD ["--version"]
