#!/bin/bash

set -e  # Exit immediately on any error

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION — edit these as needed
# ─────────────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="hello-world-cluster"
ECR_REPO="eks-hello-world"
REPLICAS=10

# CloudFormation stack names
STACK_ECR="hello-world-ecr"
STACK_VPC="hello-world-vpc"
STACK_IAM="hello-world-iam"
STACK_EKS="hello-world-eks"

# CloudFormation template paths (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFN_ECR="$SCRIPT_DIR/cfn-ecr.yaml"
CFN_VPC="$SCRIPT_DIR/cfn-vpc.yaml"
CFN_IAM="$SCRIPT_DIR/cfn-iam.yaml"
CFN_EKS="$SCRIPT_DIR/cfn-eks.yaml"

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

# Wait for a CloudFormation stack to reach a target status.
# Usage: wait_for_stack <stack-name> <action-label>
wait_for_stack() {
  local STACK_NAME="$1"
  local LABEL="$2"
  local ATTEMPTS=0
  local MAX_ATTEMPTS=80  # 80 x 15s = 20 minutes max

  warn "$LABEL — polling every 15 seconds (up to 20 min)..."
  while true; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -gt $MAX_ATTEMPTS ]; then
      error "Timed out waiting for stack '$STACK_NAME'. Check the AWS Console for details."
    fi

    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>/dev/null || echo "UNKNOWN")

    case "$STATUS" in
      *_COMPLETE)
        if [[ "$STATUS" == *"ROLLBACK"* ]]; then
          show_stack_failure_reason "$STACK_NAME"
          error "Stack '$STACK_NAME' failed with status: $STATUS."
        fi
        success "Stack '$STACK_NAME' reached status: $STATUS"
        return 0
        ;;
      *_FAILED|*ROLLBACK*)
        show_stack_failure_reason "$STACK_NAME"
        error "Stack '$STACK_NAME' failed with status: $STATUS."
        ;;
      *)
        echo -ne "  ${YELLOW}Stack status: ${BOLD}$STATUS${RESET}${YELLOW} — attempt $ATTEMPTS/$MAX_ATTEMPTS${RESET}\r"
        sleep 15
        ;;
    esac
  done
}

# Deploy or update a CloudFormation stack.
# Usage: deploy_stack <stack-name> <template-file> [param1=val1 param2=val2 ...]
deploy_stack() {
  local STACK_NAME="$1"
  local TEMPLATE="$2"
  shift 2
  local PARAMS=("$@")

  if [ ! -f "$TEMPLATE" ]; then
    error "CloudFormation template not found: $TEMPLATE"
  fi

  # Build parameter overrides string
  local PARAM_ARGS=""
  for PARAM in "${PARAMS[@]}"; do
    PARAM_ARGS="$PARAM_ARGS ParameterKey=${PARAM%%=*},ParameterValue=${PARAM#*=}"
  done

  # Check if stack already exists
  STACK_EXISTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  # A ROLLBACK_COMPLETE stack cannot be updated — must delete and recreate
  if [ "$STACK_EXISTS" = "ROLLBACK_COMPLETE" ]; then
    warn "Stack '$STACK_NAME' is in ROLLBACK_COMPLETE state — deleting it before recreating..."
    aws cloudformation delete-stack \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION"
    info "Waiting for stack '$STACK_NAME' deletion to complete..."
    aws cloudformation wait stack-delete-complete \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION"
    success "Stack '$STACK_NAME' deleted — will recreate now."
    STACK_EXISTS="DOES_NOT_EXIST"
  fi

  if [ "$STACK_EXISTS" = "DOES_NOT_EXIST" ]; then
    info "Creating stack '$STACK_NAME'..."
    aws cloudformation create-stack \
      --stack-name "$STACK_NAME" \
      --template-body "file://$TEMPLATE" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$AWS_REGION" \
      ${PARAM_ARGS:+--parameters $PARAM_ARGS} \
      --output text > /dev/null
  else
    info "Stack '$STACK_NAME' already exists (status: $STACK_EXISTS) — attempting update..."
    UPDATE_OUTPUT=$(aws cloudformation update-stack \
      --stack-name "$STACK_NAME" \
      --template-body "file://$TEMPLATE" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$AWS_REGION" \
      ${PARAM_ARGS:+--parameters $PARAM_ARGS} \
      --output text 2>&1 || true)

    if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
      success "Stack '$STACK_NAME' is already up to date — no changes needed."
      return 0
    fi
  fi
}

# Fetch and display the CloudFormation events that caused a stack failure.
show_stack_failure_reason() {
  local STACK_NAME="$1"
  echo ""
  echo -e "${RED}${BOLD}  ── Failure Details for '$STACK_NAME' ──${RESET}"
  echo ""
  FAILED_EVENTS=$(aws cloudformation describe-stack-events \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
    --output table 2>/dev/null || true)
  if [ -n "$FAILED_EVENTS" ]; then
    echo "$FAILED_EVENTS"
  else
    echo -e "  ${YELLOW}No failure events found or events unavailable. Check the AWS Console.${RESET}"
  fi
  echo ""
}

# Check for CloudFormation stacks in a running or stuck state and prompt user.
check_for_active_stacks() {
  info "Checking for active or stuck CloudFormation stacks..."
  ACTIVE_STACKS=$(aws cloudformation list-stacks \
    --region "$AWS_REGION" \
    --stack-status-filter \
      CREATE_IN_PROGRESS UPDATE_IN_PROGRESS DELETE_IN_PROGRESS \
      ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_IN_PROGRESS \
      UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS \
      REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_ROLLBACK_IN_PROGRESS \
    --query 'StackSummaries[].[StackName,StackStatus]' \
    --output text 2>/dev/null || true)

  if [ -z "$ACTIVE_STACKS" ]; then
    success "No active or stuck stacks found — safe to proceed."
    return 0
  fi

  echo ""
  echo -e "${YELLOW}${BOLD}[WARN]  The following CloudFormation stacks are currently active or stuck:${RESET}"
  echo ""
  printf "  %-45s %s\n" "Stack Name" "Status"
  printf "  %-45s %s\n" "─────────────────────────────────────────────" "──────────────────────────────────"
  while IFS=$'\t' read -r NAME STATUS; do
    printf "  ${YELLOW}%-45s${RESET} %s\n" "$NAME" "$STATUS"
  done <<< "$ACTIVE_STACKS"
  echo ""
  echo -e "${YELLOW}${BOLD}[WARN]  These stacks may conflict with or block this setup.${RESET}"
  echo ""
  read -rp "  Continue anyway? [y/N]: " CONFIRM || true
  echo ""
  case "$CONFIRM" in
    [yY][eE][sS]|[yY])
      info "Continuing setup as requested..."
      ;;
    *)
      info "Setup cancelled. Resolve the above stacks and re-run."
      exit 0
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ███████╗██╗  ██╗███████╗    ██╗  ██╗███████╗██╗     ██╗      ██████╗ "
echo "  ██╔════╝██║ ██╔╝██╔════╝    ██║  ██║██╔════╝██║     ██║     ██╔═══██╗"
echo "  █████╗  █████╔╝ ███████╗    ███████║█████╗  ██║     ██║     ██║   ██║"
echo "  ██╔══╝  ██╔═██╗ ╚════██║    ██╔══██║██╔══╝  ██║     ██║     ██║   ██║"
echo "  ███████╗██║  ██╗███████║    ██║  ██║███████╗███████╗███████╗╚██████╔╝"
echo "  ╚══════╝╚═╝  ╚═╝╚══════╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝ ╚═════╝ "
echo -e "${RESET}"
echo -e "${BOLD}  EKS Hello World — CloudFormation Setup Script${RESET}"
echo -e "  Region: ${CYAN}$AWS_REGION${RESET} | Cluster: ${CYAN}$CLUSTER_NAME${RESET} | Pods: ${CYAN}$REPLICAS${RESET}"
divider
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1: VERIFY PREREQUISITES & AWS CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 1/8 — Verifying prerequisites and AWS credentials..."
divider

for cmd in aws kubectl docker; do
  if command -v $cmd &> /dev/null; then
    success "$cmd found ($(command -v $cmd))"
  else
    error "$cmd is not installed or not in PATH. Please install it and re-run."
  fi
done

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials not configured. Run 'aws configure' first."
success "AWS credentials valid — Account ID: $AWS_ACCOUNT_ID"

# Verify all CFN templates are present
for TEMPLATE in "$CFN_ECR" "$CFN_VPC" "$CFN_IAM" "$CFN_EKS"; do
  if [ -f "$TEMPLATE" ]; then
    success "Template found: $(basename $TEMPLATE)"
  else
    error "CloudFormation template missing: $TEMPLATE"
  fi
done
echo ""

check_for_active_stacks
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 2: DEPLOY ECR STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 2/8 — Deploying ECR stack ('$STACK_ECR')..."
info "This creates the Elastic Container Registry repository for Docker images."
divider

deploy_stack "$STACK_ECR" "$CFN_ECR" "RepositoryName=$ECR_REPO"
wait_for_stack "$STACK_ECR" "Waiting for ECR stack to complete"
echo ""

ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_ECR" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`RepositoryUri`].OutputValue' \
  --output text)
success "ECR Repository URI: $ECR_URI"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3: BUILD & PUSH DOCKER IMAGE
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 3/8 — Building and pushing Docker image to ECR..."
divider

# Write app source files to a temp build directory
BUILD_DIR=$(mktemp -d)
info "Writing application source files to $BUILD_DIR..."

cat > "$BUILD_DIR/app.js" << 'APPEOF'
const express = require('express');
const app = express();
const PORT = 3000;

const podName = process.env.POD_NAME || 'unknown-pod';

const themes = {
  'phoenix':  { emoji: '🔥', color: '#FF6B35', bg: '#1a0a00' },
  'nebula':   { emoji: '🌌', color: '#A855F7', bg: '#0a0014' },
  'falcon':   { emoji: '🦅', color: '#3B82F6', bg: '#00071a' },
  'titan':    { emoji: '⚡', color: '#EAB308', bg: '#1a1400' },
  'aurora':   { emoji: '🌠', color: '#10B981', bg: '#001a0e' },
  'vortex':   { emoji: '🌀', color: '#06B6D4', bg: '#001a1f' },
  'cosmos':   { emoji: '🪐', color: '#F472B6', bg: '#1a0010' },
  'shadow':   { emoji: '🐺', color: '#94A3B8', bg: '#0a0a0a' },
  'inferno':  { emoji: '🌋', color: '#EF4444', bg: '#1a0000' },
  'glacier':  { emoji: '🧊', color: '#67E8F9', bg: '#001a1a' },
};

const podNames = [
  'phoenix', 'nebula', 'falcon', 'titan', 'aurora',
  'vortex', 'cosmos', 'shadow', 'inferno', 'glacier'
];

function getTheme(name) {
  for (const key of Object.keys(themes)) {
    if (name.toLowerCase().includes(key)) return { ...themes[key], name: key };
  }
  const index = name.split('').reduce((acc, c) => acc + c.charCodeAt(0), 0) % podNames.length;
  const fallbackKey = podNames[index];
  return { ...themes[fallbackKey], name: fallbackKey };
}

app.get('/', (req, res) => {
  const theme = getTheme(podName);
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Hello from ${podName}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: ${theme.bg};
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
      font-family: 'Segoe UI', sans-serif;
    }
    .card {
      text-align: center;
      padding: 60px 80px;
      border: 2px solid ${theme.color};
      border-radius: 20px;
      box-shadow: 0 0 60px ${theme.color}44;
      max-width: 600px;
    }
    .emoji { font-size: 80px; margin-bottom: 20px; }
    h1 { color: ${theme.color}; font-size: 2.8rem; margin-bottom: 12px; }
    .pod { color: #ffffff99; font-size: 1rem; margin-top: 20px; }
    .dot { display: inline-block; width: 10px; height: 10px;
           background: ${theme.color}; border-radius: 50%; margin-right: 8px;
           animation: pulse 1.5s infinite; }
    @keyframes pulse {
      0%, 100% { opacity: 1; } 50% { opacity: 0.3; }
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="emoji">${theme.emoji}</div>
    <h1>Hello from ${theme.name.charAt(0).toUpperCase() + theme.name.slice(1)}!</h1>
    <p style="color:${theme.color}99; font-size:1.1rem; margin-top:10px;">
      You have been routed to this pod by the load balancer.
    </p>
    <p class="pod"><span class="dot"></span>Pod: <strong style="color:${theme.color}">${podName}</strong></p>
  </div>
</body>
</html>`);
});

app.get('/health', (req, res) => res.json({ status: 'ok', pod: podName }));

app.listen(PORT, () => console.log(`Running on port ${PORT} — Pod: ${podName}`));
APPEOF

cat > "$BUILD_DIR/package.json" << 'PKGEOF'
{
  "name": "eks-hello-world",
  "version": "1.0.0",
  "main": "app.js",
  "scripts": { "start": "node app.js" },
  "dependencies": { "express": "^4.18.2" }
}
PKGEOF

cat > "$BUILD_DIR/Dockerfile" << 'DEOF'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --production
COPY app.js .
EXPOSE 3000
CMD ["node", "app.js"]
DEOF

cat > "$BUILD_DIR/.dockerignore" << 'DIEOF'
node_modules
npm-debug.log
DIEOF

info "Authenticating Docker with ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS \
  --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
success "Docker authenticated with ECR."

info "Building Docker image..."
docker build -t "$ECR_REPO" "$BUILD_DIR"
success "Docker image built."

info "Tagging and pushing image to ECR..."
docker tag "$ECR_REPO:latest" "$ECR_URI:latest"
docker push "$ECR_URI:latest"
success "Image pushed to: $ECR_URI:latest"

rm -rf "$BUILD_DIR"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4: DEPLOY VPC STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 4/8 — Deploying VPC stack ('$STACK_VPC')..."
info "Creates VPC, 2 public + 2 private subnets, Internet Gateway, NAT Gateway, and route tables."
divider

deploy_stack "$STACK_VPC" "$CFN_VPC" "ClusterName=$CLUSTER_NAME"
wait_for_stack "$STACK_VPC" "Waiting for VPC stack to complete"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5: DEPLOY IAM STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 5/8 — Deploying IAM stack ('$STACK_IAM')..."
info "Creates the EKS cluster service role and EC2 node group instance role."
divider

deploy_stack "$STACK_IAM" "$CFN_IAM" "ClusterName=$CLUSTER_NAME"
wait_for_stack "$STACK_IAM" "Waiting for IAM stack to complete"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 6: DEPLOY EKS STACK
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 6/8 — Deploying EKS stack ('$STACK_EKS')..."
info "Creates the EKS control plane and managed node group."
warn "This is the longest step — typically 15–20 minutes. Please be patient."
divider

deploy_stack "$STACK_EKS" "$CFN_EKS" \
  "ClusterName=$CLUSTER_NAME" \
  "VpcStackName=$STACK_VPC" \
  "IamStackName=$STACK_IAM"
wait_for_stack "$STACK_EKS" "Waiting for EKS cluster and node group to be ready"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 7: CONFIGURE KUBECTL & DEPLOY APP
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 7/8 — Configuring kubectl and deploying the application..."
divider

info "Updating kubeconfig for cluster '$CLUSTER_NAME'..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION"
success "kubectl configured to talk to '$CLUSTER_NAME'."

info "Verifying nodes are Ready..."
kubectl get nodes
echo ""

info "Applying Kubernetes Deployment ($REPLICAS replicas)..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - name: hello-world
          image: $ECR_URI:latest
          ports:
            - containerPort: 3000
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 15
EOF

info "Applying Kubernetes LoadBalancer Service..."
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: hello-world-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "classic"
spec:
  type: LoadBalancer
  selector:
    app: hello-world
  ports:
    - protocol: TCP
      port: 80
      targetPort: 3000
EOF

echo ""
warn "Waiting for all $REPLICAS pods to reach Running state..."
kubectl rollout status deployment/hello-world --timeout=300s
success "All pods are running!"
echo ""
kubectl get pods
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 8: WAIT FOR LOAD BALANCER
# ─────────────────────────────────────────────────────────────────────────────
divider
info "STEP 8/8 — Waiting for AWS Load Balancer to be provisioned..."
info "AWS is provisioning a Classic Load Balancer for public internet access."
warn "This typically takes 2–5 minutes after the service is created..."
divider

LB_HOSTNAME=""
ATTEMPTS=0
MAX_ATTEMPTS=40  # 40 x 15s = 10 minutes max

while [ -z "$LB_HOSTNAME" ]; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ $ATTEMPTS -gt $MAX_ATTEMPTS ]; then
    error "Timed out waiting for Load Balancer. Run 'kubectl get service hello-world-service' to check manually."
  fi
  LB_HOSTNAME=$(kubectl get service hello-world-service \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -z "$LB_HOSTNAME" ]; then
    echo -ne "  ${YELLOW}Still waiting for ELB hostname... (attempt $ATTEMPTS/$MAX_ATTEMPTS)${RESET}\r"
    sleep 15
  fi
done

echo ""
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  COMPLETE!
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${GREEN}${BOLD}"
echo "  ✅  SETUP COMPLETE!"
echo -e "${RESET}"
echo -e "  Your load-balanced EKS Hello World cluster is live."
echo ""
echo -e "  ${BOLD}CloudFormation Stacks Deployed:${RESET}"
echo -e "  ${GREEN}✓${RESET} $STACK_ECR   — ECR container registry"
echo -e "  ${GREEN}✓${RESET} $STACK_VPC   — VPC and networking"
echo -e "  ${GREEN}✓${RESET} $STACK_IAM   — IAM roles"
echo -e "  ${GREEN}✓${RESET} $STACK_EKS   — EKS cluster and node group"
echo ""
echo -e "  ${BOLD}Load Balancer URL:${RESET}"
echo -e "  ${CYAN}${BOLD}  http://$LB_HOSTNAME${RESET}"
echo ""
echo -e "  ${BOLD}Tips:${RESET}"
echo -e "  • Open the URL in your browser and refresh repeatedly"
echo -e "  • Each refresh may route you to a different pod with a unique theme"
echo -e "  • Run ${YELLOW}kubectl get pods${RESET} to see all $REPLICAS running pods"
echo -e "  • Run ${YELLOW}kubectl get service hello-world-service${RESET} to see LB details"
echo -e "  • View stacks in the AWS Console under CloudFormation"
echo ""
echo -e "  ${BOLD}To tear everything down, run:${RESET}"
echo -e "  ${YELLOW}  ./cfn-destroy.sh${RESET}"
divider
echo ""
