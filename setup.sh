#!/bin/bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SKILL_DIR/.env"

echo "====================================="
echo "  Athena Query Skill Setup"
echo "====================================="
echo ""

# --- Step 1: Install uv if needed ---
if command -v uv &>/dev/null; then
    echo "[✓] uv is already installed ($(uv --version))"
else
    echo "[*] Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Source the updated PATH
    export PATH="$HOME/.local/bin:$PATH"
    echo "[✓] uv installed ($(uv --version))"
fi
echo ""

# --- Step 2: Create virtual environment ---
echo "[*] Setting up Python environment..."
cd "$SKILL_DIR"
if [ -d ".venv" ]; then
    echo "    .venv already exists, reinstalling dependencies..."
else
    uv venv .venv
    echo "    Created .venv"
fi
uv pip install -r requirements.txt --quiet
echo "[✓] Python dependencies installed"
echo ""

# --- Step 3: Configure AWS profiles ---
echo "====================================="
echo "  AWS Profile Configuration"
echo "====================================="
echo ""
echo "This skill uses AWS CLI profiles to authenticate with Athena."
echo "You can configure multiple profiles (e.g., dev and prod)."
echo ""
echo "TIP: It's recommended to set up 'dev' as your first profile."
echo "     This becomes the default, so queries run against dev"
echo "     unless you explicitly specify a different profile."
echo ""

# Check for existing config
PROFILES=()
DEFAULT_PROFILE=""

if [ -f "$ENV_FILE" ]; then
    echo "Existing configuration found in .env"
    existing_profiles=$(grep "^ATHENA_PROFILES=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    existing_default=$(grep "^ATHENA_DEFAULT_PROFILE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$existing_profiles" ]; then
        echo "  Existing profiles: $existing_profiles"
        echo "  Default profile: $existing_default"
        echo ""
        read -p "Would you like to add a new profile or reconfigure? (add/reconfigure/skip) [skip]: " action
        action="${action:-skip}"
        if [ "$action" = "skip" ]; then
            echo ""
            echo "[✓] Setup complete! Keeping existing configuration."
            echo ""
            echo "Usage:"
            echo "  Ask Claude to 'query Athena' and it will use the default profile ($existing_default)."
            echo "  Say 'use the prod profile' to query with a different profile."
            echo ""
            exit 0
        elif [ "$action" = "add" ]; then
            # Load existing profiles
            IFS=',' read -ra PROFILES <<< "$existing_profiles"
            DEFAULT_PROFILE="$existing_default"
        fi
        # reconfigure: start fresh below
    fi
fi

# Start .env content (will append profile-specific settings)
ENV_CONTENT=""

configure_profile() {
    local profile_name="$1"
    local profile_upper
    profile_upper=$(echo "$profile_name" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo "--- Configuring profile: $profile_name ---"
    echo ""

    # Check if AWS profile exists
    if aws configure list --profile "$profile_name" &>/dev/null 2>&1; then
        echo "[✓] AWS profile '$profile_name' already exists in ~/.aws/credentials"
        read -p "    Reconfigure AWS credentials for this profile? (y/n) [n]: " reconfig
        reconfig="${reconfig:-n}"
    else
        reconfig="y"
    fi

    if [ "$reconfig" = "y" ]; then
        echo ""
        echo "Enter AWS credentials for profile '$profile_name':"
        read -p "  AWS Access Key ID: " aws_key
        read -sp "  AWS Secret Access Key: " aws_secret
        echo ""
        read -p "  AWS Region [us-east-1]: " aws_region
        aws_region="${aws_region:-us-east-1}"

        # Write AWS credentials
        mkdir -p ~/.aws
        # Use python to safely update the credentials file
        "$SKILL_DIR/.venv/bin/python" -c "
import configparser, os
creds = configparser.ConfigParser()
creds_path = os.path.expanduser('~/.aws/credentials')
if os.path.exists(creds_path):
    creds.read(creds_path)
creds['$profile_name'] = {
    'aws_access_key_id': '$aws_key',
    'aws_secret_access_key': '$aws_secret',
}
with open(creds_path, 'w') as f:
    creds.write(f)

config = configparser.ConfigParser()
config_path = os.path.expanduser('~/.aws/config')
if os.path.exists(config_path):
    config.read(config_path)
section = 'profile $profile_name' if '$profile_name' != 'default' else 'default'
config[section] = {'region': '$aws_region', 'output': 'json'}
with open(config_path, 'w') as f:
    config.write(f)
"
        echo "[✓] AWS credentials saved for profile '$profile_name'"
    fi

    echo ""
    echo "Enter Athena settings for profile '$profile_name':"
    read -p "  Athena Database: " athena_db
    read -p "  Athena Region [us-east-1]: " athena_region
    athena_region="${athena_region:-us-east-1}"
    read -p "  Athena Workgroup [primary]: " athena_wg
    athena_wg="${athena_wg:-primary}"
    read -p "  Athena S3 Output Location (e.g., s3://bucket/path/): " athena_output

    # Append to env content
    ENV_CONTENT="${ENV_CONTENT}
# Profile: $profile_name
ATHENA_DATABASE_${profile_upper}=${athena_db}
ATHENA_REGION_${profile_upper}=${athena_region}
ATHENA_WORKGROUP_${profile_upper}=${athena_wg}
ATHENA_OUTPUT_LOCATION_${profile_upper}=${athena_output}
"

    PROFILES+=("$profile_name")
    echo "[✓] Athena settings saved for profile '$profile_name'"
}

# Configure first profile (suggest dev)
if [ ${#PROFILES[@]} -eq 0 ]; then
    read -p "Enter profile name [dev]: " first_profile
    first_profile="${first_profile:-dev}"
    DEFAULT_PROFILE="$first_profile"
    configure_profile "$first_profile"
else
    read -p "Enter new profile name: " new_profile
    configure_profile "$new_profile"
fi

# Loop to add more profiles
while true; do
    echo ""
    read -p "Add another profile? (y/n) [n]: " add_more
    add_more="${add_more:-n}"
    if [ "$add_more" != "y" ]; then
        break
    fi
    read -p "Enter profile name: " next_profile
    configure_profile "$next_profile"
done

# Write .env file
PROFILE_LIST=$(IFS=','; echo "${PROFILES[*]}")
cat > "$ENV_FILE" << ENVEOF
# Athena Query Skill Configuration
# Generated by setup.sh on $(date)

# Default profile (used when no --profile flag is specified)
ATHENA_DEFAULT_PROFILE=${DEFAULT_PROFILE}

# All configured profiles
ATHENA_PROFILES=${PROFILE_LIST}
${ENV_CONTENT}
ENVEOF

echo ""
echo "[✓] Configuration saved to .env"

# --- Step 4: Test connection ---
echo ""
read -p "Test connection with default profile ($DEFAULT_PROFILE)? (y/n) [y]: " do_test
do_test="${do_test:-y}"

if [ "$do_test" = "y" ]; then
    echo "[*] Running test query..."
    "$SKILL_DIR/.venv/bin/python" "$SKILL_DIR/scripts/run_query.py" \
        "SELECT 1 AS test_connection" \
        --profile "$DEFAULT_PROFILE" \
        --format table 2>&1 || {
        echo ""
        echo "[!] Connection test failed. Check your credentials and Athena settings."
        echo "    You can re-run ./setup.sh to reconfigure."
    }
fi

echo ""
echo "====================================="
echo "  Setup Complete!"
echo "====================================="
echo ""
echo "Configured profiles: $PROFILE_LIST"
echo "Default profile: $DEFAULT_PROFILE"
echo ""
echo "To use this skill, ask Claude to query Athena."
echo "Examples:"
echo "  'Query Athena: SELECT * FROM my_table LIMIT 10'"
echo "  'Query the prod Athena database for...'"
echo ""
echo "To add more profiles later, run ./setup.sh again."
