#!/usr/bin/env bash

CONTAINERD_VERSION="1.6.20-1"
DOCKER_VERSION="5:23.0.5-1~debian.$(cat /etc/debian_version | cut -d'.' -f1)~$(lsb_release -cs)"

MYIFACE="eth1"
MYIP="$( ip -4 addr show ${MYIFACE} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' )"

# Basic package installation
apt update
apt install -y vim dos2unix
cat << EOF > /root/.vimrc
set nomodeline
set bg=dark
set tabstop=2
set expandtab
set ruler
set nu
syntax on
EOF
find /usr/local/bin -name lab-* | xargs dos2unix

# Prepare SSH inter-VM communication
mv /home/vagrant/ssh/* /home/vagrant/.ssh
rm -r /home/vagrant/ssh
dos2unix /home/vagrant/.ssh/tmpkey
dos2unix /home/vagrant/.ssh/tmpkey.pub
cat /home/vagrant/.ssh/tmpkey.pub >> /home/vagrant/.ssh/authorized_keys
cat << EOF >> /home/vagrant/.ssh/config
Host s2-*
   StrictHostKeyChecking no
   UserKnownHostsFile=/dev/null
EOF
chown vagrant. /home/vagrant/.ssh/config
chmod 600 /home/vagrant/.ssh/config /home/vagrant/.ssh/tmpkey

# Setup /etc/hosts
cat << EOF >> /etc/hosts
192.168.68.20 s2-master-1
192.168.68.25 s2-node-1
EOF

# Install Docker
apt install -y apt-transport-https \
               ca-certificates     \
               curl                \
               gnupg               \
               lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y containerd.io=${CONTAINERD_VERSION} \
               docker-ce=${DOCKER_VERSION}      \
               docker-ce-cli=${DOCKER_VERSION}
cat <<EOF | tee /etc/docker/daemon.json
{
  "log-opts": {
    "max-size": "100m"
  }
}
EOF

# Enable and configure required modules
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Install cri-dockerd
wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.1/cri-dockerd_0.3.1.3-0.debian-bullseye_amd64.deb
apt install -y ./cri-dockerd_0.3.1.3-0.debian-bullseye_amd64.deb

mkdir -p /etc/systemd/system/docker.service.d
systemctl daemon-reload
systemctl restart docker
systemctl enable docker

# Enable bridged traffic through iptables
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# Configure containerd
mkdir -p /etc/containerd
containerd config default | \
  sed 's/^\([[:space:]]*SystemdCgroup = \).*/\1true/' | \
  tee /etc/containerd/config.toml

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Install kubeadm, kubelet, and kubectl using the updated repository
apt update
apt install -y apt-transport-https ca-certificates curl gnupg

# Create the keyrings directory if it doesn't exist (for Debian 11 and earlier)
mkdir -p /etc/apt/keyrings

# Download and add the Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-archive-keyring.gpg  # Allow unprivileged APT programs to read this keyring

# Add the Kubernetes apt repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | \
  tee /etc/apt/sources.list.d/kubernetes.list
chmod 644 /etc/apt/sources.list.d/kubernetes.list  # Helps tools such as command-not-found to work correctly

# Update package listings and install Kubernetes components
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Set correct IP address for kubelet and use cri-dockerd
echo "KUBELET_EXTRA_ARGS=\"--node-ip=${MYIP} --container-runtime-endpoint=unix:///var/run/cri-dockerd.sock\"" >> /etc/default/kubelet
systemctl restart kubelet

# Configure kubectl autocompletion
kubectl completion bash > /etc/bash_completion.d/kubectl
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

if [ "$1" == "master" ]; then
  # Initialize cluster
  kubeadm config images pull --cri-socket unix:///var/run/cri-dockerd.sock
  kubeadm init --apiserver-advertise-address=${MYIP} \
    --apiserver-cert-extra-sans=${MYIP} \
    --cri-socket unix:///var/run/cri-dockerd.sock \
    --node-name="$( hostname )" \
    --pod-network-cidr=192.168.0.0/16 \
    --ignore-preflight-errors="all"

  # Configure kubectl
  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  # Install Calico CNI plugin
  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

  # Create kubeadm join token
  join_command="$( kubeadm token create --print-join-command )"
  echo "${join_command} --cri-socket unix:///var/run/cri-dockerd.sock" > /opt/join_token

  # Copy exercise scripts, set permissions
  mv /home/vagrant/scripts/* /usr/local/bin
  rm -r /home/vagrant/scripts
  chown root. /usr/local/bin/*
  chmod +x /usr/local/bin/*
else
  # Copy join token and enter cluster
  sudo -u vagrant scp -i /home/vagrant/.ssh/tmpkey vagrant@s2-master-1:/opt/join_token /tmp
  sh /tmp/join_token
  rm -f /tmp/join_token
fi
