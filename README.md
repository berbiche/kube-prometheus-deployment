# kube-prometheus-kubespray

[![Build manifests and push](https://github.com/berbiche/kube-prometheus-kubespray/actions/workflows/ci.yaml/badge.svg)](https://github.com/berbiche/kube-prometheus-kubespray/actions/workflows/ci.yaml)

Custom configuration for the prometheus configuration of my bare-metal
Kubernetes cluster.

This configuration is tailored for my network (i.e. DNS, ingress and certificate resolvers)
and would need to be updated for your own use.

## Building

Simply run `nix-shell --run './build.sh kubespray.jsonnet'`

## Using

Add the following to your `kustomization.yaml`:

``` yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- https://github.com/berbiche/kube-prometheus-kubespray/releases/download/v0.1.2/manifests.zip
```

An additional secret will have to be added and generated:

``` yaml

```

