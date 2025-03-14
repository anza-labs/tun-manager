# Easy crosscomple toolkit
FROM ghcr.io/grpc-ecosystem/grpc-health-probe:v0.4.37 AS probe
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.6.1 AS xx

# Build the plugin binary
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.24 AS builder
ARG TARGETOS
ARG TARGETARCH
ARG TARGETPLATFORM
COPY --from=xx / /

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN xx-go mod download

# Copy the go source
COPY cmd/tun-device-plugin/main.go cmd/tun-device-plugin/main.go
COPY pkg/ pkg/

# Build
ENV CGO_ENABLED=0
RUN xx-go build -trimpath -a -o tun-device-plugin cmd/tun-device-plugin/main.go && \
    xx-verify tun-device-plugin

# Use distroless as minimal base image to package the plugin binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
# hadolint ignore=DL3007
FROM gcr.io/distroless/static:latest
WORKDIR /
COPY --from=builder /workspace/tun-device-plugin .
COPY --from=probe /ko-app/grpc-health-probe /grpc_health_probe

ENTRYPOINT ["/tun-device-plugin"]
