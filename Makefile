IMAGE ?= ubi9-jdk21-gradle8-hardened
VERSION ?= 8.14.5
TAG ?= $(IMAGE):$(VERSION)
GRADLE_VERSION ?= 8.14.5
GRADLE_SHA256 ?= 6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854
ENGINE ?= podman

.PHONY: build verify run scan clean

build:
	$(ENGINE) build \
		--pull=always \
		--build-arg GRADLE_VERSION=$(GRADLE_VERSION) \
		--build-arg GRADLE_SHA256=$(GRADLE_SHA256) \
		-t $(TAG) \
		-f Dockerfile .

verify:
	IMAGE=$(TAG) ENGINE=$(ENGINE) ./scripts/verify-image.sh

run:
	IMAGE=$(TAG) ENGINE=$(ENGINE) ./scripts/run-hardened.sh --version

scan:
	IMAGE=$(TAG) ./scripts/scan.sh

clean:
	$(ENGINE) image rm $(TAG) || true
