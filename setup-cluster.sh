#!/bin/bash

set -e  # Exit immediately on any error

# ─────────────────────────────────────────────
#  CONFIGURATION — edit these as needed
# ─────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="hello-world-cluster"
ECR_REPO="eks-hello-world"
NODE_TYPE="t3.medium"
NODE_COUNT=2
REPLICAS=10

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
echo -e "${BOLD}${CYAN}"
echo "  ███████╗██╗  ██╗███████╗    ██╗  ██╗███████╗██╗     ██╗      ██████╗ "
echo "  ██╔════╝██║ ██╔╝██╔════╝    ██║  ██║██╔════╝██║     ██║     ██╔═══██╗"
echo "  █████╗  █████╔╝ ███████╗    ███████║█████╗  ██║     ██║     ██║   ██║"
echo "  ██╔══╝  ██╔═██╗ ╚════██║    ██╔══██║██╔══╝  ██║     ██║     ██║   ██║"
echo "  ███████╗██║  ██╗███████║    ██║  ██║███████╗███████╗███████╗╚██████╔╝"
echo "  ╚══════╝╚═╝  ╚═╝╚══════╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝ ╚═════╝ "
echo -e "${RESET}"
echo -e "${BOLD}  EKS Hello World — Cluster Setup Script${RESET}"
echo -e "  Region: ${CYAN}$AWS_REGION${RESET} | Cluster: ${CYAN}$CLUSTER_NAME${RESET} | Pods: ${CYAN}$REPLICAS${RESET}"
divider
echo ""

# ─────────────────────────────────────────────
#  STEP 1: VERIFY PREREQUISITES
# ─────────────────────────────────────────────
divider
info "STEP 1/7 — Verifying prerequisites..."
divider

for cmd in aws eksctl kubectl docker; do
  if command -v $cmd &> /dev/null; then
    success "$cmd is installed ($(command -v $cmd))"
  else
    error "$cmd is not installed or not in PATH. Please install it and re-run."
  fi
done

info "Verifying AWS credentials..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials are not configured. Run 'aws configure' first."
success "AWS credentials valid — Account ID: $AWS_ACCOUNT_ID"
echo ""

# ─────────────────────────────────────────────
#  STEP 2: CREATE PROJECT FILES
# ─────────────────────────────────────────────
divider
info "STEP 2/7 — Creating application source files..."
divider

mkdir -p eks-hello-world/k8s
cd eks-hello-world

info "Writing app.js..."
cat > app.js << 'APPEOF'
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
  // Fallback: pick theme by hashing the pod name
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

info "Writing package.json..."
cat > package.json << 'PKGEOF'
{
  "name": "eks-hello-world",
  "version": "1.0.0",
  "main": "app.js",
  "scripts": { "start": "node app.js" },
  "dependencies": { "express": "^4.18.2" }
}
PKGEOF

info "Writing Dockerfile..."
cat > Dockerfile << 'DEOF'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --production
COPY app.js .
EXPOSE 3000
CMD ["node", "app.js"]
DEOF

cat > .dockerignore << 'DIEOF'
node_modules
npm-debug.log
DIEOF

success "Application source files created."
echo ""

# ─────────────────────────────────────────────
#  STEP 3: CREATE ECR REPO & PUSH IMAGE
# ─────────────────────────────────────────────
divider
info "STEP 3/7 — Building and pushing Docker image to ECR..."
divider

info "Creating ECR repository '$ECR_REPO' (skipping if it already exists)..."
aws ecr create-repository \
  --repository-name $ECR_REPO \
  --region $AWS_REGION 2>/dev/null || warn "ECR repository already exists — continuing."

info "Authenticating Docker with ECR..."
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS \
  --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
success "Docker authenticated with ECR."

info "Building Docker image (this may take a minute)..."
docker build -t $ECR_REPO .
success "Docker image built."

info "Tagging and pushing image to ECR..."
docker tag $ECR_REPO:latest \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
docker push \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
success "Image pushed to ECR: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest"
echo ""

# ─────────────────────────────────────────────
#  STEP 4: CREATE EKS CLUSTER
# ─────────────────────────────────────────────
divider
info "STEP 4/7 — Creating EKS cluster '$CLUSTER_NAME'..."
info "This typically takes 15–20 minutes. Please be patient."
divider
warn "Provisioning VPC, subnets, IAM roles, and EKS control plane..."

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --nodegroup-name standard-workers \
  --node-type $NODE_TYPE \
  --nodes $NODE_COUNT \
  --nodes-min $NODE_COUNT \
  --nodes-max 3 \
  --managed

success "EKS cluster '$CLUSTER_NAME' is up and running!"
echo ""

info "Verifying cluster nodes are Ready..."
kubectl get nodes
echo ""

# ─────────────────────────────────────────────
#  STEP 5: WRITE KUBERNETES MANIFESTS
# ─────────────────────────────────────────────
divider
info "STEP 5/7 — Writing Kubernetes manifests..."
divider

info "Writing k8s/deployment.yaml..."
cat > k8s/deployment.yaml << EOF
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
          image: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
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

info "Writing k8s/service.yaml..."
cat > k8s/service.yaml << 'EOF'
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

success "Kubernetes manifests written."
echo ""

# ─────────────────────────────────────────────
#  STEP 6: DEPLOY TO EKS
# ─────────────────────────────────────────────
divider
info "STEP 6/7 — Deploying application to EKS..."
divider

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
success "Deployment and Service applied to cluster."

echo ""
warn "Waiting for all $REPLICAS pods to reach Running state..."
echo -e "  ${YELLOW}(This usually takes 1–2 minutes)${RESET}"
echo ""

# Wait for rollout to complete
kubectl rollout status deployment/hello-world --timeout=300s
success "All pods are running!"

echo ""
kubectl get pods
echo ""

# ─────────────────────────────────────────────
#  STEP 7: WAIT FOR LOAD BALANCER
# ─────────────────────────────────────────────
divider
info "STEP 7/7 — Waiting for AWS Load Balancer to be provisioned..."
divider
warn "AWS is provisioning your Classic Load Balancer. This can take 2–5 minutes..."
echo ""

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
    echo -ne "  ${YELLOW}Still waiting... (attempt $ATTEMPTS/$MAX_ATTEMPTS)${RESET}\r"
    sleep 15
  fi
done

echo ""
echo ""

# ─────────────────────────────────────────────
#  COMPLETE!
# ─────────────────────────────────────────────
divider
echo -e "${GREEN}${BOLD}"
echo "  ✅  SETUP COMPLETE!"
echo -e "${RESET}"
echo -e "  Your load-balanced EKS Hello World cluster is ready."
echo ""
echo -e "  ${BOLD}Load Balancer URL:${RESET}"
echo -e "  ${CYAN}${BOLD}  http://$LB_HOSTNAME${RESET}"
echo ""
echo -e "  ${BOLD}Tips:${RESET}"
echo -e "  • Open the URL above in your browser"
echo -e "  • Refresh the page repeatedly to be routed to different pods"
echo -e "  • Each pod has a unique theme (Phoenix 🔥, Nebula 🌌, Falcon 🦅, etc.)"
echo -e "  • Run ${YELLOW}kubectl get pods${RESET} to see all $REPLICAS running pods"
echo -e "  • Run ${YELLOW}kubectl get service hello-world-service${RESET} to see the LB details"
echo ""
echo -e "  ${BOLD}To tear everything down, run:${RESET}"
echo -e "  ${YELLOW}  ./destroy-cluster.sh${RESET}"
divider
echo ""
