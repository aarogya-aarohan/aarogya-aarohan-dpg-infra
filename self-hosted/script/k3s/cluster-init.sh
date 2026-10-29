#!/usr/bin/env sh

# Install K3S
export PRIVATE_IP=<PRIVATE_IP of the server to prevent public access>
export K3S_KUBECONFIG_MODE="644"
export INSTALL_K3S_EXEC="server --disable=traefik --bind-address ${PRIVATE_IP} --advertise-address ${PRIVATE_IP} --node-ip ${PRIVATE_IP}"

# Backup credentials come from the environment so they are never written into this script:
#   export LITESTREAM_ACCESS_KEY_ID=... LITESTREAM_SECRET_ACCESS_KEY=...
export AWS_ACCESS_KEY="${LITESTREAM_ACCESS_KEY_ID:?set LITESTREAM_ACCESS_KEY_ID}"
export AWS_SECRET_KEY="${LITESTREAM_SECRET_ACCESS_KEY:?set LITESTREAM_SECRET_ACCESS_KEY}"
export INFRA_BUCKET=<AWS_BUCKET for cluster data>
export CLUSTER_NAME=<Cluster Name>

cat > /etc/litestream.yml << END
access-key-id: ${AWS_ACCESS_KEY}
secret-access-key: ${AWS_SECRET_KEY}
dbs:
  - path: /var/lib/rancher/k3s/server/db/state.db
    replicas:
      - url: s3://${INFRA_BUCKET}/backups/k3s/${CLUSTER_NAME}
END
chmod 600 /etc/litestream.yml


# Install litestream
curl -o /tmp/litestream.deb -fsSL https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-amd64.deb
dpkg --force-confold -i /tmp/litestream.deb


# Install k3s
export INSTALL_K3S_SKIP_START=true
curl -sfL https://get.k3s.io | sh -

# Configure Registry

export DOCKER_USERNAME=<DOCKER_USERNAME>
export DOCKER_TOKEN=<Docker PAT>
sudo mkdir -p /etc/rancher/k3s
sudo cat << EOF > /etc/rancher/k3s/registries.yaml
configs:
  registry-1.docker.io:
    auth:
      username: ${DOCKER_USERNAME}
      password: ${DOCKER_TOKEN}
EOF

litestream restore -if-replica-exists /var/lib/rancher/k3s/server/db/state.db

# Start k3s
systemctl start k3s

# Start Litestream
systemctl enable litestream
systemctl start litestream

