FROM alpine/k8s:1.34.9@sha256:72c921a10c53ab749674e828ad12b776d006481c852bba7dd89e149ceed666f3 AS builder

ARG HELM_VERSION=3.21.4
ARG SOPS_VERSION=3.11.0
ARG AGE_VERSION=1.2.1
ARG KUSTOMIZE_VERSION=5.7.1
ARG YQ_VERSION=4.53.3

RUN apk add --no-cache ca-certificates curl tar \
 && curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
 && curl -fsSLo /tmp/sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
 && curl -fsSLo /tmp/age.tgz "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
 && curl -fsSLo /tmp/kustomize.tgz "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSLo /tmp/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
 && mkdir -p /out/bin /out/charts /tmp/helm /tmp/age /tmp/kustomize \
 && tar -xzf /tmp/helm.tgz -C /tmp/helm \
 && tar -xzf /tmp/age.tgz -C /tmp/age \
 && tar -xzf /tmp/kustomize.tgz -C /tmp/kustomize \
 && install -m 0755 /tmp/helm/linux-amd64/helm /out/bin/helm \
 && install -m 0755 /tmp/sops /out/bin/sops \
 && install -m 0755 /tmp/age/age/age /out/bin/age \
 && install -m 0755 /tmp/age/age/age-keygen /out/bin/age-keygen \
 && install -m 0755 /tmp/kustomize/kustomize /out/bin/kustomize \
 && install -m 0755 /tmp/yq /out/bin/yq \
 && /out/bin/helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ \
 && /out/bin/helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
 && /out/bin/helm repo update \
 && /out/bin/helm pull jupyterhub/jupyterhub --version 4.3.4 --destination /out/charts \
 && /out/bin/helm pull prometheus-community/kube-prometheus-stack --version 84.3.0 --destination /out/charts

FROM alpine/k8s:1.34.9@sha256:72c921a10c53ab749674e828ad12b776d006481c852bba7dd89e149ceed666f3

COPY --from=builder /out/bin/ /usr/local/bin/
COPY --from=builder /out/charts/ /opt/csoc/charts/
COPY generate.sh /usr/local/bin/csoc-cmp-generate

RUN chmod 0755 /usr/local/bin/csoc-cmp-generate \
 && addgroup -g 10001 csoc \
 && adduser -D -H -u 10001 -G csoc csoc

USER 10001:10001
WORKDIR /workspace
ENV HOME=/tmp/home
ENTRYPOINT ["/var/run/argocd/argocd-cmp-server"]
