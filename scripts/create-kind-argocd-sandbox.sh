#!/usr/bin/env bash
#
# create-kind-argocd-sandbox.sh
#
# Creates an Argo CD sandbox on a local KIND cluster using Helm.
# Includes NGINX Ingress Controller for direct access without port-forwarding.
#
# USAGE:
#   ./scripts/create-kind-argocd-sandbox.sh
#   CLUSTER_NAME=demo ./scripts/create-kind-argocd-sandbox.sh
#   ARGOCD_CHART_VERSION=8.2.7 ./scripts/create-kind-argocd-sandbox.sh
#   ARGOCD_SYNC_INTERVAL=30s ./scripts/create-kind-argocd-sandbox.sh
#   PORT_FORWARD=true ./scripts/create-kind-argocd-sandbox.sh
#   DELETE=true ./scripts/create-kind-argocd-sandbox.sh
#   APPLY_EXAMPLE=true ./scripts/create-kind-argocd-sandbox.sh
#
# ENVIRONMENT VARIABLES:
#   CLUSTER_NAME          KIND cluster name (default: argocd-sandbox)
#   ARGOCD_CHART_VERSION  Helm chart version for argo-cd (default: 8.2.7)
#   ARGOCD_SYNC_INTERVAL  Application sync interval (default: 3m, e.g., 30s, 1m, 5m)
#   RELEASE_NAME          Helm release name (default: argocd)
#   PORT_FORWARD          If "true", run port-forward in background (default: false)
#   DELETE                If "true", delete the KIND cluster and exit (default: false)
#   APPLY_EXAMPLE         If "true", apply an example Application CR (default: false)
#   ARGOCD_HOSTNAME       Hostname for Argo CD Ingress (default: argocd.localhost)
#
# REQUIREMENTS:
#   - kind
#   - kubectl
#   - helm
#
# ACCESS:
#   After installation, access Argo CD at: https://argocd.localhost
#   (Add to /etc/hosts if needed: 127.0.0.1 argocd.localhost)
#

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration (with defaults)
#------------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-argocd-sandbox}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-8.2.7}"
ARGOCD_SYNC_INTERVAL="${ARGOCD_SYNC_INTERVAL:-3m}"
RELEASE_NAME="${RELEASE_NAME:-argocd}"
NAMESPACE="argocd"
HELM_REPO_NAME="argo"
HELM_REPO_URL="https://argoproj.github.io/argo-helm"
PORT_FORWARD="${PORT_FORWARD:-false}"
DELETE="${DELETE:-false}"
APPLY_EXAMPLE="${APPLY_EXAMPLE:-false}"
ARGOCD_HOSTNAME="${ARGOCD_HOSTNAME:-argocd.localhost}"

# Ingress NGINX configuration
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.11.3}"

#------------------------------------------------------------------------------
# Colors and logging
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}▶ $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

#------------------------------------------------------------------------------
# Cleanup function for port-forward
#------------------------------------------------------------------------------
PF_PID=""
cleanup() {
    if [[ -n "$PF_PID" ]]; then
        log_info "Stopping port-forward (PID: $PF_PID)..."
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

#------------------------------------------------------------------------------
# Dependency checks
#------------------------------------------------------------------------------
check_dependencies() {
    log_step "Checking dependencies"
    
    local missing=()
    
    if ! command -v kind &>/dev/null; then
        missing+=("kind")
    fi
    
    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl")
    fi
    
    if ! command -v helm &>/dev/null; then
        missing+=("helm")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo ""
        echo "Please install the missing tools:"
        for tool in "${missing[@]}"; do
            case "$tool" in
                kind)
                    echo "  kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
                    ;;
                kubectl)
                    echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
                    ;;
                helm)
                    echo "  helm:    https://helm.sh/docs/intro/install/"
                    ;;
            esac
        done
        exit 1
    fi
    
    log_success "All dependencies found:"
    log_info "  kind:    $(kind version 2>/dev/null | head -1)"
    log_info "  kubectl: $(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | sed 's/.*"gitVersion": "\([^"]*\)".*/\1/')"
    log_info "  helm:    $(helm version --short 2>/dev/null)"
}

#------------------------------------------------------------------------------
# Delete cluster (if DELETE=true)
#------------------------------------------------------------------------------
delete_cluster() {
    log_step "Deleting KIND cluster: $CLUSTER_NAME"
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        kind delete cluster --name "$CLUSTER_NAME"
        log_success "Cluster '$CLUSTER_NAME' deleted."
    else
        log_warn "Cluster '$CLUSTER_NAME' does not exist. Nothing to delete."
    fi
    exit 0
}

#------------------------------------------------------------------------------
# Generate KIND cluster config with Ingress support
#------------------------------------------------------------------------------
generate_kind_config() {
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
}

#------------------------------------------------------------------------------
# Create or reuse KIND cluster (with Ingress support)
#------------------------------------------------------------------------------
ensure_kind_cluster() {
    log_step "Ensuring KIND cluster exists: $CLUSTER_NAME"
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Cluster '$CLUSTER_NAME' already exists. Reusing."
    else
        log_info "Creating KIND cluster '$CLUSTER_NAME' with Ingress support..."
        
        local kind_config
        kind_config=$(mktemp /tmp/kind-config-XXXXXX.yaml)
        generate_kind_config > "$kind_config"
        
        log_info "KIND config:"
        cat "$kind_config" | sed 's/^/    /'
        
        kind create cluster --name "$CLUSTER_NAME" --config "$kind_config" --wait 60s
        rm -f "$kind_config"
        
        log_success "Cluster '$CLUSTER_NAME' created with Ingress port mappings."
    fi
    
    # Switch kubectl context
    local context="kind-${CLUSTER_NAME}"
    log_info "Switching kubectl context to: $context"
    kubectl config use-context "$context"
    
    # Verify connection
    log_info "Verifying cluster connection..."
    kubectl cluster-info --context "$context" | head -2
}

#------------------------------------------------------------------------------
# Install NGINX Ingress Controller
#------------------------------------------------------------------------------
install_ingress_nginx() {
    log_step "Installing NGINX Ingress Controller"
    
    # Add ingress-nginx helm repo
    if helm repo list 2>/dev/null | grep -q "^ingress-nginx"; then
        log_info "Helm repo 'ingress-nginx' already added. Updating..."
        helm repo update ingress-nginx
    else
        log_info "Adding Helm repo 'ingress-nginx'..."
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    fi
    
    # Check if already installed
    if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
        log_info "NGINX Ingress Controller already installed. Skipping."
        return
    fi
    
    log_info "Installing NGINX Ingress Controller (version: $INGRESS_NGINX_VERSION)..."
    
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version "$INGRESS_NGINX_VERSION" \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=NodePort \
        --set controller.nodeSelector."ingress-ready"=true \
        --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
        --set controller.tolerations[0].operator=Exists \
        --set controller.tolerations[0].effect=NoSchedule \
        --set controller.tolerations[1].key=node-role.kubernetes.io/master \
        --set controller.tolerations[1].operator=Exists \
        --set controller.tolerations[1].effect=NoSchedule \
        --wait \
        --timeout 3m
    
    log_success "NGINX Ingress Controller installed."
    
    # Wait for ingress controller to be ready
    log_info "Waiting for Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s
}

#------------------------------------------------------------------------------
# Setup Helm repo
#------------------------------------------------------------------------------
setup_helm_repo() {
    log_step "Setting up Argo Helm repository"
    
    if helm repo list 2>/dev/null | grep -q "^${HELM_REPO_NAME}"; then
        log_info "Helm repo '$HELM_REPO_NAME' already added. Updating..."
        helm repo update "$HELM_REPO_NAME"
    else
        log_info "Adding Helm repo '$HELM_REPO_NAME' from $HELM_REPO_URL..."
        helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"
    fi
    
    log_success "Helm repo ready."
}

#------------------------------------------------------------------------------
# Install Argo CD via Helm
#------------------------------------------------------------------------------
install_argocd() {
    log_step "Installing Argo CD via Helm"
    
    log_info "Configuration:"
    log_info "  Namespace:      $NAMESPACE"
    log_info "  Release name:   $RELEASE_NAME"
    log_info "  Chart version:  $ARGOCD_CHART_VERSION"
    log_info "  Sync interval:  $ARGOCD_SYNC_INTERVAL"
    log_info "  Hostname:       $ARGOCD_HOSTNAME"
    
    # Create namespace if it doesn't exist
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Namespace '$NAMESPACE' already exists."
    else
        log_info "Creating namespace '$NAMESPACE'..."
        kubectl create namespace "$NAMESPACE"
    fi
    
    # Check if release already exists
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_info "Helm release '$RELEASE_NAME' already exists. Upgrading..."
    else
        log_info "Installing new Helm release '$RELEASE_NAME'..."
    fi
    
    # Install or upgrade Argo CD with Ingress and custom sync interval
    helm upgrade --install "$RELEASE_NAME" "$HELM_REPO_NAME/argo-cd" \
        --namespace "$NAMESPACE" \
        --version "$ARGOCD_CHART_VERSION" \
        --set "configs.cm.timeout\.reconciliation=$ARGOCD_SYNC_INTERVAL" \
        --set server.ingress.enabled=true \
        --set server.ingress.ingressClassName=nginx \
        --set server.ingress.hosts[0]="$ARGOCD_HOSTNAME" \
        --set server.ingress.tls[0].hosts[0]="$ARGOCD_HOSTNAME" \
        --set server.ingress.tls[0].secretName=argocd-server-tls \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/ssl-passthrough"=true \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/backend-protocol"=HTTPS \
        --set server.extraArgs[0]="--insecure" \
        --wait \
        --timeout 5m
    
    log_success "Argo CD Helm release installed/upgraded."
    
    # Print installed versions
    log_info "Installed Helm release info:"
    helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" -o table
}

#------------------------------------------------------------------------------
# Wait for Argo CD to be ready
#------------------------------------------------------------------------------
wait_for_argocd() {
    log_step "Waiting for Argo CD to be ready"
    
    local deployments=(
        "argocd-server"
        "argocd-repo-server"
        "argocd-redis"
        "argocd-dex-server"
        "argocd-notifications-controller"
        "argocd-applicationset-controller"
    )
    
    for deploy in "${deployments[@]}"; do
        # Check if deployment exists (some may be named differently based on release name)
        local full_name="${RELEASE_NAME}-${deploy#argocd-}"
        if [[ "$deploy" == "argocd-server" ]]; then
            full_name="${RELEASE_NAME}-server"
        elif [[ "$deploy" == "argocd-repo-server" ]]; then
            full_name="${RELEASE_NAME}-repo-server"
        elif [[ "$deploy" == "argocd-redis" ]]; then
            full_name="${RELEASE_NAME}-redis"
        elif [[ "$deploy" == "argocd-dex-server" ]]; then
            full_name="${RELEASE_NAME}-dex-server"
        elif [[ "$deploy" == "argocd-notifications-controller" ]]; then
            full_name="${RELEASE_NAME}-notifications-controller"
        elif [[ "$deploy" == "argocd-applicationset-controller" ]]; then
            full_name="${RELEASE_NAME}-applicationset-controller"
        fi
        
        if kubectl get deployment "$full_name" -n "$NAMESPACE" &>/dev/null; then
            log_info "Waiting for deployment: $full_name..."
            kubectl rollout status deployment/"$full_name" -n "$NAMESPACE" --timeout=120s
        fi
    done
    
    # Wait for application-controller (statefulset)
    local controller_name="${RELEASE_NAME}-application-controller"
    if kubectl get statefulset "$controller_name" -n "$NAMESPACE" &>/dev/null; then
        log_info "Waiting for statefulset: $controller_name..."
        kubectl rollout status statefulset/"$controller_name" -n "$NAMESPACE" --timeout=120s
    fi
    
    log_success "All Argo CD components are ready!"
}

#------------------------------------------------------------------------------
# Example Application YAML
#------------------------------------------------------------------------------
print_example_application() {
    log_step "Example Application YAML"
    
    cat <<EOF
# Example Argo CD Application (Guestbook)
# Save this as guestbook-app.yaml and apply with: kubectl apply -f guestbook-app.yaml

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook-example
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
}

#------------------------------------------------------------------------------
# Apply example Application
#------------------------------------------------------------------------------
apply_example_application() {
    log_step "Applying example Application"
    
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook-example
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
    
    log_success "Example 'guestbook' Application created!"
    log_info "Check status with: kubectl get applications -n argocd"
}

#------------------------------------------------------------------------------
# Print access instructions
#------------------------------------------------------------------------------
print_access_instructions() {
    log_step "Access Instructions"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ARGO CD IS READY!                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Argo CD URL (via Ingress):${NC}"
    echo "  https://${ARGOCD_HOSTNAME}"
    echo ""
    echo -e "${YELLOW}NOTE:${NC} If '${ARGOCD_HOSTNAME}' doesn't resolve, add to /etc/hosts:"
    echo -e "    ${YELLOW}echo '127.0.0.1 ${ARGOCD_HOSTNAME}' | sudo tee -a /etc/hosts${NC}"
    echo ""
    echo -e "${CYAN}Login Credentials:${NC}"
    echo "  Username: admin"
    echo "  Password: Run the following command to retrieve it:"
    echo ""
    echo -e "    ${YELLOW}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo${NC}"
    echo ""
    echo -e "${CYAN}Alternative Access (Port-Forward):${NC}"
    echo -e "    ${YELLOW}kubectl -n argocd port-forward svc/${RELEASE_NAME}-server 8080:443${NC}"
    echo "    Then access: https://localhost:8080"
    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo "  Sync Interval: $ARGOCD_SYNC_INTERVAL"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  # List all Argo CD Applications"
    echo "  kubectl get applications -n argocd"
    echo ""
    echo "  # Get Argo CD server logs"
    echo "  kubectl logs -n argocd -l app.kubernetes.io/name=${RELEASE_NAME}-server -f"
    echo ""
    echo "  # Check Ingress status"
    echo "  kubectl get ingress -n argocd"
    echo ""
    echo "  # Delete the sandbox cluster"
    echo "  DELETE=true $0"
    echo ""
    
    # Print helm release info
    echo -e "${CYAN}Installed Versions:${NC}"
    local chart_info
    chart_info=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" -o json 2>/dev/null)
    if command -v jq &>/dev/null && [[ -n "$chart_info" ]]; then
        local chart_version app_version
        chart_version=$(echo "$chart_info" | jq -r '.[0].chart' 2>/dev/null || echo "N/A")
        app_version=$(echo "$chart_info" | jq -r '.[0].app_version' 2>/dev/null || echo "N/A")
        echo "  Chart:       $chart_version"
        echo "  App Version: $app_version"
    else
        helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$"
    fi
    echo ""
}

#------------------------------------------------------------------------------
# Run port-forward
#------------------------------------------------------------------------------
run_port_forward() {
    log_step "Starting port-forward"
    
    log_info "Starting port-forward to Argo CD server on https://localhost:8080..."
    kubectl -n "$NAMESPACE" port-forward "svc/${RELEASE_NAME}-server" 8080:443 &
    PF_PID=$!
    
    sleep 2
    
    if kill -0 "$PF_PID" 2>/dev/null; then
        log_success "Port-forward running (PID: $PF_PID)"
        log_info "Access Argo CD at: https://localhost:8080"
        log_info "Press Ctrl+C to stop."
        echo ""
        wait "$PF_PID"
    else
        log_error "Port-forward failed to start."
        PF_PID=""
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           ARGO CD KIND SANDBOX - HELM INSTALLATION               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check dependencies first
    check_dependencies
    
    # Handle DELETE mode
    if [[ "$DELETE" == "true" ]]; then
        delete_cluster
    fi
    
    # Main installation flow
    ensure_kind_cluster
    install_ingress_nginx
    setup_helm_repo
    install_argocd
    wait_for_argocd
    
    # Print example application YAML
    print_example_application
    
    # Apply example if requested
    if [[ "$APPLY_EXAMPLE" == "true" ]]; then
        apply_example_application
    fi
    
    # Print access instructions
    print_access_instructions
    
    # Run port-forward if requested
    if [[ "$PORT_FORWARD" == "true" ]]; then
        run_port_forward
    fi
    
    log_success "Setup complete!"
}

main "$@"
