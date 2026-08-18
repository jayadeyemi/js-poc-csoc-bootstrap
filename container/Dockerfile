FROM ubuntu:22.04

ARG KUBECTL_VERSION=1.29.3
ARG CLUSTERCTL_VERSION=1.7.2
ARG HELM_VERSION=3.14.3
ARG YQ_VERSION=4.43.1
ARG ARGOCD_VERSION=2.11.3

# Install system deps and OpenStack CLI (no interactive prompts)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-pip curl git jq gettext-base ca-certificates gnupg \
    && pip3 install --no-cache-dir \
        python-openstackclient~=6.6 \
        python-magnumclient~=4.8.0 \
        python-heatclient~=3.2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# clusterctl (Cluster API)
RUN curl -fsSL \
    "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTERCTL_VERSION}/clusterctl-linux-amd64" \
        -o /usr/local/bin/clusterctl \
    && chmod +x /usr/local/bin/clusterctl

# yq (YAML processor)
RUN curl -fsSL \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION="v${HELM_VERSION}" bash

# Argo CD CLI
RUN curl -fsSL \
    "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64" \
        -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/argocd

# Non-root user — credentials are mounted, not baked in
RUN useradd -ms /bin/bash jetstream \
    && mkdir -p /home/jetstream/.config/openstack \
                /home/jetstream/.kube \
                /home/jetstream/.cluster-api \
    && chown -R jetstream:jetstream /home/jetstream

WORKDIR /workspace
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER jetstream
ENV HOME=/home/jetstream \
    OS_CLOUD=openstack

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
