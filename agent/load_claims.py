#!/usr/bin/env python3
"""One-time load of the pack's synthetic claims into the claim store (w1-agent). Run inside the VNet (the jumpbox)
while the person running it holds a temporary Cosmos DB Built-in Data Contributor assignment on the claims container
(w1-rbac R4), then remove that assignment.

    python -I agent/load_claims.py [--dry-run]

Environment: COSMOS_ENDPOINT, SCENARIO (default larkfield). Prints counts only, never record content.
--dry-run reads the pack and reports what would be loaded, with no Azure calls (local check of the invocation).
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pack  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Load the pack's synthetic claims into the claim store")
    parser.add_argument("--dry-run", action="store_true", help="read the pack only; no Azure calls")
    args = parser.parse_args()

    config = pack.load_config()
    store = config["record_store"]
    if args.dry_run:
        print(f"dry run: would upsert {len(pack.load_records())} records into {store['database']}/{store['container']}")
        return 0

    from azure.cosmos import CosmosClient
    from azure.identity import AzureCliCredential

    container = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=AzureCliCredential()) \
        .get_database_client(store["database"]).get_container_client(store["container"])
    records = pack.load_records()
    for record in records:
        container.upsert_item({"id": record["claim_id"], **record})
    print(f"upserted {len(records)} records into {store['database']}/{store['container']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
