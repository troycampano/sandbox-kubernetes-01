#!/bin/bash

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
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}    $1"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $1"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${RESET} $1"; }
divider() { echo -e "${BOLD}────────────────────────────────────────────────────────────${RESET}"; }

# Prints a colored stack status line.
# Usage: print_stack_status <stack-name> <description>
print_stack_status() {
  local STACK_NAME="$1"
  local DESCRIPTION="$2"

  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  local STATUS_COLOR="$RESET"
  local ICON="  "
  case "$STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      STATUS_COLOR="$GREEN"; ICON="${GREEN}${BOLD}✓${RESET}" ;;
    NOT_FOUND|DELETE_COMPLETE)
      STATUS_COLOR="$YELLOW"; ICON="${YELLOW}${BOLD}–${RESET}"; STATUS="NOT DEPLOYED" ;;
    *FAILED*|*ROLLBACK*)
      STATUS_COLOR="$RED"; ICON="${RED}${BOLD}✗${RESET}" ;;
    *IN_PROGRESS*)
      STATUS_COLOR="$YELLOW"; ICON="${YELLOW}${BOLD}…${RESET}" ;;
    *)
      STATUS_COLOR="$YELLOW"; ICON="${YELLOW}${BOLD}?${RESET}" ;;
  esac

  printf "  %b  %-28s %b%-35s%b %s\n" \
    "$ICON" "$STACK_NAME" "$STATUS_COLOR${BOLD}" "$STATUS" "$RESET" "$DESCRIPTION"
}

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ███████╗████████╗ █████╗ ████████╗██╗   ██╗███████╗"
echo "  ██╔════╝╚══██╔══╝██╔══██╗╚══██╔══╝██║   ██║██╔════╝"
echo "  ███████╗   ██║   ███████║   ██║   ██║   ██║███████╗"
echo "  ╚════██║   ██║   ██╔══██║   ██║   ██║   ██║╚════██║"
echo "  ███████║   ██║   ██║  ██║   ██║   ╚██████╔╝███████║"
echo "  ╚══════╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝"
echo -e "${RESET}"
echo -e "${BOLD}  EKS Hello World — CloudFormation Status Script${RESET}"
echo -e "  Region: ${CYAN}$AWS_REGION${RESET} | Cluster: ${CYAN}$CLUSTER_NAME${RESET}"
divider
echo ""

# Track overall health for the summary
OVERALL_OK=true

# ─────────────────────────────────────────────────────────────────────────────
#  VERIFY AWS CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
info "Verifying AWS credentials..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [ -z "$AWS_ACCOUNT_ID" ]; then
  error "AWS credentials not configured or expired. Run 'aws configure' first."
  echo ""
  exit 1
fi
success "AWS credentials valid — Account ID: $AWS_ACCOUNT_ID"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  CLOUDFORMATION STACK STATUS
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${BOLD}  CloudFormation Stacks${RESET}"
divider
printf "  ${BOLD}%-30s %-35s %s${RESET}\n" "Stack Name" "Status" "Description"
printf "  %-30s %-35s %s\n"               "──────────────────────────────" "───────────────────────────────────" "───────────────────────────"

print_stack_status "$STACK_ECR" "ECR container registry"
print_stack_status "$STACK_VPC" "VPC and networking"
print_stack_status "$STACK_IAM" "IAM roles"
print_stack_status "$STACK_EKS" "EKS cluster and node group"
echo ""

# Determine if EKS stack is deployed and healthy
EKS_STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_EKS" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$EKS_STACK_STATUS" != "CREATE_COMPLETE" && "$EKS_STACK_STATUS" != "UPDATE_COMPLETE" ]]; then
  if [[ "$EKS_STACK_STATUS" == "NOT_FOUND" || "$EKS_STACK_STATUS" == "DELETE_COMPLETE" ]]; then
    warn "EKS stack is not deployed — cluster, pod, and URL status unavailable."
  else
    warn "EKS stack status is '$EKS_STACK_STATUS' — cluster may not be fully ready."
    OVERALL_OK=false
  fi
  echo ""
else
  # ─────────────────────────────────────────────────────────────────────────
  #  EKS CLUSTER STATUS
  # ─────────────────────────────────────────────────────────────────────────
  divider
  echo -e "${BOLD}  EKS Cluster${RESET}"
  divider

  CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  CLUSTER_VERSION=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text 2>/dev/null || echo "—")

  CLUSTER_ENDPOINT=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.endpoint' \
    --output text 2>/dev/null || echo "—")

  if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    success "Cluster '$CLUSTER_NAME' is ${GREEN}${BOLD}ACTIVE${RESET}"
  elif [ "$CLUSTER_STATUS" = "NOT_FOUND" ]; then
    warn "Cluster '$CLUSTER_NAME' not found."
    OVERALL_OK=false
  else
    warn "Cluster '$CLUSTER_NAME' status: ${YELLOW}${BOLD}$CLUSTER_STATUS${RESET}"
    OVERALL_OK=false
  fi

  echo -e "  ${BOLD}Version:${RESET}  $CLUSTER_VERSION"
  echo -e "  ${BOLD}Endpoint:${RESET} $CLUSTER_ENDPOINT"
  echo ""

  # ─────────────────────────────────────────────────────────────────────────
  #  KUBECTL — NODES & PODS
  # ─────────────────────────────────────────────────────────────────────────
  divider
  echo -e "${BOLD}  Nodes${RESET}"
  divider

  # Update kubeconfig silently
  aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" &>/dev/null 2>&1 || true

  if kubectl cluster-info &>/dev/null 2>&1; then

    NODE_OUTPUT=$(kubectl get nodes --no-headers 2>/dev/null || true)
    if [ -n "$NODE_OUTPUT" ]; then
      TOTAL_NODES=$(echo "$NODE_OUTPUT" | wc -l | tr -d ' ')
      READY_NODES=$(echo "$NODE_OUTPUT" | grep -c " Ready " || true)
      echo -e "  Nodes ready: ${GREEN}${BOLD}$READY_NODES${RESET} / ${BOLD}$TOTAL_NODES${RESET}"
      echo ""
      kubectl get nodes 2>/dev/null || true
    else
      warn "No nodes found."
      OVERALL_OK=false
    fi
    echo ""

    divider
    echo -e "${BOLD}  Pods (hello-world deployment)${RESET}"
    divider

    POD_OUTPUT=$(kubectl get pods -l app=hello-world --no-headers 2>/dev/null || true)
    if [ -n "$POD_OUTPUT" ]; then
      TOTAL_PODS=$(echo "$POD_OUTPUT" | wc -l | tr -d ' ')
      RUNNING_PODS=$(echo "$POD_OUTPUT" | grep -c "Running" || true)
      echo -e "  Pods running: ${GREEN}${BOLD}$RUNNING_PODS${RESET} / ${BOLD}$TOTAL_PODS${RESET}"
      echo ""
      kubectl get pods -l app=hello-world 2>/dev/null || true
      if [ "$RUNNING_PODS" -lt "$TOTAL_PODS" ]; then
        OVERALL_OK=false
      fi
    else
      warn "No pods found for 'hello-world' deployment."
      OVERALL_OK=false
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    #  LOAD BALANCER URL
    # ───────────────────────────────────────────────────────────────────────
    divider
    echo -e "${BOLD}  Load Balancer${RESET}"
    divider

    LB_HOSTNAME=$(kubectl get service hello-world-service \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

    SVC_STATUS=$(kubectl get service hello-world-service --no-headers 2>/dev/null | awk '{print $5}' || true)

    if [ -n "$LB_HOSTNAME" ]; then
      success "Load Balancer is provisioned"
      echo -e "  ${BOLD}URL:${RESET}    ${CYAN}${BOLD}http://$LB_HOSTNAME${RESET}"
      echo -e "  ${BOLD}Ports:${RESET}  $SVC_STATUS"
    else
      SVC_EXISTS=$(kubectl get service hello-world-service --no-headers 2>/dev/null || true)
      if [ -n "$SVC_EXISTS" ]; then
        warn "Load Balancer service exists but hostname is not yet assigned (still provisioning)."
        OVERALL_OK=false
      else
        warn "Service 'hello-world-service' not found — load balancer not deployed."
        OVERALL_OK=false
      fi
    fi
    echo ""

  else
    warn "Cannot connect to cluster via kubectl — node and pod status unavailable."
    OVERALL_OK=false
    echo ""
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  ECR IMAGE STATUS
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${BOLD}  ECR Repository${RESET}"
divider

ECR_EXISTS=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$AWS_REGION" \
  --query 'repositories[0].repositoryName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$ECR_EXISTS" != "NOT_FOUND" ]; then
  ECR_URI=$(aws ecr describe-repositories \
    --repository-names "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || echo "—")

  IMAGE_COUNT=$(aws ecr list-images \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'length(imageIds)' \
    --output text 2>/dev/null || echo "0")

  LATEST_PUSHED=$(aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'sort_by(imageDetails, &imagePushedAt)[-1].imagePushedAt' \
    --output text 2>/dev/null || echo "—")

  success "Repository '$ECR_REPO' exists"
  echo -e "  ${BOLD}URI:${RESET}          $ECR_URI"
  echo -e "  ${BOLD}Images stored:${RESET} $IMAGE_COUNT"
  echo -e "  ${BOLD}Last pushed:${RESET}   $LATEST_PUSHED"
else
  warn "ECR repository '$ECR_REPO' not found."
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  OVERALL STATUS SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
divider
if [ "$OVERALL_OK" = true ]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ✅  OVERALL STATUS: HEALTHY"
  echo -e "${RESET}"
  echo -e "  All CloudFormation stacks are deployed and the cluster is running."
  if [ -n "$LB_HOSTNAME" ]; then
    echo ""
    echo -e "  ${BOLD}Access your app at:${RESET}"
    echo -e "  ${CYAN}${BOLD}  http://$LB_HOSTNAME${RESET}"
  fi
else
  echo -e "${YELLOW}${BOLD}"
  echo "  ⚠️   OVERALL STATUS: DEGRADED OR NOT DEPLOYED"
  echo -e "${RESET}"
  echo -e "  One or more components are missing, not ready, or in an error state."
  echo -e "  Review the details above for specifics."
  echo ""
  echo -e "  ${BOLD}To deploy everything from scratch, run:${RESET}"
  echo -e "  ${CYAN}  ./cfn-setup.sh${RESET}"
fi
echo ""
echo -e "  ${BOLD}Other useful commands:${RESET}"
echo -e "  • ${YELLOW}kubectl get pods${RESET}                        — live pod list"
echo -e "  • ${YELLOW}kubectl get service hello-world-service${RESET} — LB details"
echo -e "  • ${YELLOW}kubectl describe pod <name>${RESET}             — pod diagnostics"
echo -e "  • ${YELLOW}./cfn-destroy.sh${RESET}                        — tear everything down"
divider
echo ""
