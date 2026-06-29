#!/bin/bash

set -e  # Exit immediately on any error

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION — must match cfn-setup.sh
# ─────────────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="hello-world-cluster"
ECR_REPO="eks-hello-world"

# CloudFormation stack names — must match cfn-setup.sh
STACK_ECR="hello-world-ecr"
STACK_VPC="hello-world-vpc"
STACK_IAM="hello-world-iam"
STACK_EKS="hello-world-eks"

# ─────────────────────────────────────────────────────────────────────────────
#  COLORS & HELPERS
# ─────────────────────────────────────────────────────────────────────────────
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
divider() { echo -e "${BOLD}────────────────────────────────────────────────────────────${RESET}"; }

# Wait for a CloudFormation stack to be fully deleted.
# Usage: wait_for_delete <stack-name>
wait_for_delete() {
  local STACK_NAME="$1"
  local ATTEMPTS=0
  local MAX_ATTEMPTS=80  # 80 x 15s = 20 minutes max

  warn "Waiting for stack '$STACK_NAME' to be deleted — polling every 15 seconds..."
  while true; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -gt $MAX_ATTEMPTS ]; then
      error "Timed out waiting for stack '$STACK_NAME' to delete. Check the AWS Console."
    fi

    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>/dev/null || echo "DELETE_COMPLETE")

    case "$STATUS" in
      DELETE_COMPLETE)
        success "Stack '$STACK_NAME' has been fully deleted."
        return 0
        ;;
      DELETE_FAILED)
        error "Stack '$STACK_NAME' deletion FAILED. Check the AWS Console Events tab for the root cause."
        ;;
      *)
        echo -ne "  ${YELLOW}Stack status: ${BOLD}$STATUS${RESET}${YELLOW} — attempt $ATTEMPTS/$MAX_ATTEMPTS${RESET}\r"
        sleep 15
        ;;
    esac
  done
}

# Delete a CloudFormation stack if it exists. Skip gracefully if already gone.
# Usage: delete_stack <stack-name>
delete_stack() {
  local STACK_NAME="$1"

  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
    warn "Stack '$STACK_NAME' does not exist — skipping."
    return 0
  fi

  info "Deleting stack '$STACK_NAME' (current status: $STACK_STATUS)..."
  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION"

  wait_for_delete "$STACK_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${RED}"
echo "  ██████╗ ███████╗███████╗████████╗██████╗  ██████╗ ██╗   ██╗"
echo "  ██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗ ██╔╝"
echo "  ██║  ██║█████╗  ███████╗   ██║   ██████╔╝██║   ██║ ╚████╔╝ "
echo "  ██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██╗██║   ██║  ╚██╔╝  "
echo "  ██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╔╝   ██║   "
echo "  ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝    ╚═╝   "
echo -e "${RESET}"
echo -e "${BOLD}  EKS Hello World — CloudFormation Destroy Script${RESET}"
echo -e "  Region: ${CYAN}$AWS_REGION${RESET} | Cluster: ${CYAN}$CLUSTER_NAME${RESET}"
divider
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIRMATION PROMPT
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${RED}${BOLD}  ⚠️  WARNING: This will permanently destroy the following CloudFormation stacks:${RESET}"
echo ""
echo -e "     ${BOLD}Stack                   What it contains${RESET}"
echo -e "     $STACK_EKS     EKS cluster, node group"
echo -e "     $STACK_IAM     IAM roles for EKS and node group"
echo -e "     $STACK_VPC     VPC, subnets, NAT Gateway, route tables"
echo -e "     $STACK_ECR      ECR repository and all Docker images"
echo ""
echo -e "  ${RED}This also removes the AWS Load Balancer and all running pods.${RESET}"
echo -e "  ${RED}This action cannot be undone.${RESET}"
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
info "Starting teardown of all CloudFormation stacks..."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  VERIFY AWS CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
divider
info "Verifying AWS credentials..."
divider
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials not configured or expired. Run 'aws configure' first."
success "AWS credentials valid — Account ID: $AWS_ACCOUNT_ID"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1: DELETE KUBERNETES RESOURCES
#  (Must be done before deleting the EKS CFN stack so the ELB is removed first)
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 1/5 — Deleting Kubernetes resources..."
info "The LoadBalancer Service must be removed first so AWS de-provisions"
info "the ELB before we tear down the VPC. Skipping this step causes VPC"
info "deletion to fail due to the ELB still referencing its subnets."
divider

# Only attempt kubectl if the cluster still exists
CLUSTER_STATUS=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$CLUSTER_STATUS" = "NOT_FOUND" ]; then
  warn "EKS cluster '$CLUSTER_NAME' not found — skipping kubectl cleanup."
else
  info "Updating kubeconfig to connect to '$CLUSTER_NAME'..."
  aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" 2>/dev/null || true

  if kubectl cluster-info &>/dev/null 2>&1; then

    if kubectl get service hello-world-service &>/dev/null 2>&1; then
      info "Deleting LoadBalancer Service (this triggers ELB de-provisioning)..."
      kubectl delete service hello-world-service
      warn "Pausing 45 seconds to allow the ELB to fully de-register before VPC teardown..."
      for i in $(seq 45 -1 1); do
        echo -ne "  ${YELLOW}Waiting for ELB de-registration... ${i}s remaining${RESET}\r"
        sleep 1
      done
      echo ""
      success "LoadBalancer Service deleted."
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
    warn "Could not connect to cluster via kubectl — skipping Kubernetes resource cleanup."
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 2: DELETE EKS STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 2/5 — Deleting EKS CloudFormation stack ('$STACK_EKS')..."
info "Removes the EKS cluster control plane and managed node group."
warn "This typically takes 10–15 minutes."
divider

delete_stack "$STACK_EKS"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3: DELETE IAM STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 3/5 — Deleting IAM CloudFormation stack ('$STACK_IAM')..."
info "Removes the EKS cluster role and node group instance role."
divider

delete_stack "$STACK_IAM"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4: DELETE VPC STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 4/5 — Deleting VPC CloudFormation stack ('$STACK_VPC')..."
info "Removes the VPC, subnets, NAT Gateway, Internet Gateway, and route tables."
warn "NAT Gateway deletion can take a few minutes..."
divider

delete_stack "$STACK_VPC"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5: EMPTY AND DELETE ECR STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 5/5 — Deleting ECR CloudFormation stack ('$STACK_ECR')..."
info "CloudFormation cannot delete an ECR repo that still contains images."
info "Emptying the repository first before deleting the stack..."
divider

# Check if the ECR repo exists and has images before trying to delete them
ECR_EXISTS=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$AWS_REGION" \
  --query 'repositories[0].repositoryName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$ECR_EXISTS" != "NOT_FOUND" ]; then
  IMAGE_IDS=$(aws ecr list-images \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")

  if [ "$IMAGE_IDS" != "[]" ] && [ -n "$IMAGE_IDS" ]; then
    info "Deleting all images from ECR repository '$ECR_REPO'..."
    aws ecr batch-delete-image \
      --repository-name "$ECR_REPO" \
      --region "$AWS_REGION" \
      --image-ids "$IMAGE_IDS" \
      --output text > /dev/null
    success "All images removed from ECR repository."
  else
    info "ECR repository '$ECR_REPO' is already empty."
  fi
else
  warn "ECR repository '$ECR_REPO' not found — may already be deleted."
fi

delete_stack "$STACK_ECR"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  COMPLETE!
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${GREEN}${BOLD}"
echo "  ✅  TEARDOWN COMPLETE!"
echo -e "${RESET}"
echo -e "  All CloudFormation stacks and AWS resources have been destroyed:"
echo ""
echo -e "  ${GREEN}✓${RESET} $STACK_EKS — EKS cluster and node group deleted"
echo -e "  ${GREEN}✓${RESET} $STACK_IAM — IAM roles deleted"
echo -e "  ${GREEN}✓${RESET} $STACK_VPC — VPC and all networking deleted"
echo -e "  ${GREEN}✓${RESET} $STACK_ECR  — ECR repository and all images deleted"
echo ""
echo -e "  ${BOLD}No ongoing AWS charges remain from this setup.${RESET}"
echo ""
echo -e "  To rebuild everything from scratch, run:"
echo -e "  ${CYAN}  ./cfn-setup.sh${RESET}"
divider
echo ""
