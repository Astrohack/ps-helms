set dotenv-load

cluster_name := "local-k3s"
k3d_config_single := "infrastructure/k3d-config.yaml"
k3d_config_ha := "infrastructure/k3d-config-ha.yaml"
age_key_file := "sops-age.key"
ingress_tls_secrets_file := "gitops/charts/infrastructure/istio-ingressgateway/secrets.enc.yaml"
domain := "*.dev.localhost"
call_recipe := just_executable() + " --justfile=" + justfile()

# Lists all available tasks
_default:
    @just --list

# Provisions the raw k3d cluster with ports 80/443 exposed
cluster-create mode:
    @echo "Provisioning k3d cluster..."
    k3d cluster create -c {{ if mode == "single" { k3d_config_single } else if mode == "ha" { k3d_config_ha } else { error("allowed re only 'single' or 'ha'") } }}

# Removes all local clusters, purges docker networks and restart docker
cluster-purge:
    k3d cluster delete --all
    docker network prune -f
    sudo systemctl restart docker

# Removes the local k3d cluster instance
cluster-delete:
    @echo "Destroying k3d cluster..."
    k3d cluster delete {{ cluster_name }}

# Boots the cluster and bootstraps ArgoCD
bootstrap:
    @echo "Bootstrap in progress..."
    kubectl create namespace argocd || true
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd -n argocd -f infrastructure/argocd-values.yaml --version 9.5.17
    {{ call_recipe }} _wait-for-argocd
    kubectl apply -f gitops/bootstrap/appproject.yaml  -f gitops/bootstrap/apps.yaml --wait

# Waits for Argo CD server to become ready
_wait-for-argocd:
    #!/usr/bin/env bash
    echo "Waiting for Argo CD to be ready..."
    while ! kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -q 'True'; do
      sleep 2
    done
    echo "Argo CD is ready."

# Generates a new Age key pair and updates .sops.yaml if it doesn't exist
setup-sops:
    #!/usr/bin/env bash
    if [ ! -f {{ age_key_file }} ]; then
        echo "Generating new Age key..."
        age-keygen -o {{ age_key_file }}
    else
        echo "Age key already exists."
    fi
    PUB=$(age-keygen -y {{ age_key_file }}) yq -i '.creation_rules[].age = strenv(PUB)' .sops.yaml

# Injects the private Age key into the cluster before Argo CD starts
inject-sops-key:
    @echo "Injecting SOPS key into cluster..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic sops-age \
        -n argocd \
        --from-file=keys.txt={{ age_key_file }} \
        --dry-run=client -o yaml | kubectl apply -f -

_setup-local-ca:
    @echo "Installing mkcert local CA..."
    mkcert -install

# Generates TLS cert, injects into Argo CD expose secrets, and encrypts with SOPS
generate-and-inject-tls: _setup-local-ca
    #!/usr/bin/env bash
    set -e

    SECRET_FILE="{{ ingress_tls_secrets_file }}"

    mkcert -cert-file tls.crt -key-file tls.key "{{ domain }}"

    if [ -f "$SECRET_FILE" ]; then
        if grep -q "sops:" "$SECRET_FILE"; then
            sops --decrypt --in-place "$SECRET_FILE"
        fi
    else
        mkdir -p $(dirname "$SECRET_FILE")
        echo "tls:" > "$SECRET_FILE"
    fi

    yq -i '.tls.cert = load_str("tls.crt") | .tls.key = load_str("tls.key")' "$SECRET_FILE"

    sops --encrypt --in-place "$SECRET_FILE"

    rm tls.crt tls.key
