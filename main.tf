terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "coder" {}

# --------------------------------------------------------------------------- #
# Parameters
# --------------------------------------------------------------------------- #

data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU Cores"
  description  = "Number of vCPU cores for the VM."
  type         = "number"
  default      = "2"
  mutable      = true
  option {
    name  = "1 core"
    value = "1"
  }
  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GB)"
  description  = "RAM allocated to the VM."
  type         = "number"
  default      = "2"
  mutable      = true
  option {
    name  = "1 GB"
    value = "1"
  }
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "disk_gb" {
  name         = "disk_gb"
  display_name = "Disk Size (GB)"
  description  = "Root disk size for the VM."
  type         = "number"
  default      = "20"
  mutable      = false
  option {
    name  = "10 GB"
    value = "10"
  }
  option {
    name  = "20 GB"
    value = "20"
  }
  option {
    name  = "40 GB"
    value = "40"
  }
}

data "coder_parameter" "os_image" {
  name         = "os_image"
  display_name = "OS Image"
  description  = "Operating system for the VM."
  type         = "string"
  default      = "images:ubuntu/24.04"
  mutable      = false
  option {
    name  = "Ubuntu 24.04 LTS"
    value = "images:ubuntu/24.04"
  }
  option {
    name  = "Ubuntu 22.04 LTS"
    value = "images:ubuntu/22.04"
  }
  option {
    name  = "Debian 12"
    value = "images:debian/12"
  }
  option {
    name  = "Alpine 3.20"
    value = "images:alpine/3.20"
  }
  option {
    name  = "NixOS (unstable, arm64)"
    value = "images:nixos/unstable/arm64"
  }
}

# --------------------------------------------------------------------------- #
# Coder workspace metadata
# --------------------------------------------------------------------------- #

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  # Sanitized VM name: incus names must be lowercase alphanumeric + hyphens
  vm_name  = "coder-${replace(lower(data.coder_workspace_owner.me.name), "_", "-")}-${replace(lower(data.coder_workspace.me.name), "_", "-")}"
  is_nixos = startswith(data.coder_parameter.os_image.value, "images:nixos")
}

# --------------------------------------------------------------------------- #
# Agent
# --------------------------------------------------------------------------- #

resource "coder_agent" "main" {
  arch = "arm64"
  os   = "linux"

  startup_script = local.is_nixos ? "" : <<-EOT
    set -e
    # Install common dev tools if not present
    if ! command -v git &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y git curl wget vim
    fi
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "cpu_usage"
    script       = "top -bn1 | grep 'Cpu(s)' | awk '{print $2 + $4 \"%\"}'"
    interval     = 10
    timeout      = 5
  }

  metadata {
    display_name = "Memory Usage"
    key          = "mem_usage"
    script       = "free -h | awk '/^Mem:/ {print $3 \"/\" $2}'"
    interval     = 10
    timeout      = 5
  }

  metadata {
    display_name = "Disk Usage"
    key          = "disk_usage"
    script       = "df -h / | awk 'NR==2 {print $3 \"/\" $2}'"
    interval     = 60
    timeout      = 5
  }
}

# --------------------------------------------------------------------------- #
# VS Code app
# --------------------------------------------------------------------------- #

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code (code-server)"
  url          = "http://localhost:13337/?folder=/home/${data.coder_workspace_owner.me.name}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 15
  }
}

# --------------------------------------------------------------------------- #
# VM lifecycle — create on start, delete on stop/destroy
# --------------------------------------------------------------------------- #

resource "null_resource" "vm" {
  triggers = {
    vm_name     = local.vm_name
    os_image    = data.coder_parameter.os_image.value
    disk_gb     = data.coder_parameter.disk_gb.value
    cpu_cores   = data.coder_parameter.cpu_cores.value
    memory_gb   = data.coder_parameter.memory_gb.value
    agent_token = coder_agent.main.token
  }

  # ---- Create / start -------------------------------------------------------
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      VM="${local.vm_name}"
      IMAGE="${data.coder_parameter.os_image.value}"
      DISK="${data.coder_parameter.disk_gb.value}"
      CPU="${data.coder_parameter.cpu_cores.value}"
      MEM="${data.coder_parameter.memory_gb.value}"
      AGENT_TOKEN="${coder_agent.main.token}"
      AGENT_URL="${data.coder_workspace.me.access_url}"
      OWNER="${data.coder_workspace_owner.me.name}"

      # If container/VM already exists (workspace restart), just start it
      if incus info "$VM" &>/dev/null; then
        echo "$VM already exists, starting..."
        incus start "$VM" || true
        exit 0
      fi

      # -----------------------------------------------------------------------
      # NixOS: run as a container (arm64 VM images not available on linuxcontainers.org)
      # -----------------------------------------------------------------------
      if [[ "$IMAGE" == *"nixos"* ]]; then
        echo "Creating NixOS container $VM from $IMAGE..."
        incus launch "$IMAGE" "$VM" \
          --config limits.cpu="$CPU" \
          --config limits.memory="$${MEM}GiB" \
          --config security.nesting=true

        echo "Waiting for NixOS to boot..."
        for i in $(seq 1 90); do
          if incus exec "$VM" -- nixos-version &>/dev/null; then
            echo "NixOS is up."
            break
          fi
          sleep 3
        done

        echo "Provisioning NixOS container..."
        incus exec "$VM" -- bash -c "
          set -euo pipefail

          # Update nix channel
          nix-channel --add https://nixos.org/channels/nixos-unstable nixos
          nix-channel --update

          # Write NixOS configuration
          cat > /etc/nixos/configuration.nix <<'NIXCFG'
{ config, pkgs, ... }:
{
  imports = [ ];

  # Container-specific settings (no bootloader needed)
  boot.isContainer = true;

  networking.useDHCP = true;

  # Allow nix builds inside container
  nix.settings.sandbox = false;

  users.users.$OWNER = {
    isNormalUser = true;
    extraGroups  = [ \"wheel\" ];
    shell        = pkgs.bash;
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    code-server
  ];

  systemd.services.coder-agent = {
    description = \"Coder Agent\";
    after       = [ \"network-online.target\" ];
    wants       = [ \"network-online.target\" ];
    wantedBy    = [ \"multi-user.target\" ];
    serviceConfig = {
      User             = \"$OWNER\";
      ExecStart        = \"/usr/local/bin/coder agent\";
      Restart          = \"always\";
      RestartSec       = \"5s\";
      Environment      = [
        \"CODER_AGENT_TOKEN=$AGENT_TOKEN\"
        \"CODER_AGENT_URL=$AGENT_URL\"
      ];
    };
  };
}
NIXCFG

          # Download Coder agent binary (arm64)
          mkdir -p /usr/local/bin
          curl -fsSL '$AGENT_URL/bin/coder-linux-arm64' -o /usr/local/bin/coder
          chmod +x /usr/local/bin/coder

          # Create user home if missing
          mkdir -p /home/$OWNER
          chown $OWNER:users /home/$OWNER 2>/dev/null || true

          # Apply NixOS configuration
          nixos-rebuild switch --option sandbox false
        "

        echo "NixOS container $VM is up and agent is starting."

      # -----------------------------------------------------------------------
      # Non-NixOS: standard VM path (Ubuntu / Debian / Alpine)
      # -----------------------------------------------------------------------
      else
        echo "Creating VM $VM from $IMAGE..."
        incus launch "$IMAGE" "$VM" \
          --vm \
          --config limits.cpu="$CPU" \
          --config limits.memory="$${MEM}GiB" \
          --device root,size="$${DISK}GiB"

        echo "Waiting for VM to boot..."
        for i in $(seq 1 60); do
          if incus exec "$VM" -- test -f /etc/os-release 2>/dev/null; then
            break
          fi
          sleep 3
        done

        echo "Installing Coder agent inside VM..."
        incus exec "$VM" -- bash -c "
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive

          # Install dependencies
          apt-get update -qq
          apt-get install -y curl sudo

          # Create workspace owner user if not exists
          id -u $OWNER &>/dev/null || \
            useradd -m -s /bin/bash -G sudo $OWNER
          echo '$OWNER ALL=(ALL) NOPASSWD:ALL' \
            > /etc/sudoers.d/coder-user

          # Install code-server
          curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone --prefix=/usr/local

          # Write Coder agent systemd unit
          cat > /etc/systemd/system/coder-agent.service <<SERVICE
[Unit]
Description=Coder Agent
After=network-online.target
Wants=network-online.target

[Service]
User=$OWNER
Environment=CODER_AGENT_TOKEN=$AGENT_TOKEN
Environment=CODER_AGENT_URL=$AGENT_URL
ExecStart=/usr/local/bin/coder agent
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

          # Download Coder agent binary (arm64)
          curl -fsSL '$AGENT_URL/bin/coder-linux-arm64' -o /usr/local/bin/coder
          chmod +x /usr/local/bin/coder

          systemctl daemon-reload
          systemctl enable --now coder-agent
        "

        echo "VM $VM is up and agent is running."
      fi
    EOT
  }

  # ---- Destroy --------------------------------------------------------------
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      VM="${self.triggers.vm_name}"
      echo "Deleting $VM..."
      incus delete "$VM" --force || true
      echo "Deleted."
    EOT
  }
}

# --------------------------------------------------------------------------- #
# Stop VM/container when workspace is stopped (without destroying it)
# --------------------------------------------------------------------------- #

resource "null_resource" "vm_stop" {
  depends_on = [null_resource.vm]

  triggers = {
    vm_name = local.vm_name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      incus stop "${self.triggers.vm_name}" --force 2>/dev/null || true
    EOT
  }
}
