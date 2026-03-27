# Incus VM — Coder Template

Provisions a full QEMU/KVM virtual machine via [Incus](https://linuxcontainers.org/incus/) on a Raspberry Pi 5 host.

## Requirements

- Raspberry Pi 5 running Raspberry Pi OS / Debian
- Incus installed and initialized (`incus admin init`)
- `/dev/kvm` available (Pi 5 supports KVM)
- Coder provisioner running **on the Pi** (so `incus` CLI is available to Terraform local-exec)

## What it does

| Event | Action |
|---|---|
| Workspace **start** (new) | Creates Incus VM, installs Coder agent + code-server inside |
| Workspace **start** (existing) | Starts the stopped VM |
| Workspace **stop** | Stops the VM (preserves disk) |
| Workspace **delete** | Deletes the VM and all its data |

## Parameters

| Parameter | Options |
|---|---|
| OS Image | Ubuntu 24.04, Ubuntu 22.04, Debian 12, Alpine 3.20 |
| CPU Cores | 1, 2, 4 |
| Memory | 1, 2, 4, 8 GB |
| Disk Size | 10, 20, 40 GB (set at create time, immutable) |

## Uploading the template

```bash
coder templates create incus-vm --directory ./incus-vm-template
```

Or push an update:

```bash
coder templates push incus-vm --directory ./incus-vm-template
```
