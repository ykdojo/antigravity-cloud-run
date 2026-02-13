#!/bin/bash
# Set up Slack integration for SafeClaw

SECRETS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/safeclaw/.secrets"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../setup/slack-manifest.json"

echo ""
echo "=== Slack Setup ==="
echo ""
echo "Setup method:"
echo "  [Q] Quick   - create app from manifest (channels, users, search)"
echo "  [M] Manual  - create app from scratch (more control, optional DM access)"
echo ""
read -p "Choose [Q/m]: " setup_method
echo ""

if [[ "$setup_method" =~ ^[Mm]$ ]]; then
    # Manual setup
    echo "1. Go to https://api.slack.com/apps"
    echo "2. Click 'Create New App' > 'From scratch'"
    echo "3. Name it (e.g., 'SafeClaw') and select your workspace"
    echo "4. Go to 'OAuth & Permissions'"
    echo ""
    echo "Which token type?"
    echo "  [B] Bot Token  - can only read channels the bot is added to"
    echo "  [U] User Token - can read all channels you're in"
    echo ""
    read -p "Choose [B/u]: " token_choice
    echo ""

    if [[ "$token_choice" =~ ^[Uu]$ ]]; then
        scope_section="User Token Scopes"
        token_prefix="xoxp-"
    else
        scope_section="Bot Token Scopes"
        token_prefix="xoxb-"
    fi

    echo "Add these scopes to '$scope_section':"
    echo "   - channels:read, channels:history (public channels)"
    echo "   - groups:read, groups:history (private channels)"
    echo "   - users:read (user profiles)"
    echo "   - search:read (search messages)"
    echo "   - (optional) im:read, im:history (DMs)"
    echo "   - (optional) mpim:read, mpim:history (group DMs)"
    echo ""
    echo "5. Left sidebar > 'Install App' > 'Install to Workspace'"
    echo "6. Copy the token (starts with $token_prefix)"
else
    # Quick setup via manifest
    echo "1. Go to https://api.slack.com/apps?new_app=1"
    echo "2. Choose 'From a manifest'"
    echo "3. Select your workspace"
    echo "4. Switch to JSON tab and paste this manifest:"
    echo ""
    cat "$MANIFEST"
    echo ""
    echo "5. Click 'Create'"
    echo "6. Go to 'Install App' > 'Install to Workspace'"
    echo "7. Copy the User OAuth Token (starts with xoxp-)"
fi

echo ""
read -p "Paste token: " slack_token

if [ -z "$slack_token" ]; then
    echo "No token provided, skipping Slack setup."
else
    mkdir -p "$SECRETS_DIR"
    echo "$slack_token" > "$SECRETS_DIR/SLACK_TOKEN"
    echo ""
    echo "Saved to $SECRETS_DIR/SLACK_TOKEN"
    echo ""
    echo "Restart SafeClaw to use Slack:"
    echo "  ./scripts/run.sh"
fi
