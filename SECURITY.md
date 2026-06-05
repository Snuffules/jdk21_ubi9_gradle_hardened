# Security policy

## Supported posture

This repository is intended for hardened build containers only.

Supported controls:

- pinned Gradle distribution version
- pinned Gradle distribution SHA-256
- non-root user
- read-only root filesystem at runtime
- dropped Linux capabilities at runtime
- disabled privilege escalation at runtime
- separate runtime image without Gradle

## Reporting issues

Report vulnerabilities through the repository security advisory flow if available. Otherwise, open a private issue in the internal tracker used by the owning organization.

## Required maintenance

- rebuild regularly with `--pull=always`
- monitor Red Hat UBI/OpenJDK advisories
- monitor Gradle releases and checksums
- scan images before promotion
- pin base images by digest for release builds
- sign release images
- generate and store SBOMs

## Not covered

This image does not secure application dependencies by itself. Each application repository must enable Gradle dependency verification and use controlled artifact repositories.
