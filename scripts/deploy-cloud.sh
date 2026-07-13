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
# Separate tag from the local `agrun` image, which stays native (arm64 on
# Apple Silicon); Cloud Run only runs linux/amd64
docker build --platform linux/amd64 -t agrun-amd64 "$(dirname "$SCRIPT_DIR")"

echo "==> Pushing image..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker tag agrun-amd64 "$IMAGE"
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

# Sync local secrets (~/.config/agrun/.secrets/) to Secret Manager: each file
# becomes an env var in the service, same as local sessions. Synced secrets
# are labeled agrun=secret so ones whose local file is gone can be deleted.
LOCAL_SECRETS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agrun/.secrets"
SECRET_REFS="AGY_OAUTH_TOKEN=${SECRET}:latest"
echo "==> Syncing secrets..."
if [ -d "$LOCAL_SECRETS_DIR" ]; then
    for f in "$LOCAL_SECRETS_DIR"/*; do
        [ -f "$f" ] || continue
        NAME="$(basename "$f")"
        if ! [[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "    skipping $NAME (not a valid env var name)" >&2
            continue
        fi
        SM_NAME="agrun-${NAME}"
        # Strip trailing newlines: the value lands verbatim in an env var,
        # where a trailing \n breaks token auth (e.g. gh)
        VALUE="$(cat "$f")"
        if gcloud secrets describe "$SM_NAME" --project "$PROJECT" >/dev/null 2>&1; then
            if [ "$(gcloud secrets versions access latest --secret "$SM_NAME" --project "$PROJECT" 2>/dev/null | shasum)" != "$(printf '%s' "$VALUE" | shasum)" ]; then
                printf '%s' "$VALUE" | gcloud secrets versions add "$SM_NAME" --project "$PROJECT" --data-file=- --quiet >/dev/null
            fi
        else
            printf '%s' "$VALUE" | gcloud secrets create "$SM_NAME" --project "$PROJECT" --replication-policy automatic \
                --labels agrun=secret --data-file=- --quiet
        fi
        gcloud secrets add-iam-policy-binding "$SM_NAME" --project "$PROJECT" \
            --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor --quiet >/dev/null
        SECRET_REFS="${SECRET_REFS},${NAME}=${SM_NAME}:latest"
    done
fi
# Delete synced secrets whose local file no longer exists
for SM_NAME in $(gcloud secrets list --project "$PROJECT" --filter 'labels.agrun=secret' --format 'value(name)'); do
    NAME="${SM_NAME#agrun-}"
    if [ ! -f "$LOCAL_SECRETS_DIR/$NAME" ]; then
        echo "    removing stale secret $SM_NAME"
        gcloud secrets delete "$SM_NAME" --project "$PROJECT" --quiet
    fi
done

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
    --set-secrets "$SECRET_REFS" \
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
