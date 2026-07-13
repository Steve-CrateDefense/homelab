#!/bin/bash

helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --namespace kube-system --values values.yaml
