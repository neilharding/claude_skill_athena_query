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
echo "TIP: It's recommended to set up 'dev' as your default profile."
echo "     This becomes the default, so queries run against dev"
echo "     unless you explicitly specify a different profile."
echo ""

PROFILES=()
DEFAULT_PROFILE=""
ENV_CONTENT=""

# --- Helper: get masked key ID for an AWS profile ---
get_masked_key() {
    local profile_name="$1"
    local key_id
    key_id=$("$SKILL_DIR/.venv/bin/python" -c "
import configparser, os, sys
creds = configparser.ConfigParser()
creds_path = os.path.expanduser('~/.aws/credentials')
if not os.path.exists(creds_path):
    sys.exit(1)
creds.read(creds_path)
if '$profile_name' not in creds:
    sys.exit(1)
key = creds['$profile_name'].get('aws_access_key_id', '')
if key:
    print(key[:4] + '****' + key[-4:])
else:
    sys.exit(1)
" 2>/dev/null) && echo "$key_id" || echo ""
}

# --- Helper: get existing Athena settings for a profile from .env ---
get_existing_athena_settings() {
    local profile_upper="$1"
    if [ -f "$ENV_FILE" ]; then
        local db region wg output
        db=$(grep "^ATHENA_DATABASE_${profile_upper}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
        region=$(grep "^ATHENA_REGION_${profile_upper}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
        wg=$(grep "^ATHENA_WORKGROUP_${profile_upper}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
        output=$(grep "^ATHENA_OUTPUT_LOCATION_${profile_upper}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
        if [ -n "$db" ]; then
            echo "$db|$region|$wg|$output"
            return 0
        fi
    fi
    return 1
}

# --- Helper: configure AWS credentials for a profile ---
configure_aws_creds() {
    local profile_name="$1"
    echo ""
    echo "Enter AWS credentials for profile '$profile_name':"
    read -p "  AWS Access Key ID: " aws_key
    read -sp "  AWS Secret Access Key: " aws_secret
    echo ""
    read -p "  AWS Region [us-east-1]: " aws_region
    aws_region="${aws_region:-us-east-1}"

    mkdir -p ~/.aws
    AWS_KEY="$aws_key" AWS_SECRET="$aws_secret" AWS_REGION_VAL="$aws_region" \
    PROFILE_NAME="$profile_name" \
    "$SKILL_DIR/.venv/bin/python" -c "
import configparser, os
profile = os.environ['PROFILE_NAME']
creds = configparser.ConfigParser()
creds_path = os.path.expanduser('~/.aws/credentials')
if os.path.exists(creds_path):
    creds.read(creds_path)
creds[profile] = {
    'aws_access_key_id': os.environ['AWS_KEY'],
    'aws_secret_access_key': os.environ['AWS_SECRET'],
}
with open(creds_path, 'w') as f:
    creds.write(f)

config = configparser.ConfigParser()
config_path = os.path.expanduser('~/.aws/config')
if os.path.exists(config_path):
    config.read(config_path)
section = f'profile {profile}' if profile != 'default' else 'default'
config[section] = {'region': os.environ['AWS_REGION_VAL'], 'output': 'json'}
with open(config_path, 'w') as f:
    config.write(f)
"
    echo "[✓] AWS credentials saved for profile '$profile_name'"
}

# --- Helper: configure Athena settings for a profile ---
configure_athena_settings() {
    local profile_name="$1"
    local profile_upper
    profile_upper=$(echo "$profile_name" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo "Enter Athena settings for profile '$profile_name':"
    read -p "  Athena Database: " athena_db
    read -p "  Athena Region [us-east-1]: " athena_region
    athena_region="${athena_region:-us-east-1}"
    read -p "  Athena Workgroup [primary]: " athena_wg
    athena_wg="${athena_wg:-primary}"
    read -p "  Athena S3 Output Location (e.g., s3://bucket/path/): " athena_output

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

# --- Helper: keep existing Athena settings for a profile ---
keep_athena_settings() {
    local profile_name="$1"
    local profile_upper
    profile_upper=$(echo "$profile_name" | tr '[:lower:]' '[:upper:]')
    local settings
    settings=$(get_existing_athena_settings "$profile_upper")
    local db region wg output
    IFS='|' read -r db region wg output <<< "$settings"

    ENV_CONTENT="${ENV_CONTENT}
# Profile: $profile_name
ATHENA_DATABASE_${profile_upper}=${db}
ATHENA_REGION_${profile_upper}=${region}
ATHENA_WORKGROUP_${profile_upper}=${wg}
ATHENA_OUTPUT_LOCATION_${profile_upper}=${output}
"
    PROFILES+=("$profile_name")
}

# --- Detect existing profiles ---
echo "Checking for existing configuration..."
echo ""

WELL_KNOWN_PROFILES=("dev" "prod" "default")
FOUND_ANY=false

for pname in "${WELL_KNOWN_PROFILES[@]}"; do
    pname_upper=$(echo "$pname" | tr '[:lower:]' '[:upper:]')
    masked_key=$(get_masked_key "$pname")
    athena_settings=$(get_existing_athena_settings "$pname_upper" || true)

    has_aws=false
    has_athena=false
    [ -n "$masked_key" ] && has_aws=true
    [ -n "$athena_settings" ] && has_athena=true

    if $has_aws || $has_athena; then
        FOUND_ANY=true
        echo "  Profile '$pname':"
        if $has_aws; then
            echo "    AWS credentials: ✓ (key: $masked_key)"
        else
            echo "    AWS credentials: ✗ (not configured)"
        fi
        if $has_athena; then
            local_db=$(echo "$athena_settings" | cut -d'|' -f1)
            local_region=$(echo "$athena_settings" | cut -d'|' -f2)
            local_wg=$(echo "$athena_settings" | cut -d'|' -f3)
            local_output=$(echo "$athena_settings" | cut -d'|' -f4)
            echo "    Athena database: $local_db"
            echo "    Athena region:   $local_region"
            echo "    Athena workgroup: $local_wg"
            echo "    Athena output:   $local_output"
        else
            echo "    Athena settings: ✗ (not configured)"
        fi
        echo ""
    fi
done

# Also check for any additional profiles in existing .env
if [ -f "$ENV_FILE" ]; then
    existing_profiles_str=$(grep "^ATHENA_PROFILES=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    existing_default=$(grep "^ATHENA_DEFAULT_PROFILE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$existing_profiles_str" ]; then
        IFS=',' read -ra existing_profile_list <<< "$existing_profiles_str"
        for pname in "${existing_profile_list[@]}"; do
            # Skip well-known profiles already shown
            if [[ " ${WELL_KNOWN_PROFILES[*]} " == *" $pname "* ]]; then
                continue
            fi
            pname_upper=$(echo "$pname" | tr '[:lower:]' '[:upper:]')
            athena_settings=$(get_existing_athena_settings "$pname_upper" || true)
            masked_key=$(get_masked_key "$pname")
            if [ -n "$athena_settings" ] || [ -n "$masked_key" ]; then
                FOUND_ANY=true
                echo "  Profile '$pname':"
                [ -n "$masked_key" ] && echo "    AWS credentials: ✓ (key: $masked_key)" || echo "    AWS credentials: ✗"
                if [ -n "$athena_settings" ]; then
                    local_db=$(echo "$athena_settings" | cut -d'|' -f1)
                    echo "    Athena database: $local_db"
                fi
                echo ""
            fi
        done
    fi
fi

if $FOUND_ANY; then
    echo "-------------------------------------"
    echo ""

    # --- Walk through each detected profile ---
    for pname in "${WELL_KNOWN_PROFILES[@]}"; do
        pname_upper=$(echo "$pname" | tr '[:lower:]' '[:upper:]')
        masked_key=$(get_masked_key "$pname")
        athena_settings=$(get_existing_athena_settings "$pname_upper" || true)

        has_aws=false
        has_athena=false
        [ -n "$masked_key" ] && has_aws=true
        [ -n "$athena_settings" ] && has_athena=true

        if $has_aws || $has_athena; then
            read -p "Profile '$pname': keep existing configuration? (y/n) [y]: " keep_it
            keep_it="${keep_it:-y}"

            if [ "$keep_it" = "y" ]; then
                if $has_athena; then
                    keep_athena_settings "$pname"
                    echo "  [✓] Keeping '$pname' as-is"
                else
                    echo "  AWS credentials exist but Athena settings are missing."
                    configure_athena_settings "$pname"
                fi
            else
                # User wants to modify — ask about AWS creds and Athena settings
                if $has_aws; then
                    read -p "  Reconfigure AWS credentials for '$pname'? (y/n) [n]: " reconfig_aws
                    reconfig_aws="${reconfig_aws:-n}"
                    [ "$reconfig_aws" = "y" ] && configure_aws_creds "$pname"
                else
                    configure_aws_creds "$pname"
                fi
                configure_athena_settings "$pname"
            fi

            # Set default profile (first one kept/configured, prefer dev)
            if [ -z "$DEFAULT_PROFILE" ]; then
                DEFAULT_PROFILE="$pname"
            fi
            echo ""
        fi
    done

    # Handle extra profiles from .env that aren't in well-known list
    if [ -f "$ENV_FILE" ] && [ -n "${existing_profiles_str:-}" ]; then
        for pname in "${existing_profile_list[@]}"; do
            if [[ " ${WELL_KNOWN_PROFILES[*]} " == *" $pname "* ]]; then
                continue
            fi
            pname_upper=$(echo "$pname" | tr '[:lower:]' '[:upper:]')
            athena_settings=$(get_existing_athena_settings "$pname_upper" || true)
            if [ -n "$athena_settings" ]; then
                read -p "Profile '$pname': keep existing configuration? (y/n) [y]: " keep_it
                keep_it="${keep_it:-y}"
                if [ "$keep_it" = "y" ]; then
                    keep_athena_settings "$pname"
                    echo "  [✓] Keeping '$pname' as-is"
                else
                    masked_key=$(get_masked_key "$pname")
                    if [ -n "$masked_key" ]; then
                        read -p "  Reconfigure AWS credentials for '$pname'? (y/n) [n]: " reconfig_aws
                        reconfig_aws="${reconfig_aws:-n}"
                        [ "$reconfig_aws" = "y" ] && configure_aws_creds "$pname"
                    else
                        configure_aws_creds "$pname"
                    fi
                    configure_athena_settings "$pname"
                fi
                echo ""
            fi
        done
    fi
else
    echo "  No existing profiles detected."
    echo ""
fi

# --- Offer to add new profiles ---
# If no profiles configured yet, prompt for first one (suggest dev)
if [ ${#PROFILES[@]} -eq 0 ]; then
    read -p "Enter profile name [dev]: " first_profile
    first_profile="${first_profile:-dev}"
    DEFAULT_PROFILE="$first_profile"

    masked_key=$(get_masked_key "$first_profile")
    if [ -n "$masked_key" ]; then
        echo "[✓] AWS profile '$first_profile' found (key: $masked_key)"
        read -p "    Reconfigure AWS credentials? (y/n) [n]: " reconfig_aws
        reconfig_aws="${reconfig_aws:-n}"
        [ "$reconfig_aws" = "y" ] && configure_aws_creds "$first_profile"
    else
        configure_aws_creds "$first_profile"
    fi
    configure_athena_settings "$first_profile"
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

    masked_key=$(get_masked_key "$next_profile")
    if [ -n "$masked_key" ]; then
        echo "[✓] AWS profile '$next_profile' found (key: $masked_key)"
        read -p "    Reconfigure AWS credentials? (y/n) [n]: " reconfig_aws
        reconfig_aws="${reconfig_aws:-n}"
        [ "$reconfig_aws" = "y" ] && configure_aws_creds "$next_profile"
    else
        configure_aws_creds "$next_profile"
    fi
    configure_athena_settings "$next_profile"
done

# Ensure default is set (prefer dev if it's in the list)
if [ -z "$DEFAULT_PROFILE" ]; then
    DEFAULT_PROFILE="${PROFILES[0]}"
fi
for p in "${PROFILES[@]}"; do
    if [ "$p" = "dev" ]; then
        DEFAULT_PROFILE="dev"
        break
    fi
done

echo ""
read -p "Default profile [$DEFAULT_PROFILE]: " user_default
DEFAULT_PROFILE="${user_default:-$DEFAULT_PROFILE}"

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
