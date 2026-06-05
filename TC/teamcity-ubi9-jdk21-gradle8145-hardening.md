# Hardened TeamCity Gradle 8.14.5 Build Container on UBI9 and JDK 21

## Purpose

This document defines a hardened TeamCity build-step container for running Gradle `8.14.5` with JDK 21 on Red Hat UBI9.

The target use case is a **TeamCity Gradle build step**, not a production runtime image.

The recommended design is:

```text
TeamCity Gradle runner
+ Gradle Wrapper pinned to Gradle 8.14.5
+ UBI9 OpenJDK 21 builder image
+ non-root execution
+ pinned checksums
+ restricted Docker/Podman runtime flags
+ controlled dependency access
```

## Decision Summary

Use a hardened CI/build image only.

Do not deploy this image to production.

Do not include Gradle in runtime application images.

| Requirement | Decision |
|---|---|
| Operating system base | Red Hat UBI9 |
| Java version | JDK 21 |
| Build tool | Gradle 8.14.5 |
| Preferred Gradle source | Project Gradle Wrapper |
| Fallback Gradle source | Installed `/opt/gradle` inside image |
| Runtime user | Non-root user `185` |
| Writable paths | `/tmp`, Gradle user home, TeamCity checkout/build dirs |
| Privileges | Drop Linux capabilities, no privilege escalation |
| Network posture | Prefer internal artifact proxy; offline builds after cache/mirror warmup |
| Production image | Separate runtime image without Gradle |

## Why the Runtime Image Is Not Needed

For TeamCity builds, use the Red Hat UBI9 OpenJDK 21 builder image.

Red Hat marks `registry.access.redhat.com/ubi9/openjdk-21` as the OpenJDK 21 builder image. It is intended for building and running Java 21 applications.

Do not use `registry.access.redhat.com/ubi9/openjdk-21-runtime` for this TeamCity build image. Red Hat describes it as a lean runtime-only image that does not contain the Java compiler, JDK tools, or Maven. It is appropriate only after the build is complete.

## Preferred Pattern: Use Gradle Wrapper

This is the recommended configuration.

The container only supplies:

```text
UBI9
JDK 21
CA certificates
non-root execution
writable temporary directories
```

Gradle itself is supplied by the repository through `gradlew`.

### `gradle/wrapper/gradle-wrapper.properties`

Set the Gradle Wrapper to Gradle `8.14.5` and pin the distribution checksum.

```properties
 distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.5-bin.zip
 distributionSha256Sum=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
```

The SHA-256 value above is the official checksum for `gradle-8.14.5-bin.zip` from Gradle's checksum reference.

### Minimal Hardened Dockerfile for Wrapper Mode

Use this image when TeamCity is configured with **Use Gradle Wrapper** enabled.

```dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-21:1.24

USER 0

ENV GRADLE_USER_HOME=/tmp/gradle-user-home \
    JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

RUN mkdir -p /workspace /tmp/gradle-user-home \
 && chgrp -R 0 /workspace /tmp/gradle-user-home \
 && chmod -R g=u /workspace /tmp/gradle-user-home \
 && rm -rf /tmp/* /var/tmp/*

WORKDIR /workspace

USER 185

CMD ["java", "-version"]
```

### Build the Wrapper-Mode Image

```bash
podman build \
  --pull=always \
  -t registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0 \
  -f Dockerfile .
```

Equivalent Docker command:

```bash
docker build \
  --pull \
  -t registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0 \
  -f Dockerfile .
```

## Fallback Pattern: Install Gradle 8.14.5 in the Image

Use this only when TeamCity cannot use `gradlew` or when policy requires a centrally managed Gradle binary.

This image installs Gradle into `/opt/gradle`, verifies the official SHA-256 checksum, and does not copy `curl`, `unzip`, or package-manager artifacts into the final image.

### Hardened Dockerfile with Installed Gradle

```dockerfile
# syntax=docker/dockerfile:1.7

ARG GRADLE_VERSION=8.14.5
ARG GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist

ARG GRADLE_VERSION
ARG GRADLE_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER 0

RUN microdnf -y update \
 && microdnf -y install ca-certificates curl unzip coreutils findutils \
 && microdnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/*

RUN curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
      --output /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && echo "${GRADLE_SHA256}  /tmp/gradle.zip" | sha256sum -c - \
 && unzip -q /tmp/gradle.zip -d /opt \
 && mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
 && rm -f /tmp/gradle.zip \
 && find /opt/gradle -type f \( -name "*.bat" -o -name "*.cmd" \) -delete \
 && rm -rf /opt/gradle/docs /opt/gradle/samples /opt/gradle/src

FROM registry.access.redhat.com/ubi9/openjdk-21:1.24

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

CMD ["gradle", "--version"]
```

### Build the Installed-Gradle Image

```bash
podman build \
  --pull=always \
  --build-arg GRADLE_VERSION=8.14.5 \
  --build-arg GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854 \
  -t registry.example.com/ci/ubi9-jdk21-gradle8-teamcity:8.14.5 \
  -f Dockerfile .
```

Equivalent Docker command:

```bash
docker build \
  --pull \
  --build-arg GRADLE_VERSION=8.14.5 \
  --build-arg GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854 \
  -t registry.example.com/ci/ubi9-jdk21-gradle8-teamcity:8.14.5 \
  -f Dockerfile .
```

## TeamCity Configuration

### Preferred TeamCity Gradle Step

Use this when the repository contains `gradlew`.

```text
Runner type: Gradle
Use Gradle wrapper: enabled
Tasks: clean build
Docker image: registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0
```

### Fallback TeamCity Gradle Step

Use this only when Gradle is installed in the image.

```text
Runner type: Gradle
Use Gradle wrapper: disabled
Gradle home: /opt/gradle
Tasks: clean build
Docker image: registry.example.com/ci/ubi9-jdk21-gradle8-teamcity:8.14.5
```

## Hardened Docker/Podman Runtime Arguments

Use these as TeamCity additional Docker/Podman run arguments where supported.

```bash
--user 185:0 \
--cap-drop=ALL \
--security-opt=no-new-privileges \
--pids-limit=512 \
--memory=4g \
--cpus=2 \
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Use `--read-only` only after validating that TeamCity mounts all required working directories as writable.

Gradle and TeamCity need writable locations for:

```text
checkout directory
build directory
Gradle user home
Gradle dependency cache
test reports
temporary files
```

A safer first pass is to keep the image filesystem immutable by design but avoid `--read-only` until the build has been tested.

## TeamCity Kotlin DSL Example: Wrapper Mode

```kotlin
gradle {
    name = "Gradle build"
    tasks = "clean build"

    useGradleWrapper = true

    dockerImage = "registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0"
    dockerImagePlatform = GradleBuildStep.ImagePlatform.Linux
    dockerRunParameters = """
        --user 185:0
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --pids-limit=512
        --memory=4g
        --cpus=2
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
    """.trimIndent()
}
```

## TeamCity Kotlin DSL Example: Installed Gradle Mode

```kotlin
gradle {
    name = "Gradle build"
    tasks = "clean build"

    useGradleWrapper = false
    gradleHome = "/opt/gradle"

    dockerImage = "registry.example.com/ci/ubi9-jdk21-gradle8-teamcity:8.14.5"
    dockerImagePlatform = GradleBuildStep.ImagePlatform.Linux
    dockerRunParameters = """
        --user 185:0
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --pids-limit=512
        --memory=4g
        --cpus=2
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
    """.trimIndent()
}
```

## Dependency and Network Controls

Do not allow unrestricted dependency downloads from the public internet in hardened CI.

Recommended posture:

```text
Use an internal Maven/Gradle artifact proxy.
Allow outbound network only to the internal proxy.
Pin plugin repositories.
Use Gradle dependency locking.
Use checksum verification.
Run offline where possible after dependency resolution is controlled.
```

Example Gradle command after dependencies are available through a controlled proxy:

```bash
./gradlew --offline clean build
```

## Gradle User Home

Set Gradle user home explicitly.

```bash
GRADLE_USER_HOME=/tmp/gradle-user-home
```

For TeamCity, prefer a controlled cache mount if builds need dependency reuse.

Example Docker/Podman volume:

```bash
-v teamcity-gradle-cache:/tmp/gradle-user-home:Z
```

Do not mount host-wide user directories into the build container.

## Recommended Repository Files

For wrapper mode:

```text
Dockerfile
.dockerignore
README.md
gradle/wrapper/gradle-wrapper.properties
gradle/wrapper/gradle-wrapper.jar
gradlew
gradlew.bat
```

For installed-Gradle mode:

```text
Dockerfile
.dockerignore
README.md
checksums/gradle-8.14.5-bin.zip.sha256
```

## `.dockerignore`

Use a restrictive `.dockerignore`.

```dockerignore
.git
.github
.gradle
build
out
.idea
*.iml
*.log
*.tmp
.DS_Store
node_modules
```

## Verification Commands

### Check Java

```bash
podman run --rm registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0 java -version
```

### Check Gradle Wrapper

```bash
podman run --rm \
  -v "$PWD":/workspace:Z \
  -w /workspace \
  registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0 \
  ./gradlew --version
```

### Check Installed Gradle

```bash
podman run --rm registry.example.com/ci/ubi9-jdk21-gradle8-teamcity:8.14.5 gradle --version
```

### Check Effective User

```bash
podman run --rm registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0 id
```

Expected result should show user `185`.

## Security Controls Checklist

| Control | Required |
|---|---|
| Pin base image tag | Yes |
| Pull latest patched base during rebuild | Yes |
| Run as non-root | Yes |
| Drop all capabilities | Yes |
| Disable privilege escalation | Yes |
| Verify Gradle checksum | Yes |
| Prefer Gradle Wrapper checksum | Yes |
| Use internal artifact proxy | Yes |
| Avoid public internet during CI build | Yes |
| Avoid privileged Docker mode | Yes |
| Avoid mounting host home directories | Yes |
| Separate build and runtime images | Yes |
| Scan image before publishing | Yes |
| Rebuild regularly for UBI patches | Yes |

## Image Scanning

Run at least one scanner before publishing.

Example with Trivy:

```bash
trivy image --severity HIGH,CRITICAL registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0
```

Example with Grype:

```bash
grype registry.example.com/ci/ubi9-jdk21-teamcity:1.0.0
```

A hardened container is still dependent on timely rebuilds and patched base images.

## Maintenance Policy

Rebuild the image when any of the following changes:

```text
Red Hat UBI9/OpenJDK image update
Gradle security release
JDK security update
TeamCity agent/container-wrapper behavior change
internal dependency proxy certificate change
scanner reports new high or critical findings
```

Minimum rebuild cadence:

```text
monthly
or immediately after high/critical CVE disclosure
```

## Final Recommended Implementation

Use wrapper mode unless there is a strict policy reason not to.

Final target state:

```text
TeamCity Gradle runner
Use Gradle Wrapper = true
Gradle Wrapper pinned to 8.14.5
Gradle Wrapper SHA-256 enabled
Container image = UBI9 OpenJDK 21 only
Run as non-root user 185
Drop all Linux capabilities
Disable privilege escalation
Restrict network to internal artifact proxy
Separate CI image from runtime image
```

## References

- Red Hat UBI9 OpenJDK 21 builder image: https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21/6501cdb5c34ae048c44f7814
- Red Hat UBI9 OpenJDK 21 runtime image: https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21-runtime/6501ce769a0d86945c422d5f
- Gradle checksum reference: https://gradle.org/release-checksums/
- TeamCity Gradle build runner: https://www.jetbrains.com/help/teamcity/gradle.html
- TeamCity Run in Docker: https://www.jetbrains.com/help/teamcity/run-in-docker.html
- TeamCity Container Wrapper: https://www.jetbrains.com/help/teamcity/container-wrapper.html
- TeamCity Gradle Kotlin DSL: https://teamcity.jetbrains.com/app/dsl-documentation/buildSteps/gradle-build-step/index.html
