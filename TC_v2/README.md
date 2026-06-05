# TeamCity Hardened Build Container: UBI9 + JDK 21 + Gradle 8.14.5

## Purpose

This document defines a hardened, non-privileged TeamCity build-step container for Java builds requiring:

- Red Hat UBI9
- JDK 21
- Gradle 8.14.5
- Minimal build-image posture
- No privileged container mode
- No Docker socket mount
- No production/runtime image contents unless explicitly required

This is a **TeamCity CI build image** process, not a production runtime image process.

---

## Correct Interpretation

There are two valid TeamCity approaches:

| Approach | Gradle installed in image | Recommended | Security posture |
|---|---:|---:|---|
| Gradle Wrapper | No | Yes | Strongest |
| Installed Gradle 8.14.5 | Yes | Only if wrapper is not allowed | Acceptable if pinned and checksum-verified |

The Gradle Wrapper approach is better because the image only needs JDK 21. Gradle version control stays in the repository through `gradle-wrapper.properties`.

The installed-Gradle approach is only needed when TeamCity must call `/opt/gradle/bin/gradle` directly or organizational policy forbids wrapper execution.

---

## Non-Privileged Requirement

The TeamCity container must **not** run privileged.

Do not use:

```bash
--privileged
```

Do not mount the host Docker socket:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

Do not mount host home directories:

```bash
-v /home:/home
-v ~/.gradle:/home/user/.gradle
```

Do not run as root:

```bash
--user 0
```

Required hardened runtime flags:

```bash
--user 185:0 \
--cap-drop=ALL \
--security-opt=no-new-privileges \
--pids-limit=512 \
--memory=4g \
--cpus=2 \
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Use `--read-only` only when TeamCity checkout, temp, Gradle cache, and report directories are mounted as writable volumes.

---

## Preferred Option: Wrapper-Only TeamCity Image

Use this when the repository contains:

```text
gradlew
gradlew.bat
gradle/wrapper/gradle-wrapper.jar
gradle/wrapper/gradle-wrapper.properties
```

### `gradle/wrapper/gradle-wrapper.properties`

```properties
distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.5-bin.zip
distributionSha256Sum=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
```

### `Dockerfile.teamcity-wrapper`

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

### Build

```bash
podman build \
  --pull=always \
  -f Dockerfile.teamcity-wrapper \
  -t ubi9-jdk21-teamcity-wrapper:latest .
```

### Hardened local test

```bash
podman run --rm \
  --user 185:0 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=512 \
  --memory=4g \
  --cpus=2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
  -v "$PWD":/workspace:Z \
  ubi9-jdk21-teamcity-wrapper:latest \
  ./gradlew --version
```

---

## Fallback Option: Installed Gradle 8.14.5 Image

Use this only when TeamCity is configured to use installed Gradle instead of the wrapper.

### `Dockerfile.teamcity-gradle`

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

### Build

```bash
podman build \
  --pull=always \
  -f Dockerfile.teamcity-gradle \
  -t ubi9-jdk21-gradle8145-teamcity:latest .
```

### Hardened local test

```bash
podman run --rm \
  --user 185:0 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=512 \
  --memory=4g \
  --cpus=2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
  -v "$PWD":/workspace:Z \
  ubi9-jdk21-gradle8145-teamcity:latest \
  gradle --version
```

---

## TeamCity Configuration: Wrapper Mode

Use this configuration when using the preferred wrapper-only image.

```text
Runner type: Gradle
Use Gradle wrapper: enabled
Tasks: clean build
Docker image: your-registry/ubi9-jdk21-teamcity-wrapper:latest
```

Additional Docker run parameters:

```bash
--user 185:0
--cap-drop=ALL
--security-opt=no-new-privileges
--pids-limit=512
--memory=4g
--cpus=2
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Do not add `--privileged`.

Do not mount `/var/run/docker.sock`.

---

## TeamCity Configuration: Installed Gradle Mode

Use this only for the fallback installed-Gradle image.

```text
Runner type: Gradle
Use Gradle wrapper: disabled
Gradle home: /opt/gradle
Tasks: clean build
Docker image: your-registry/ubi9-jdk21-gradle8145-teamcity:latest
```

Additional Docker run parameters:

```bash
--user 185:0
--cap-drop=ALL
--security-opt=no-new-privileges
--pids-limit=512
--memory=4g
--cpus=2
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Do not add `--privileged`.

Do not mount `/var/run/docker.sock`.

---

## TeamCity Kotlin DSL: Wrapper Mode

```kotlin
gradle {
    name = "Gradle build"
    tasks = "clean build"

    useGradleWrapper = true

    dockerImage = "your-registry/ubi9-jdk21-teamcity-wrapper:latest"
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

---

## TeamCity Kotlin DSL: Installed Gradle Mode

```kotlin
gradle {
    name = "Gradle build"
    tasks = "clean build"

    useGradleWrapper = false
    gradleHome = "/opt/gradle"

    dockerImage = "your-registry/ubi9-jdk21-gradle8145-teamcity:latest"
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

---

## Corrected Security Controls Checklist

| Control | Wrapper-only image | Installed-Gradle image |
|---|---:|---:|
| Use UBI9 OpenJDK 21 builder image | Yes | Yes |
| Install Gradle into image | No | Yes |
| Pin Gradle 8.14.5 | In wrapper properties | In Dockerfile |
| Verify Gradle SHA-256 | `distributionSha256Sum` | `sha256sum -c` |
| Run container as non-root | Yes | Yes |
| Run container with `--privileged` | No | No |
| Mount host Docker socket | No | No |
| Add Linux capabilities | No | No |
| Drop all capabilities | Yes | Yes |
| Disable privilege escalation | Yes | Yes |
| Mount host home directories | No | No |
| Use internal artifact proxy | Yes | Yes |
| Avoid public internet during CI build | Yes | Yes |
| Scan image before publishing | Yes | Yes |
| Pull patched UBI base during rebuild | Yes | Yes |
| Separate CI build image from runtime image | Yes | Yes, if an app runtime image is also built |

---

## Read-Only Filesystem Guidance

Do not start with `--read-only` in TeamCity unless all writable paths are explicitly handled.

Gradle and TeamCity may need writable locations for:

- checkout directory
- build output
- test reports
- Gradle user home
- temporary directory
- TeamCity agent temp files

Safer baseline:

```bash
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Stricter mode after validation:

```bash
--read-only \
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g
```

Only enable `--read-only` after confirming the checkout and cache directories are mounted writable by TeamCity.

---

## Dependency and Network Controls

Preferred CI dependency flow:

1. Resolve dependencies through an internal artifact proxy.
2. Pin plugin repositories.
3. Pin Gradle version.
4. Verify Gradle distribution checksum.
5. Avoid public internet during regular CI builds.
6. Use `--offline` where feasible after dependency cache/proxy validation.

Example Gradle invocation:

```bash
./gradlew --offline clean build
```

Installed Gradle equivalent:

```bash
gradle --offline clean build
```

---

## Final Decision

Use the wrapper-only image unless there is a hard requirement to install Gradle in the TeamCity image.

The strictest TeamCity posture is:

```text
UBI9 OpenJDK 21 image
+ Gradle Wrapper pinned to 8.14.5
+ distributionSha256Sum set
+ non-root UID 185
+ no privileged mode
+ no Docker socket
+ dropped capabilities
+ no privilege escalation
+ internal artifact proxy
```
