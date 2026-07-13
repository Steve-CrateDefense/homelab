# Local talos setup

## Set up control node
https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started

## Setting up worker nodes
The worker nodes use a parsed down version of the control node settings. 

Essentially: 
* Move your usb drive to the worker node and boot from it then...
```bash
# Get the worker node IP and set it
export WORKER_IP_X="X.X.X.X"

# get the disk to use, mine was just nvme01 or something from a windows dell machine
talosctl get disks --insecure --nodes $WORKER_IP_X

# Since the config is already generated just re-use it unless the mount is different
talosctl apply-config --insecure --nodes $WORKER_IP_X --file worker.yaml
```

Because the kubeconfig are already set just run `kubectl get nodes` after the node is ready and see if it joined

## Config cilium
https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#without-kube-proxy-%2B-gateway-api

Claude gave me a path for the live config 
```
talosctl patch mc --patch @patch.yaml \
  -n $CONTROL_PLANE_IP,$WORKER_IP_1,$WORKER_IP_2 \
  --dry-run
```

`talosctl -n $CONTROL_PLANE_IP reboot`

# Install metrics server
https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server

# Longhorn
https://longhorn.io/docs/archives/1.9.0/advanced-resources/os-distro-specific/talos-linux-support/
