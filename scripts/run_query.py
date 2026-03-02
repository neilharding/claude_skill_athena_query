#!/usr/bin/env python3
"""CLI query runner for AWS Athena."""

import argparse
import io
import json
import sys
import time
from typing import Optional
from urllib.parse import urlparse

import boto3
import pandas as pd
from botocore.exceptions import ClientError

from config import AthenaConfig


def query_athena(
    query_string: str,
    database: str,
    execution_parameters: Optional[list[str]] = None,
    output_location: Optional[str] = None,
    region: str = "us-east-1",
    workgroup: str = "primary",
    profile: Optional[str] = None,
    poll_interval: int = 5,
    timeout_seconds: int = 600,
) -> tuple[str, str]:
    """Execute an Athena query and return the S3 results URL."""
    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
    athena_client = session.client("athena", region_name=region)

    execution_params = {
        "QueryString": query_string,
        "QueryExecutionContext": {"Database": database},
        "WorkGroup": workgroup,
    }

    if output_location:
        execution_params["ResultConfiguration"] = {"OutputLocation": output_location}

    if execution_parameters:
        execution_params["ExecutionParameters"] = execution_parameters

    response = athena_client.start_query_execution(**execution_params)
    query_execution_id = response["QueryExecutionId"]
    print(f"Query execution ID: {query_execution_id}", file=sys.stderr)

    start_time = time.time()
    state = None
    execution = None
    while (time.time() - start_time) < timeout_seconds:
        execution = athena_client.get_query_execution(
            QueryExecutionId=query_execution_id
        )
        state = execution["QueryExecution"]["Status"]["State"]

        if state in ["SUCCEEDED", "FAILED", "CANCELLED"]:
            break

        elapsed = int(time.time() - start_time)
        print(f"  Waiting... ({elapsed}s, state={state})", file=sys.stderr)
        time.sleep(poll_interval)

    if state != "SUCCEEDED":
        error_message = (
            execution["QueryExecution"]["Status"].get(
                "StateChangeReason", "Unknown error"
            )
            if execution
            else "Unknown error"
        )
        print(f"ERROR: Query {state}: {error_message}", file=sys.stderr)
        sys.exit(1)

    result_config = (
        execution["QueryExecution"].get("ResultConfiguration", {})
        if execution
        else {}
    )
    results_location = result_config.get("OutputLocation")

    if not results_location:
        try:
            workgroup_info = athena_client.get_work_group(WorkGroup=workgroup)
            results_location = (
                workgroup_info["WorkGroup"]
                .get("Configuration", {})
                .get("ResultConfiguration", {})
                .get("OutputLocation")
            )
        except ClientError:
            pass

    if not results_location:
        print(
            "ERROR: Unable to determine results location. "
            "Set ATHENA_OUTPUT_LOCATION in .env.",
            file=sys.stderr,
        )
        sys.exit(1)

    return results_location, query_execution_id


def fetch_results(s3_url: str, region: str, profile: Optional[str]) -> pd.DataFrame:
    """Download query results from S3 and return as DataFrame."""
    parsed = urlparse(s3_url)
    bucket = parsed.netloc
    key = parsed.path.lstrip("/")

    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
    s3_client = session.client("s3", region_name=region)

    buffer = io.BytesIO()
    s3_client.download_fileobj(bucket, key, buffer)
    buffer.seek(0)

    return pd.read_csv(buffer)


def main():
    parser = argparse.ArgumentParser(description="Run Athena SQL queries")
    parser.add_argument("query", help="SQL query to execute")
    parser.add_argument(
        "--params",
        help='Query parameters as JSON list (e.g., \'["value1", "value2"]\')',
        default=None,
    )
    parser.add_argument(
        "--profile",
        help="AWS/Athena profile name (default: from .env ATHENA_DEFAULT_PROFILE)",
        default=None,
    )
    parser.add_argument(
        "--format",
        choices=["csv", "json", "table"],
        default="csv",
        help="Output format (default: csv)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help="Query timeout in seconds (default: 600)",
    )
    args = parser.parse_args()

    # Parse parameters
    params = None
    if args.params:
        params = json.loads(args.params)
        if not isinstance(params, list):
            print("ERROR: --params must be a JSON list", file=sys.stderr)
            sys.exit(1)

    # Load config
    config = AthenaConfig(profile=args.profile)

    print(
        f"Querying Athena (profile={config.profile}, db={config.database})...",
        file=sys.stderr,
    )
    start = time.time()

    # Execute query
    s3_url, _ = query_athena(
        query_string=args.query,
        database=config.database,
        execution_parameters=params,
        output_location=config.output_location,
        region=config.region,
        workgroup=config.workgroup,
        profile=config.profile,
        timeout_seconds=args.timeout,
    )

    # Fetch results
    df = fetch_results(s3_url, config.region, config.profile)

    elapsed = time.time() - start
    print(f"Returned {len(df)} rows in {elapsed:.1f}s", file=sys.stderr)

    # Output results
    if args.format == "csv":
        print(df.to_csv(index=False))
    elif args.format == "json":
        print(df.to_json(orient="records", indent=2))
    elif args.format == "table":
        print(df.to_string(index=False))


if __name__ == "__main__":
    main()
