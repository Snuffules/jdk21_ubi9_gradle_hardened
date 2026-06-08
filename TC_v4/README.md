# TeamCity: Build and Use a Hardened SHA-Verified Gradle Image

This document explains how to use TeamCity to:

1. Build a custom UBI9 OpenJDK 21 image.
2. Download Gradle 8.14.5 during the image build.
3. Verify the Gradle ZIP with SHA-256.
4. Harden the Gradle installation.
5. Push the final image to Quay.
6. Use that final image in a separate TeamCity build step with `Run step within Docker container`.

The important rule:

```text
FROM belongs only inside a Dockerfile.
TeamCity Run step within Docker container uses a finished image name.
```

Do not put this in TeamCity's Docker image field:

```Dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist
```

Do not put this there either:

```Dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-21:1.24
```

TeamCity's Docker image field must contain a final built image name, for example:

```text
quay.io/my-org/ubi9-openjdk21-gradle:8.14.5
```

---

# 1. Final architecture

There are two TeamCity build steps.

```text
Step 1: Build hardened Gradle image
  - Runs directly on the TeamCity agent
  - Creates a Dockerfile
  - Downloads Gradle
  - Verifies Gradle SHA-256
  - Builds the custom image
  - Pushes image to Quay

Step 2: Build Java application
  - Runs inside the custom image from Step 1
  - Uses TeamCity "Run step within Docker container"
  - Calls gradle directly
  - Does not download Gradle
  - Does not use Gradle Wrapper
```

---

# 2. Why the Red Hat OpenJDK image alone is not enough

This image:

```text
registry.access.redhat.com/ubi9/openjdk-21:1.24
```

contains Java.

It does not contain Gradle.

If TeamCity uses only that image and the script runs:

```bash
gradle --version
```

the expected failure is:

```text
gradle: command not found
```

The Red Hat OpenJDK image is only a base image in the Dockerfile.

Correct relationship:

```text
Base image used inside Dockerfile:
registry.access.redhat.com/ubi9/openjdk-21:1.24

Final custom image built by TeamCity:
quay.io/my-org/ubi9-openjdk21-gradle:8.14.5

Image used in TeamCity "Run step within Docker container":
quay.io/my-org/ubi9-openjdk21-gradle:8.14.5
```

---

# 3. TeamCity Step 1: Build and push the hardened Gradle image

## TeamCity UI configuration

Create a new build step:

```text
Build Configuration
→ Build Steps
→ Add build step
→ Runner type: Command Line
```

Use these settings:

```text
Step name: Build hardened Gradle image
Runner type: Command Line
Run: Custom script
Run step within Docker container: OFF
```

This step should not use `Run step within Docker container`.

Reason:

```text
This step must build a container image.
It needs access to the TeamCity agent's docker or podman engine.
```

The TeamCity agent must have one of these installed:

```text
podman
docker
```

The agent must also be able to push to Quay.

---

# 4. Full TeamCity Step 1 script

Replace this value:

```bash
IMAGE="quay.io/<org>/ubi9-openjdk21-gradle:8.14.5"
```

with your real Quay path.

Example:

```bash
IMAGE="quay.io/my-org/ubi9-openjdk21-gradle:8.14.5"
```

Paste this script into the TeamCity Step 1 custom script box:

```bash
set -euo pipefail

IMAGE="quay.io/<org>/ubi9-openjdk21-gradle:8.14.5"

cat > Dockerfile << 'EOF'
ARG GRADLE_VERSION=8.14.5
ARG GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist

ARG GRADLE_VERSION
ARG GRADLE_SHA256

USER 0

RUN microdnf -y install curl unzip ca-certificates findutils \
 && microdnf clean all \
 && curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
      --output /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && echo "${GRADLE_SHA256}  /tmp/gradle.zip" | sha256sum -c - \
 && unzip -q /tmp/gradle.zip -d /opt \
 && mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
 && rm -f /tmp/gradle.zip \
 && find /opt/gradle -type f \( -name "*.bat" -o -name "*.cmd" \) -delete \
 && rm -rf /opt/gradle/docs \
           /opt/gradle/samples \
           /opt/gradle/src \
           /opt/gradle/init.d \
 && find /opt/gradle -type d -exec chmod 0555 {} \; \
 && find /opt/gradle -type f -exec chmod 0444 {} \; \
 && find /opt/gradle/bin -type f -exec chmod 0555 {} \;

FROM registry.access.redhat.com/ubi9/openjdk-21:1.24

USER 0

COPY --from=gradle-dist --chown=185:0 /opt/gradle /opt/gradle

ENV GRADLE_HOME=/opt/gradle
ENV GRADLE_USER_HOME=/tmp/gradle-user-home
ENV PATH="/opt/gradle/bin:${PATH}"

RUN mkdir -p /workspace /tmp/gradle-user-home \
 && chown -R 185:0 /workspace /tmp/gradle-user-home \
 && chmod -R g=u /workspace /tmp/gradle-user-home

WORKDIR /workspace

USER 185
EOF

if command -v podman >/dev/null 2>&1; then
  CONTAINER_ENGINE=podman
else
  CONTAINER_ENGINE=docker
fi

# Enable this only if the TeamCity agent is not already authenticated to Quay.
# echo "%quay.password%" | "$CONTAINER_ENGINE" login quay.io -u "%quay.username%" --password-stdin

"$CONTAINER_ENGINE" build --pull -t "$IMAGE" .

"$CONTAINER_ENGINE" run --rm "$IMAGE" java -version
"$CONTAINER_ENGINE" run --rm "$IMAGE" gradle --version

"$CONTAINER_ENGINE" push "$IMAGE"
```

---

# 5. Step 1 script explained

## Shell safety

```bash
set -euo pipefail
```

Meaning:

```text
-e        Stop when a command fails.
-u        Fail on undefined variables.
pipefail  Fail when any command in a pipeline fails.
```

This prevents TeamCity from continuing after a broken Dockerfile, failed Gradle download, failed SHA check, failed image build, or failed image push.

---

## Final image name

```bash
IMAGE="quay.io/<org>/ubi9-openjdk21-gradle:8.14.5"
```

This is the final custom image that TeamCity builds and pushes.

This same image is used later in Step 2.

Example:

```bash
IMAGE="quay.io/my-org/ubi9-openjdk21-gradle:8.14.5"
```

---

## Create a Dockerfile from the TeamCity text box

```bash
cat > Dockerfile << 'EOF'
...
EOF
```

This writes a Dockerfile in the current TeamCity working directory.

The quoted heredoc marker is important:

```bash
<< 'EOF'
```

It prevents the shell from expanding Dockerfile variables too early.

These values stay inside the Dockerfile:

```Dockerfile
${GRADLE_VERSION}
${PATH}
```

Without the quotes, the shell running the TeamCity script could expand them before Docker sees them.

---

# 6. Dockerfile explained

## Gradle version and checksum

```Dockerfile
ARG GRADLE_VERSION=8.14.5
ARG GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
```

These define:

```text
Gradle version: 8.14.5
Expected SHA-256: 6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
```

The downloaded file is:

```text
gradle-8.14.5-bin.zip
```

The SHA-256 check ensures the downloaded file is exactly the expected Gradle distribution.

If the checksum is wrong, the image build fails.

---

## First Dockerfile stage: Gradle download and hardening

```Dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist
```

This starts the first stage.

The first stage is named:

```text
gradle-dist
```

This stage is temporary.

It exists only to:

```text
install download tools
download Gradle
verify SHA-256
unzip Gradle
remove unnecessary files
lock permissions
```

This is not the final runtime image.

---

## Re-declare build arguments inside the first stage

```Dockerfile
ARG GRADLE_VERSION
ARG GRADLE_SHA256
```

Docker build arguments declared before the first `FROM` must be declared again inside the stage where they are used.

These two lines make the values available to the `RUN` command.

---

## Use root during image construction

```Dockerfile
USER 0
```

This allows the Docker build to install packages and write to `/opt`.

The final image does not run as root.

The final image switches back to:

```Dockerfile
USER 185
```

---

## Install temporary tools

```Dockerfile
RUN microdnf -y install curl unzip ca-certificates findutils \
```

This installs only what the first stage needs:

```text
curl             downloads Gradle
unzip            extracts the Gradle ZIP
ca-certificates  verifies HTTPS certificates
findutils        provides the find command
```

These tools stay in the first stage.

They are not copied into the final runtime image.

---

## Clean package metadata

```Dockerfile
 && microdnf clean all \
```

This removes package-manager cache from the first stage.

The final image still only receives `/opt/gradle`.

---

## Download Gradle securely

```Dockerfile
 && curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
      --output /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
```

This downloads:

```text
https://services.gradle.org/distributions/gradle-8.14.5-bin.zip
```

Option meaning:

```text
--proto '=https'     Allow only HTTPS.
--tlsv1.2            Require TLS 1.2 behavior.
--fail               Fail on HTTP errors.
--location           Follow redirects.
--show-error         Show errors even in silent mode.
--silent             Suppress progress output.
--output             Save the ZIP to /tmp/gradle.zip.
```

---

## Verify the SHA-256 checksum

```Dockerfile
 && echo "${GRADLE_SHA256}  /tmp/gradle.zip" | sha256sum -c - \
```

This checks the downloaded ZIP against the pinned checksum.

The input format is:

```text
<sha256>  <file>
```

Example:

```text
6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854  /tmp/gradle.zip
```

If the file matches, the build continues.

If the file does not match, the build stops.

This protects against:

```text
corrupted downloads
wrong Gradle ZIP
tampered content
unexpected upstream changes
man-in-the-middle replacement
```

---

## Unzip Gradle

```Dockerfile
 && unzip -q /tmp/gradle.zip -d /opt \
```

This extracts the Gradle ZIP into `/opt`.

After extraction, the directory is:

```text
/opt/gradle-8.14.5
```

---

## Normalize the Gradle path

```Dockerfile
 && mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
```

This renames:

```text
/opt/gradle-8.14.5
```

to:

```text
/opt/gradle
```

The final image can then use a stable path:

```text
/opt/gradle/bin/gradle
```

---

## Remove the downloaded ZIP

```Dockerfile
 && rm -f /tmp/gradle.zip \
```

The ZIP is no longer needed after extraction.

---

## Remove Windows scripts

```Dockerfile
 && find /opt/gradle -type f \( -name "*.bat" -o -name "*.cmd" \) -delete \
```

Linux containers do not need Windows launchers.

This removes:

```text
*.bat
*.cmd
```

---

## Remove non-runtime files

```Dockerfile
 && rm -rf /opt/gradle/docs \
           /opt/gradle/samples \
           /opt/gradle/src \
           /opt/gradle/init.d \
```

This removes files that are not needed for this TeamCity runtime image:

```text
docs     documentation
samples  sample projects
src      source archives or source directories if present
init.d   optional global Gradle initialization scripts
```

Removing `init.d` is a hardening choice.

It prevents shipping global Gradle initialization hooks unless intentionally required.

---

## Lock Gradle directories

```Dockerfile
 && find /opt/gradle -type d -exec chmod 0555 {} \; \
```

Permission `0555` means:

```text
read + execute
not writable
```

Directories need execute permission so users can traverse them.

---

## Lock Gradle files

```Dockerfile
 && find /opt/gradle -type f -exec chmod 0444 {} \; \
```

Permission `0444` means:

```text
read-only
not writable
not executable
```

This prevents Gradle installation files from being modified during builds.

---

## Make Gradle launchers executable

```Dockerfile
 && find /opt/gradle/bin -type f -exec chmod 0555 {} \;
```

The previous command made all files read-only.

This command restores execute permission only for Gradle launchers under:

```text
/opt/gradle/bin
```

This is required so this command can work:

```bash
gradle --version
```

---

# 7. Final Dockerfile stage explained

## Start from Red Hat OpenJDK 21

```Dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-21:1.24
```

This starts the final runtime image.

This image provides Java 21.

This image does not provide Gradle by itself.

Gradle is added by the next copy command.

---

## Use root temporarily

```Dockerfile
USER 0
```

This is only during image construction.

It allows the Dockerfile to copy Gradle, create directories, and set ownership.

---

## Copy verified Gradle from the first stage

```Dockerfile
COPY --from=gradle-dist --chown=185:0 /opt/gradle /opt/gradle
```

This copies only the prepared Gradle installation from the first stage.

It does not copy:

```text
curl
unzip
microdnf cache
/tmp/gradle.zip
temporary build tools
```

Ownership is set to:

```text
user: 185
group: 0
```

---

## Set Gradle environment variables

```Dockerfile
ENV GRADLE_HOME=/opt/gradle
ENV GRADLE_USER_HOME=/tmp/gradle-user-home
ENV PATH="/opt/gradle/bin:${PATH}"
```

Meaning:

```text
GRADLE_HOME       Gradle installation directory.
GRADLE_USER_HOME  Writable Gradle cache/runtime directory.
PATH              Allows calling gradle directly.
```

Because `/opt/gradle` is read-only, Gradle must write runtime files somewhere else.

That writable place is:

```text
/tmp/gradle-user-home
```

---

## Create writable runtime directories

```Dockerfile
RUN mkdir -p /workspace /tmp/gradle-user-home \
 && chown -R 185:0 /workspace /tmp/gradle-user-home \
 && chmod -R g=u /workspace /tmp/gradle-user-home
```

This creates:

```text
/workspace
/tmp/gradle-user-home
```

Ownership:

```text
185:0
```

This matches the non-root user used by the final image.

The permission command:

```bash
chmod -R g=u
```

makes group permissions match user permissions.

This helps in container platforms where group permissions matter.

---

## Set default working directory

```Dockerfile
WORKDIR /workspace
```

This makes `/workspace` the default directory when the container starts.

TeamCity may still mount and use its own checkout directory, but `/workspace` remains a safe fallback.

---

## Run as non-root

```Dockerfile
USER 185
```

The final container runs as user `185`.

The Gradle installation is readable and executable but not writable.

The writable runtime paths are:

```text
/workspace
/tmp/gradle-user-home
```

---

# 8. Back to the Step 1 TeamCity shell script

## Choose Podman or Docker

```bash
if command -v podman >/dev/null 2>&1; then
  CONTAINER_ENGINE=podman
else
  CONTAINER_ENGINE=docker
fi
```

This detects which container engine is available on the TeamCity agent.

If `podman` exists, the script uses Podman.

Otherwise, it uses Docker.

The rest of the script calls:

```bash
"$CONTAINER_ENGINE"
```

---

## Optional Quay login

```bash
# echo "%quay.password%" | "$CONTAINER_ENGINE" login quay.io -u "%quay.username%" --password-stdin
```

This line is commented out.

Enable it only when the TeamCity agent is not already authenticated to Quay.

Use TeamCity secure parameters:

```text
%quay.username%
%quay.password%
```

Do not hardcode credentials.

---

## Build the image

```bash
"$CONTAINER_ENGINE" build --pull -t "$IMAGE" .
```

Meaning:

```text
build       Build the image.
--pull      Pull newer base image layers if available.
-t          Apply the final image tag.
.           Use the current directory as the build context.
```

The SHA-256 verification happens during this command.

---

## Test Java in the built image

```bash
"$CONTAINER_ENGINE" run --rm "$IMAGE" java -version
```

This verifies that Java works inside the final image.

---

## Test Gradle in the built image

```bash
"$CONTAINER_ENGINE" run --rm "$IMAGE" gradle --version
```

This verifies that Gradle works inside the final image.

Expected result includes:

```text
Gradle 8.14.5
```

---

## Push the image

```bash
"$CONTAINER_ENGINE" push "$IMAGE"
```

This pushes the final image to Quay.

After this succeeds, Step 2 can use the image.

---

# 9. TeamCity Step 2: Use the image as Run step within Docker container

## TeamCity UI configuration

Create another build step:

```text
Build Configuration
→ Build Steps
→ Add build step
→ Runner type: Command Line
```

Use these settings:

```text
Step name: Build Java app with hardened Gradle
Runner type: Command Line
Run: Custom script
Run step within Docker container: ON
Docker image: quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
```

Use the same image value that Step 1 pushed.

Example:

```text
Docker image: quay.io/my-org/ubi9-openjdk21-gradle:8.14.5
```

This Step 2 Docker image field must contain the final image name.

It must not contain `FROM`.

---

# 10. Full TeamCity Step 2 script

Paste this into the Step 2 custom script box:

```bash
set -euo pipefail

cd "%teamcity.build.checkoutDir%"

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/tmp/gradle-user-home}"
mkdir -p "$GRADLE_USER_HOME"

mkdir -p src/main/java/com/example

cat > src/main/java/com/example/MyApp.java << 'EOF'
package com.example;

public class MyApp {
    public static void main(String[] args) {
        System.out.println("Success! Compiled with a pre-installed, SHA-verified Gradle binary.");
    }
}
EOF

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

which gradle
gradle --version
gradle --no-daemon clean build
```

---

# 11. Step 2 script explained

## Shell safety

```bash
set -euo pipefail
```

Stops the build on failures, undefined variables, or broken pipelines.

---

## Move to TeamCity checkout directory

```bash
cd "%teamcity.build.checkoutDir%"
```

TeamCity replaces:

```text
%teamcity.build.checkoutDir%
```

with the actual build checkout directory.

This makes the Gradle project files appear in the build workspace.

---

## Set Gradle user home

```bash
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/tmp/gradle-user-home}"
```

This keeps the image default if already set.

If not set, it uses:

```text
/tmp/gradle-user-home
```

This is writable.

Gradle must not write to:

```text
/opt/gradle
```

because `/opt/gradle` is locked down.

---

## Create Gradle user home

```bash
mkdir -p "$GRADLE_USER_HOME"
```

Ensures Gradle has a writable directory for caches and runtime files.

---

## Create Java package directory

```bash
mkdir -p src/main/java/com/example
```

Creates the source path matching:

```java
package com.example;
```

---

## Write Java source file

```bash
cat > src/main/java/com/example/MyApp.java << 'EOF'
...
EOF
```

Creates this Java class:

```java
package com.example;

public class MyApp {
    public static void main(String[] args) {
        System.out.println("Success! Compiled with a pre-installed, SHA-verified Gradle binary.");
    }
}
```

---

## Write Gradle settings

```bash
cat > settings.gradle << 'EOF'
...
EOF
```

Creates the Gradle project settings file.

---

## Plugin repository block

```groovy
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}
```

Defines where Gradle plugins can be resolved.

The built-in `java` plugin does not require downloading an external plugin.

---

## Dependency repository governance

```groovy
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}
```

This centralizes dependency repository configuration.

It prevents project-level repository declarations from being silently added in `build.gradle`.

---

## Root project name

```groovy
rootProject.name = 'teamcity-inline-gradle-build'
```

Sets the Gradle root project name.

---

## Write Gradle build file

```bash
cat > build.gradle << 'EOF'
...
EOF
```

Creates the Gradle build configuration.

---

## Apply Java plugin

```groovy
plugins {
    id 'java'
}
```

Adds standard Java build tasks:

```text
clean
compileJava
classes
jar
build
```

---

## Use Java 21

```groovy
java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}
```

Tells Gradle to use Java 21.

The image is based on OpenJDK 21, so this matches the runtime.

---

## Verify Gradle is on PATH

```bash
which gradle
```

Expected output:

```text
/opt/gradle/bin/gradle
```

If this fails, Step 2 is not using the custom image.

---

## Print Gradle version

```bash
gradle --version
```

Expected output includes:

```text
Gradle 8.14.5
```

---

## Run the build

```bash
gradle --no-daemon clean build
```

Meaning:

```text
--no-daemon  Do not keep a Gradle daemon running.
clean        Remove old build output.
build        Compile and verify the project.
```

Expected successful result:

```text
BUILD SUCCESSFUL
```

---

# 12. Exact TeamCity field values

## Step 1

```text
Step name: Build hardened Gradle image
Runner type: Command Line
Run: Custom script
Run step within Docker container: OFF
Docker image field: not used
```

## Step 2

```text
Step name: Build Java app with hardened Gradle
Runner type: Command Line
Run: Custom script
Run step within Docker container: ON
Docker image: quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
```

---

# 13. Wrong vs correct

## Wrong

```text
Run step within Docker container: ON
Docker image: registry.access.redhat.com/ubi9/openjdk-21:1.24
```

Reason:

```text
That image has Java but not Gradle.
```

## Wrong

```text
Docker image: FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS gradle-dist
```

Reason:

```text
FROM is Dockerfile syntax, not an image name.
```

## Wrong

```text
Docker image: FROM registry.access.redhat.com/ubi9/openjdk-21:1.24
```

Reason:

```text
FROM is Dockerfile syntax, not an image name.
```

## Correct

```text
Docker image: quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
```

Reason:

```text
This is the final image built and pushed by Step 1.
```

---

# 14. Expected build flow

```text
TeamCity Step 1 starts
↓
Dockerfile is written
↓
Gradle 8.14.5 ZIP is downloaded
↓
SHA-256 is verified
↓
Gradle is unpacked into /opt/gradle
↓
Gradle install is hardened
↓
Final UBI9 OpenJDK 21 image is built
↓
java -version is tested
↓
gradle --version is tested
↓
Image is pushed to Quay
↓
TeamCity Step 2 starts
↓
TeamCity pulls quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
↓
Step runs inside that image
↓
Java files are written
↓
Gradle build files are written
↓
gradle --no-daemon clean build runs
↓
BUILD SUCCESSFUL
```

---

# 15. Failure checks

## Failure: `gradle: command not found`

Cause:

```text
Step 2 is not using the custom Quay image.
```

Fix:

```text
Set Step 2 Docker image to:
quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
```

---

## Failure: checksum mismatch

Failure appears near:

```bash
sha256sum -c -
```

Cause:

```text
The downloaded Gradle ZIP does not match the pinned SHA-256.
```

Fix:

```text
Do not bypass this.
Verify the Gradle version and checksum from the official Gradle checksum page.
```

---

## Failure: image push denied

Cause:

```text
TeamCity agent is not authenticated to Quay or lacks push permission.
```

Fix:

```text
Configure TeamCity registry credentials or enable the login line with secure TeamCity parameters.
```

---

## Failure: Docker or Podman not found

Cause:

```text
The TeamCity agent cannot build container images.
```

Fix:

```text
Run Step 1 on an agent that has docker or podman installed and configured.
```

---

# 16. Final checklist

Before running Step 2, Step 1 must successfully complete these commands:

```bash
"$CONTAINER_ENGINE" build --pull -t "$IMAGE" .
"$CONTAINER_ENGINE" run --rm "$IMAGE" java -version
"$CONTAINER_ENGINE" run --rm "$IMAGE" gradle --version
"$CONTAINER_ENGINE" push "$IMAGE"
```

Step 2 must use this image:

```text
quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
```

Step 2 must call:

```bash
gradle --no-daemon clean build
```

Step 2 must not call:

```bash
./gradlew build
```

Step 2 must not use:

```Dockerfile
FROM ...
```

---

# 17. Summary

Use `FROM` only in the Dockerfile created by Step 1.

Use the final Quay image name in Step 2.

The correct TeamCity setup is:

```text
Step 1:
Build and push quay.io/<org>/ubi9-openjdk21-gradle:8.14.5

Step 2:
Run step within Docker container using quay.io/<org>/ubi9-openjdk21-gradle:8.14.5
Run gradle --no-daemon clean build
```
