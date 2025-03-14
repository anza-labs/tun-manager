# tun-manager

[![GitHub License](https://img.shields.io/github/license/anza-labs/tun-manager)][license]
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](code_of_conduct.md)
[![GitHub issues](https://img.shields.io/github/issues/anza-labs/tun-manager)](https://github.com/anza-labs/tun-manager/issues)
[![GitHub release](https://img.shields.io/github/release/anza-labs/tun-manager)](https://GitHub.com/anza-labs/tun-manager/releases/)
[![Go Report Card](https://goreportcard.com/badge/github.com/anza-labs/tun-manager)](https://goreportcard.com/report/github.com/anza-labs/tun-manager)

`tun-manager` is a Kubernetes Device Plugin that manages access to `/dev/net/tun` (Kernel-based Virtual Network Device). It allows workloads running in Kubernetes to request tun access via the Device Plugin interface, ensuring proper communication with the kubelet.

- [tun-manager](#tun-manager)
  - [Features](#features)
  - [Device plugin](#device-plugin)
    - [Installation](#installation)
    - [Usage](#usage)
    - [How It Works](#how-it-works)
  - [Compatibility](#compatibility)
  - [License](#license)
  - [Attributions](#attributions)

## Features

- Provides access to `/dev/net/tun` for containers running in Kubernetes.
- Implements the Kubernetes Device Plugin API to manage tun allocation.
- Ensures that only workloads explicitly requesting tun access receive it.

## Device plugin

### Installation

To deploy the `tun-manager` device plugin, apply the provided manifests:

```sh
LATEST="$(curl -s 'https://api.github.com/repos/anza-labs/tun-manager/releases/latest' | jq -r '.tag_name')"
kubectl apply -k "https://github.com/anza-labs/tun-manager/?ref=${LATEST}"
```

### Usage

To request access to `/dev/net/tun` in a pod, specify the device resource in the `resources` section:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tun-checker
spec:
  restartPolicy: Never
  containers:
    - name: tun-checker
      image: busybox
      command: ["sh", "-c", "[ -e /dev/net/tun ]"]
      resources:
        requests:
          devices.anza-labs.dev/tun: '1' # Request tun device
        limits:
          devices.anza-labs.dev/tun: '1' # Limit tun device
```

### How It Works

1. The `tun-manager` registers with the kubelet and advertises available tun devices.
2. When a pod requests the `devices.anza-labs.dev/tun` resource, the device plugin assigns a `/dev/net/tun` device to the container.
3. The container is granted access to `/dev/net/tun` for virtualization tasks.

## Compatibility

- Kubernetes 1.20+

## License

`tun-manager` is licensed under the [Apache-2.0][license].

## Attributions

This codebase is inspired by:
- [github.com/squat/generic-device-plugin](https://github.com/squat/generic-device-plugin)
- [github.com/kubevirt/kubernetes-device-plugins](https://github.com/kubevirt/kubernetes-device-plugins)

<!-- Resources -->

[license]: https://github.com/anza-labs/tun-manager/blob/main/LICENSE
