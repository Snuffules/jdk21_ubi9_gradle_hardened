# Hardened Gradle Image for TeamCity

This Dockerfile installs a fixed, verified Gradle distribution into a hardened UBI9 OpenJDK 21 image. It removes the need for a Gradle Wrapper in TeamCity build steps where the build script is entered directly in the TeamCity UI.

## Why this Dockerfile is useful

The image solves the previous `Option 1` versus `Option 2` problem by using a multi-stage build:

1. The first stage downloads and verifies Gradle.
2. The second stage copies only the verified Gradle installation into the runtime image.
3. TeamCity can run `gradle` directly without downloading Gradle during the build.

## Stage 1: Gradle distribution stage

```Dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist
```

This stage exists only to prepare Gradle.

It performs three important jobs:

- Downloads the exact Gradle distribution.
- Verifies the download using `GRADLE_SHA256`.
- Removes unnecessary files such as Windows scripts, samples, documentation, and source archives.

The SHA-256 check is the security control that prevents a tampered Gradle ZIP from being accepted. If the downloaded file does not match the expected hash, the Docker build fails.

## Stage 2: Hardened runtime stage

```Dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-21:1.24

COPY --from=gradle-dist --chown=185:0 /opt/gradle /opt/gradle
```

The runtime image starts clean and receives only the verified Gradle installation from the first stage.

This means the final image does not retain the temporary download tooling from the first stage, such as `curl`, `unzip`, or package-manager metadata.

The runtime stage also hardens the Gradle installation by making it read-only. This prevents build code, plugins, or malicious dependencies from modifying the installed Gradle binaries during a TeamCity run.

Gradle is then made globally available through `PATH`:

```Dockerfile
ENV PATH="/opt/gradle/bin:${PATH}"
```

## Why the Gradle Wrapper is not needed here

A Gradle Wrapper normally requires these files:

```text
gradlew
gradlew.bat
gradle/wrapper/gradle-wrapper.jar
gradle/wrapper/gradle-wrapper.properties
```

That is not practical when the project is being created directly inside a TeamCity command-line text box.

The script can easily write plain text files with `cat << 'EOF'`, but it cannot cleanly write the binary `gradle-wrapper.jar`.

This image avoids that problem completely because Gradle `8.14.5` is already installed inside the container. The TeamCity build step can call `gradle` directly.

## TeamCity build-step setup

Create a TeamCity build step with these settings:

| Setting | Value |
|---|---|
| Runner type | Command Line |
| Run | Custom script |
| Docker setting | Run step within Docker container |
| Docker image | Your hardened Gradle image in Quay |

Example image path:

```text
quay.io/<organization>/<image-name>:<tag>
```

## Corrected TeamCity custom script

Use this script in the TeamCity command-line text area:

```bash
set -euo pipefail

# Use TeamCity's checkout directory when available.
# Fall back to /workspace for manually-created builds.
WORKDIR="${TEAMCITY_BUILD_CHECKOUTDIR:-/workspace}"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Keep Gradle's writable user home outside the read-only Gradle installation.
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/tmp/gradle-user-home}"
mkdir -p "${GRADLE_USER_HOME}"

# Create the Java source directory.
mkdir -p src/main/java/com/example

# Write the Java application source.
cat > src/main/java/com/example/MyApp.java << 'EOF'
package com.example;

public class MyApp {
    public static void main(String[] args) {
        System.out.println("Success! Compiled with a pre-installed, hardened Gradle binary.");
    }
}
EOF

# Write the Gradle settings file.
cat > settings.gradle << 'EOF'
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = 'teamcity-inline-gradle-build'
EOF

# Write the Gradle build file.
cat > build.gradle << 'EOF'
plugins {
    id 'java'
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}
EOF

# Verify that TeamCity is using the Gradle installed in the image.
gradle --version

# Run the build using the pre-installed Gradle binary.
gradle --no-daemon clean build
```

## Why this TeamCity script is safe

The script does not use `gradlew`.

It does not download a Gradle distribution.

It uses the Gradle binary already installed in the container image:

```bash
gradle --no-daemon clean build
```

The build writes generated files into the TeamCity workspace and keeps Gradle user files under:

```text
/tmp/gradle-user-home
```

That keeps runtime writes separate from the locked-down Gradle installation under:

```text
/opt/gradle
```

## Expected successful output

A successful build should end with output similar to:

```text
BUILD SUCCESSFUL
```

The compiled classes will be created under:

```text
build/classes/java/main
```

## Key result

This approach gives TeamCity a clean, reproducible Java build without a Gradle Wrapper and without downloading Gradle during the build step.
