"""Athena configuration with multi-profile support."""

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

# Load .env from skill root directory
_env_path = Path(__file__).parent.parent / ".env"
if _env_path.exists():
    load_dotenv(_env_path, override=True)


@dataclass
class AthenaConfig:
    """Configuration for AWS Athena queries with profile support."""

    database: str
    region: str = "us-east-1"
    workgroup: str = "primary"
    output_location: Optional[str] = None
    profile: Optional[str] = None

    def __init__(
        self,
        database: Optional[str] = None,
        region: Optional[str] = None,
        workgroup: Optional[str] = None,
        output_location: Optional[str] = None,
        profile: Optional[str] = None,
    ):
        # Resolve which AWS profile to use
        self.profile = profile or os.environ.get("ATHENA_DEFAULT_PROFILE")

        # Load per-profile settings if a profile is set
        suffix = f"_{self.profile.upper()}" if self.profile else ""

        self.database = (
            database
            or os.environ.get(f"ATHENA_DATABASE{suffix}")
            or os.environ.get("ATHENA_DATABASE")
            or ""
        )
        self.region = (
            region
            or os.environ.get(f"ATHENA_REGION{suffix}")
            or os.environ.get("ATHENA_REGION")
            or "us-east-1"
        )
        self.workgroup = (
            workgroup
            or os.environ.get(f"ATHENA_WORKGROUP{suffix}")
            or os.environ.get("ATHENA_WORKGROUP")
            or "primary"
        )
        self.output_location = (
            output_location
            or os.environ.get(f"ATHENA_OUTPUT_LOCATION{suffix}")
            or os.environ.get("ATHENA_OUTPUT_LOCATION")
        )

        if not self.database:
            raise ValueError(
                "Athena database must be provided via parameter or environment variable. "
                "Run ./setup.sh to configure."
            )
