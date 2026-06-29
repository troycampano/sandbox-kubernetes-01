#!/bin/bash

set -e  # Exit immediately on any error

# ─────────────────────────────────────────────
#  CONFIGURATION — must match setup-cluster.sh
# ─────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="hello-world-cluster"
ECR_REPO="eks-hello-world"

# ─────────────────────────────────────────────
#  COLORS & HELPERS
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $1"; }
success() { echo -e "${GREEN}${BOLD}[DONE]${RESET}  $1"; }
warn()    { echo -e "${YELLOW}${BOLD}[WAIT]${RESET}  $1"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${RESET} $1"; exit 1; }
divider() { echo -e "${BOLD}────────────────────────────────────────────────────${RESET}"; }

# ─────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────
clear
echo -e "${BOLD}${RED}"
echo "  ██████╗ ███████╗███████╗████████╗██████╗  ██████╗ ██╗   ██╗"
echo "  ██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗ ██╔╝"
echo "  ██║  ██║█████╗  ███████╗   ██║   ██████╔╝██║   ██║ ╚████╔╝ "
echo "  ██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██╗██║   ██║  ╚██╔╝  "
echo "  ██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╔╝   ██║   "
echo "  ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝    ╚═╝   "
echo -e "${RESET}"
echo -e "${BOLD}  EKS Hello World — Cluster Destroy Script${RESET}"
echo -e "  Region: ${CYAN}$AWS_REGION${RESET} | Cluster: ${CYAN}$CLUSTER_NAME${RESET} | ECR Repo: ${CYAN}$ECR_REPO${RESET}"
divider
echo ""

# ─────────────────────────────────────────────
#  CONFIRMATION PROMPT
# ─────────────────────────────────────────────
echo -e "${RED}${BOLD}  ⚠️  WARNING: This will permanently destroy:${RESET}"
echo -e "     • EKS Cluster: ${BOLD}$CLUSTER_NAME${RESET}"
echo -e "     • All running pods and Kubernetes resources"
echo -e "     • The AWS Load Balancer"
echo -e "     • ECR Repository: ${BOLD}$ECR_REPO${RESET} and all images"
echo -e "     • Associated VPC, subnets, and IAM roles created by eksctl"
echo ""
echo -ne "${YELLOW}${BOLD}  Are you sure you want to continue? Type 'yes' to confirm: ${RESET}"
read CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo ""
  echo -e "${GREEN}  Aborted. No changes were made.${RESET}"
  echo ""
  exit 0
fi

echo ""
info "Starting teardown of all resources..."
echo ""

# ─────────────────────────────────────────────
#  VERIFY AWS CREDENTIALS
# ─────────────────────────────────────────────
divider
info "Verifying AWS credentials..."
divider
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials are not configured or have expired."
success "AWS credentials valid — Account ID: $AWS_ACCOUNT_ID"
echo ""

# ─────────────────────────────────────────────
#  STEP 1: DELETE KUBERNETES RESOURCES
# ─────────────────────────────────────────────
divider
info "STEP 1/3 — Deleting Kubernetes resources (Deployment & Service)..."
divider
warn "Deleting the LoadBalancer Service will also decommission the AWS ELB..."

# Check if kubectl can reach the cluster
if kubectl cluster-info &>/dev/null; then
  # Delete service first so ELB is deprovisioned before cluster deletion
  if kubectl get service hello-world-service &>/dev/null 2>&1; then
    info "Deleting LoadBalancer service (deprovisioning AWS ELB)..."
    kubectl delete service hello-world-service
    warn "Waiting 30 seconds for ELB to fully deregister before cluster deletion..."
    for i in $(seq 30 -1 1); do
      echo -ne "  ${YELLOW}Waiting... ${i}s remaining${RESET}\r"
      sleep 1
    done
    echo ""
    success "LoadBalancer service deleted."
  else
    warn "Service 'hello-world-service' not found — may already be deleted."
  fi

  if kubectl get deployment hello-world &>/dev/null 2>&1; then
    info "Deleting Deployment..."
    kubectl delete deployment hello-world
    success "Deployment deleted."
  else
    warn "Deployment 'hello-world' not found — may already be deleted."
  fi
else
  warn "Could not connect to cluster — it may already be deleted. Skipping kubectl steps."
fi

echo ""

# ─────────────────────────────────────────────
#  STEP 2: DELETE EKS CLUSTER
# ─────────────────────────────────────────────
divider
info "STEP 2/3 — Deleting EKS cluster '$CLUSTER_NAME'..."
info "This will delete the cluster, node group, VPC, subnets, and IAM roles."
info "This typically takes 10–15 minutes. Please be patient."
divider
warn "Handing off to eksctl — do not interrupt this process..."
echo ""

if eksctl get cluster --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null 2>&1; then
  eksctl delete cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION \
    --wait
  success "EKS cluster '$CLUSTER_NAME' fully deleted."
else
  warn "Cluster '$CLUSTER_NAME' not found in region '$AWS_REGION' — may already be deleted."
fi

echo ""

# ─────────────────────────────────────────────
#  STEP 3: DELETE ECR REPOSITORY
# ─────────────────────────────────────────────
divider
info "STEP 3/3 — Deleting ECR repository '$ECR_REPO'..."
divider

if aws ecr describe-repositories --repository-names $ECR_REPO --region $AWS_REGION &>/dev/null 2>&1; then
  info "Deleting ECR repository and all images inside it..."
  aws ecr delete-repository \
    --repository-name $ECR_REPO \
    --region $AWS_REGION \
    --force
  success "ECR repository '$ECR_REPO' deleted."
else
  warn "ECR repository '$ECR_REPO' not found — may already be deleted."
fi

echo ""

# ─────────────────────────────────────────────
#  CLEAN UP LOCAL FILES (OPTIONAL)
# ─────────────────────────────────────────────
divider
info "Cleaning up local project files..."
divider

if [ -d "eks-hello-world" ]; then
  echo -ne "${YELLOW}${BOLD}  Remove local 'eks-hello-world' project folder? (yes/no): ${RESET}"
  read REMOVE_LOCAL
  if [ "$REMOVE_LOCAL" = "yes" ]; then
    rm -rf eks-hello-world
    success "Local project folder removed."
  else
    info "Local project folder kept at: $(pwd)/eks-hello-world"
  fi
else
  warn "No local 'eks-hello-world' folder found — nothing to clean up."
fi

echo ""

# ─────────────────────────────────────────────
#  COMPLETE!
# ─────────────────────────────────────────────
divider
echo -e "${GREEN}${BOLD}"
echo "  ✅  TEARDOWN COMPLETE!"
echo -e "${RESET}"
echo -e "  All AWS resources have been destroyed:"
echo -e "  ${GREEN}✓${RESET} EKS Cluster deleted"
echo -e "  ${GREEN}✓${RESET} Load Balancer deprovisioned"
echo -e "  ${GREEN}✓${RESET} Node groups and VPC removed"
echo -e "  ${GREEN}✓${RESET} ECR repository and images deleted"
echo ""
echo -e "  ${BOLD}No ongoing AWS charges remain from this setup.${RESET}"
echo ""
echo -e "  To rebuild the cluster from scratch, run:"
echo -e "  ${CYAN}  ./setup-cluster.sh${RESET}"
divider
echo ""
