"""Read-only access to the claim store (Cosmos DB for NoSQL, private, Entra only)."""
from __future__ import annotations


class CosmosRecordReader:
    """Reads one item by ID. Use a credential that holds only Cosmos DB Built-in Data Reader on the container."""

    def __init__(self, endpoint: str, database: str, container: str, credential):
        from azure.cosmos import CosmosClient

        self._container = CosmosClient(endpoint, credential=credential).get_database_client(database) \
            .get_container_client(container)

    def read(self, record_id: str) -> dict | None:
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        try:
            item = self._container.read_item(item=record_id, partition_key=record_id)
        except CosmosResourceNotFoundError:
            return None
        return {k: v for k, v in item.items() if not k.startswith("_") and k != "id"}
