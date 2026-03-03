# Athena Query Skill for Claude Code

A Claude Code skill that enables Claude to execute SQL queries against AWS Athena.

## Installation

```bash
git clone https://github.com/neilharding/claude_skill_athena_query.git ~/.claude/skills/athena-query
cd ~/.claude/skills/athena-query
./setup.sh
```

The setup script will:
1. Install [uv](https://github.com/astral-sh/uv) (fast Python package manager) if not present
2. Create a Python virtual environment with required dependencies
3. Walk you through configuring one or more AWS profiles with Athena settings
4. Optionally test the connection

## Usage

Once installed, ask Claude to query Athena in natural language:

- "Query Athena: SELECT * FROM patients LIMIT 10"
- "How many records are in the events table on Athena?"
- "Query the prod Athena database for active clinical sites"

## Multi-Profile Support

You can configure multiple profiles (e.g., dev and prod) during setup. The default profile is used unless you specify otherwise:

- "Query Athena for..." → uses default profile (dev)
- "Query the prod Athena..." → uses prod profile

To add more profiles later, run `./setup.sh` again.

## Requirements

- macOS
- Internet connection (for initial setup)
- AWS access key and secret key for each profile
- Athena database, workgroup, and S3 output location
