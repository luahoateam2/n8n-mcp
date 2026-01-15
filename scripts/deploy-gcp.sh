#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 n8n on Google Cloud Deployer${NC}"
echo "-----------------------------------"

# Configuration
KEY_FILE="${1:-credentials.json}"
REGION="${2:-us-central1}"
ZONE="${REGION}-a"
INSTANCE_NAME="n8n-server"
SQL_INSTANCE_NAME="n8n-db-$(date +%s)" # Unique name to avoid conflicts if previously deleted
DB_USER="n8n"
DB_NAME="n8n"

# Check prerequisites
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed.${NC}"
    exit 1
fi

# Check key file
if [ ! -f "$KEY_FILE" ]; then
    echo -e "${RED}Error: Service account key file '$KEY_FILE' not found.${NC}"
    echo "Please save your Service Account JSON to 'credentials.json' or pass the path as the first argument."
    exit 1
fi

# Authenticate
echo -e "${YELLOW}Authenticating with Google Cloud...${NC}"
gcloud auth activate-service-account --key-file="$KEY_FILE" --quiet

# Get Project ID
PROJECT_ID=$(jq -r .project_id "$KEY_FILE")
echo -e "${GREEN}Project ID: ${PROJECT_ID}${NC}"
gcloud config set project "$PROJECT_ID" --quiet

# Enable APIs
echo -e "${YELLOW}Enabling required APIs...${NC}"
gcloud services enable compute.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com --quiet

# Generate Secrets
echo -e "${YELLOW}Generating secure credentials...${NC}"
DB_PASSWORD=$(openssl rand -hex 16)
N8N_PASSWORD=$(openssl rand -hex 12)
N8N_ENC_KEY=$(openssl rand -hex 16)
MCP_TOKEN=$(openssl rand -hex 32)
N8N_API_KEY=$(openssl rand -hex 32)

echo "Generated Database Password: [HIDDEN]"
echo "Generated n8n Admin Password: $N8N_PASSWORD"

# Create Cloud SQL Instance
echo -e "${YELLOW}Creating Cloud SQL Instance (PostgreSQL)...${NC}"
# Check if instance exists (skipping for now, assuming new deploy with unique name)
# Using db-f1-micro is cheapest but might be too small for heavy loads.
# Using db-custom-1-3840 (1 vCPU, 3.75GB) is safer but costs more.
# For $800 credits, we can afford standard.
gcloud sql instances create "$SQL_INSTANCE_NAME" \
    --database-version=POSTGRES_15 \
    --tier=db-custom-1-3840 \
    --region="$REGION" \
    --root-password="$DB_PASSWORD" \
    --quiet

# Get Connection Name
CONNECTION_NAME=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --format="value(connectionName)")
echo -e "${GREEN}Cloud SQL Instance created: ${CONNECTION_NAME}${NC}"

# Create Database and User
echo -e "${YELLOW}Configuring Database...${NC}"
gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME" --quiet
gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASSWORD" --quiet

# Firewall Rules
echo -e "${YELLOW}Configuring Firewall...${NC}"
if ! gcloud compute firewall-rules describe allow-n8n-ports &>/dev/null; then
    gcloud compute firewall-rules create allow-n8n-ports \
        --allow tcp:5678,tcp:3000 \
        --target-tags=n8n-server \
        --description="Allow n8n and MCP ports" \
        --quiet
else
    echo "Firewall rule 'allow-n8n-ports' already exists."
fi

# Prepare Docker Compose content
# Read the file content
COMPOSE_CONTENT=$(cat deploy/docker-compose.gcp.yml)

# Create Startup Script
echo -e "${YELLOW}Preparing VM Startup Script...${NC}"
cat > startup-script.sh <<EOF
#!/bin/bash
# Install Docker
apt-get update
apt-get install -y docker.io docker-compose-v2

# Create directory
mkdir -p /opt/n8n
cd /opt/n8n

# Write Docker Compose file
cat > docker-compose.yml <<'YAML'
$COMPOSE_CONTENT
YAML

# Write .env file
cat > .env <<ENV
INSTANCE_CONNECTION_NAME=$CONNECTION_NAME
DB_PASSWORD=$DB_PASSWORD
DB_USER=$DB_USER
DB_NAME=$DB_NAME
N8N_PASSWORD=$N8N_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENC_KEY
MCP_AUTH_TOKEN=$MCP_TOKEN
N8N_API_KEY=$N8N_API_KEY
# Default values
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
ENV

# Start Services
docker compose up -d
EOF

# Create VM
echo -e "${YELLOW}Creating Compute Engine VM...${NC}"
gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type=e2-standard-2 \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --tags=n8n-server,http-server,https-server \
    --metadata-from-file startup-script=startup-script.sh \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --quiet

# Get VM IP
VM_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

# Authorize VM IP for Cloud SQL (Creating a public IP connection needs this)
echo -e "${YELLOW}Authorizing VM IP ($VM_IP) for Cloud SQL...${NC}"
gcloud sql instances patch "$SQL_INSTANCE_NAME" \
    --authorized-networks="$VM_IP" \
    --quiet

# Cleanup
rm startup-script.sh

echo ""
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo "-----------------------------------"
echo -e "n8n URL:     http://$VM_IP:5678"
echo -e "MCP URL:     http://$VM_IP:3000"
echo -e "Username:    admin"
echo -e "Password:    $N8N_PASSWORD"
echo -e "MCP Token:   $MCP_TOKEN"
echo "-----------------------------------"
echo "IMPORTANT NEXT STEPS:"
echo "1. Login to n8n at http://$VM_IP:5678 using the credentials above."
echo "2. Go to Settings > Public API and create a new API Key."
echo "3. SSH into the server: gcloud compute ssh n8n-server --zone=$ZONE"
echo "4. Update the API Key in /opt/n8n/.env: N8N_API_KEY=your_new_key"
echo "5. Restart the services: cd /opt/n8n && docker compose restart n8n-mcp"
echo "-----------------------------------"
echo "Note: It may take a few minutes for the services to start."
echo "Save these credentials safely!"
