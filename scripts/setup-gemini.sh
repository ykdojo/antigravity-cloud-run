#!/bin/bash
# Set up Gemini CLI API key for SafeClaw

SECRETS_DIR="$HOME/.config/safeclaw/.secrets"
TOKEN_FILE="$SECRETS_DIR/GEMINI_API_KEY"

mkdir -p "$SECRETS_DIR"

echo "Gemini CLI Setup"
echo "================"
echo ""
echo "Get your API key from: https://aistudio.google.com/apikey"
echo ""
read -p "Paste your Gemini API key: " api_key

if [ -z "$api_key" ]; then
    echo "No key provided. Aborting."
    exit 1
fi

echo -n "$api_key" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

echo ""
echo "Saved to $TOKEN_FILE"
echo "Stop and start the container from the dashboard to apply."
