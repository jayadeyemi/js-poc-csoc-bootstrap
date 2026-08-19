FROM ubuntu:24.04

ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG YQ_VERSION
ARG ARGOCD_CLI_VERSION
ARG OPENSTACK_CLIENT_VERSION
ARG MAGNUM_CLIENT_VERSION
ARG OCTAVIA_CLIENT_VERSION
ARG DESIGNATE_CLIENT_VERSION
ARG HEAT_CLIENT_VERSION

# Install system deps and OpenStack CLI (no interactive prompts)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-venv curl git jq ripgrep gettext-base ca-certificates gnupg \
    && python3 -m venv /opt/openstack \
    && /opt/openstack/bin/pip install --no-cache-dir \
        "python-openstackclient==${OPENSTACK_CLIENT_VERSION}" \
        "python-magnumclient==${MAGNUM_CLIENT_VERSION}" \
        "python-octaviaclient==${OCTAVIA_CLIENT_VERSION}" \
        "python-designateclient==${DESIGNATE_CLIENT_VERSION}" \
        "python-heatclient==${HEAT_CLIENT_VERSION}" \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/openstack/bin:${PATH}"

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# yq (YAML processor)
RUN curl -fsSL \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Helm
RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

# Argo CD CLI
RUN curl -fsSL \
    "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_CLI_VERSION}/argocd-linux-amd64" \
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
