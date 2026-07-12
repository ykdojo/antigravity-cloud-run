#!/bin/bash
# Deploy a session to Cloud Run: one service per session, IAM-gated.
# Usage: deploy-cloud.sh [-s session] [-r region] [-P project] [-a]
#   -a  always-on (min-instances=1, costs money 24/7; default: scale to zero)
set -euo pipefail

SESSION_NAME="default"
REGION="us-central1"
PROJECT="$(gcloud config get-value project 2>/dev/null)"
MIN_INSTANCES=0

while getopts "s:r:P:a" opt; do
    case $opt in
        s) SESSION_NAME="$OPTARG" ;;
        r) REGION="$OPTARG" ;;
        P) PROJECT="$OPTARG" ;;
        a) MIN_INSTANCES=1 ;;
        *) echo "Usage: $0 [-s session] [-r region] [-P project] [-a]"; exit 1 ;;
    esac
done

if [ -z "$PROJECT" ]; then
    echo "Error: no GCP project. Set one with 'gcloud config set project ...' or pass -P." >&2
    exit 1
fi

STORED_AGY_TOKEN="${XDG_CONFIG_HOME:-$HOME/.config}/agrun/agy-oauth-token"
if [ ! -f "$STORED_AGY_TOKEN" ]; then
    echo "Error: no agy login stored ($STORED_AGY_TOKEN)." >&2
    echo "Log in through a local container first: run ./scripts/run.sh and follow its sign-in instructions." >&2
    exit 1
fi

SERVICE="agrun-${SESSION_NAME}"
REPO="agrun"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/agrun:latest"
BUCKET="${PROJECT}-agrun-${SESSION_NAME}"
SECRET="agy-oauth-token"

echo "Project: $PROJECT | Region: $REGION | Service: $SERVICE"

echo "==> Enabling APIs (idempotent)..."
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
    secretmanager.googleapis.com --project "$PROJECT" --quiet

echo "==> Ensuring Artifact Registry repo..."
gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 || \
    gcloud artifacts repositories create "$REPO" --repository-format docker \
        --location "$REGION" --project "$PROJECT" --quiet

echo "==> Building image..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
docker build -t agrun "$(dirname "$SCRIPT_DIR")"

echo "==> Pushing image..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker tag agrun "$IMAGE"
docker push "$IMAGE"

echo "==> Ensuring session bucket gs://$BUCKET..."
gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1 || \
    gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" \
        --location "$REGION" --uniform-bucket-level-access

echo "==> Ensuring agy login secret..."
if gcloud secrets describe "$SECRET" --project "$PROJECT" >/dev/null 2>&1; then
    gcloud secrets versions add "$SECRET" --project "$PROJECT" --data-file "$STORED_AGY_TOKEN" --quiet
else
    gcloud secrets create "$SECRET" --project "$PROJECT" --replication-policy automatic \
        --data-file "$STORED_AGY_TOKEN" --quiet
fi

# Default compute service account runs the service; grant it the bucket + secret
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format 'value(projectNumber)')"
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "==> Granting $SA access to bucket and secret..."
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member "serviceAccount:$SA" --role roles/storage.objectAdmin --quiet >/dev/null
gcloud secrets add-iam-policy-binding "$SECRET" --project "$PROJECT" \
    --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor --quiet >/dev/null

echo "==> Deploying $SERVICE..."
gcloud run deploy "$SERVICE" \
    --project "$PROJECT" \
    --region "$REGION" \
    --image "$IMAGE" \
    --no-allow-unauthenticated \
    --port 7681 \
    --execution-environment gen2 \
    --cpu 2 --memory 2Gi \
    --min-instances "$MIN_INSTANCES" --max-instances 1 \
    --session-affinity \
    --timeout 3600 \
    --set-env-vars "SESSION_NAME=${SESSION_NAME}" \
    --set-secrets "AGY_OAUTH_TOKEN=${SECRET}:latest" \
    --add-volume "name=gemini,type=cloud-storage,bucket=${BUCKET}" \
    --add-volume-mount "volume=gemini,mount-path=/gcs-session" \
    --labels "agrun=session" \
    --quiet

# Record project/region for the dashboard's cloud section
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agrun"
mkdir -p "$CONFIG_DIR"
printf '{\n  "project": "%s",\n  "region": "%s"\n}\n' "$PROJECT" "$REGION" > "$CONFIG_DIR/cloud.json"

echo ""
echo "Deployed. Connect with:"
echo ""
echo "  gcloud run services proxy $SERVICE --project $PROJECT --region $REGION --port 7681"
echo ""
echo "then open http://localhost:7681"
echo ""
echo "Never use --allow-unauthenticated: the web terminal is a remote shell."
