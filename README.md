# UBI9 JDK 21 Gradle 8 hardened container

Hardened Red Hat UBI9 container for Java builds requiring:

- Red Hat UBI9
- JDK 21
- Gradle 8.x
- non-root execution
- pinned Gradle distribution checksum
- minimal build image posture
- separate runtime image without Gradle

This repository intentionally separates the **build image** from the **runtime image**.

## Image design

| Image | Purpose | Contains |
|---|---|---|
| `Dockerfile` | CI/build image | UBI9 OpenJDK 21 builder image + Gradle 8 |
| `Dockerfile.runtime` | Application runtime base | UBI9 OpenJDK 21 runtime image + app jar only |

Do not deploy the Gradle build image to production. Use it only for CI or controlled build environments.

## Version pins

| Component | Value |
|---|---|
| UBI minimal staging image | `registry.access.redhat.com/ubi9/ubi-minimal:9.6` |
| JDK build image | `registry.access.redhat.com/ubi9/openjdk-21:1.24` |
| JDK runtime image | `registry.access.redhat.com/ubi9/openjdk-21-runtime:1.24` |
| Gradle | `8.14.5` |
| Gradle binary ZIP SHA-256 | `6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854` |
| Runtime user | `185` |

Source references:

- Red Hat UBI OpenJDK images: <https://rh-openjdk.github.io/redhat-openjdk-containers/>
- Red Hat UBI9 OpenJDK 21 builder image: <https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21/653fb7e21b2ec10f7dfc10d0>
- Red Hat UBI9 OpenJDK 21 runtime image: <https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21-runtime/6501ce769a0d86945c422d5f>
- Gradle checksums: <https://gradle.org/release-checksums/>
- Gradle distribution index: <https://services.gradle.org/distributions/>

## Repository layout

```text
.
├── Dockerfile
├── Dockerfile.runtime
├── Makefile
├── README.md
├── SECURITY.md
├── .dockerignore
├── .gitignore
├── .github
│   ├── dependabot.yml
│   └── workflows
│       └── build.yml
├── checksums
│   └── gradle-8.14.5-bin.zip.sha256
├── examples
│   └── run-hardened.sh
├── k8s
│   └── security-context.yaml
└── scripts
    ├── build.sh
    ├── run-hardened.sh
    ├── scan.sh
    └── verify-image.sh
```

## Build the hardened Gradle image

Using Make:

```bash
make build
```

Using Podman directly:

```bash
podman build \
  --pull=always \
  --build-arg GRADLE_VERSION=8.14.5 \
  --build-arg GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854 \
  -t ubi9-jdk21-gradle8-hardened:8.14.5 \
  -f Dockerfile .
```

Using Docker directly:

```bash
docker build \
  --pull \
  --build-arg GRADLE_VERSION=8.14.5 \
  --build-arg GRADLE_SHA256=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854 \
  -t ubi9-jdk21-gradle8-hardened:8.14.5 \
  -f Dockerfile .
```

## Verify the image

```bash
make verify
```

Manual verification:

```bash
podman run --rm ubi9-jdk21-gradle8-hardened:8.14.5 --version

podman run --rm \
  --entrypoint sh \
  ubi9-jdk21-gradle8-hardened:8.14.5 \
  -c 'id && java -version && javac -version && gradle --version'
```

Expected posture:

- user is not root
- user is `185`
- Gradle exists only in the build image
- Gradle installation files are read-only
- no downloaded ZIP remains in `/tmp`

## Hardened local run

Use network-disabled mode for reproducible builds after dependencies are available from cache or an internal repository mirror.

```bash
podman run --rm \
  --user 185:0 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit=512 \
  --memory=4g \
  --cpus=2 \
  --network=none \
  -v "$PWD":/workspace:Z \
  ubi9-jdk21-gradle8-hardened:8.14.5 \
  --offline clean test
```

For Docker, remove the SELinux `:Z` mount suffix if unsupported:

```bash
docker run --rm \
  --user 185:0 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit=512 \
  --memory=4g \
  --cpus=2 \
  --network=none \
  -v "$PWD":/workspace \
  ubi9-jdk21-gradle8-hardened:8.14.5 \
  --offline clean test
```

## Runtime image

The runtime image should not contain Gradle, Maven, curl, unzip, or a compiler.

Build your application first:

```bash
podman run --rm \
  --user 185:0 \
  -v "$PWD":/workspace:Z \
  ubi9-jdk21-gradle8-hardened:8.14.5 \
  clean build
```

Then build the runtime image:

```bash
podman build \
  --pull=always \
  -f Dockerfile.runtime \
  -t my-java-app:runtime .
```

The runtime Dockerfile expects an application artifact at:

```text
build/libs/app.jar
```

Change this path in `Dockerfile.runtime` if your Gradle project emits a differently named jar.

## Kubernetes security context

Use the manifest snippet in `k8s/security-context.yaml`.

Minimum controls:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 185
  runAsGroup: 0
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
```

## CI

The GitHub Actions workflow in `.github/workflows/build.yml`:

- builds the container
- verifies Java, javac, and Gradle are available
- verifies the container user is not root
- verifies the hardened run mode works
- optionally runs Trivy if enabled

The workflow does not push images by default.

## Supply-chain controls

Required:

- keep `GRADLE_SHA256` pinned
- do not download Gradle without checksum verification
- build with `--pull=always` in CI
- scan the result before publishing
- deploy only `Dockerfile.runtime` output
- use internal artifact repositories instead of open internet during builds

Recommended:

- pin base images by digest for release builds
- sign published images with Cosign or equivalent
- generate SBOMs with Syft or equivalent
- fail builds on critical vulnerabilities where fixes exist
- run Gradle with dependency verification enabled in each application repository

## Gradle dependency verification

Inside each application repository, enable Gradle dependency verification:

```bash
gradle --write-verification-metadata sha256 help
```

Commit the generated file:

```text
gradle/verification-metadata.xml
```

This container secures the Gradle distribution itself. Application dependency verification remains the responsibility of the application repository.

## Hardening summary

| Area | Control |
|---|---|
| Base image | Red Hat UBI9 OpenJDK 21 builder image |
| Gradle | pinned version and checksum |
| Download integrity | SHA-256 verification required |
| Runtime user | non-root `185` |
| Runtime permissions | Gradle files are read-only |
| Writable paths | `/tmp` and mounted workspace only |
| Linux capabilities | drop all at runtime |
| Privilege escalation | disabled |
| Filesystem | read-only root filesystem at runtime |
| Network | disabled for hermetic/offline builds |
| Production image | separate runtime image without Gradle |
