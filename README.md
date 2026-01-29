# Subgraph Deployment Migration Script

A bash script for migrating specific subgraph deployments from one Graph Node database cluster to another.

## Overview

This script handles the complete migration of subgraph deployments between sharded database clusters, including:

- Metadata migration (deployment_schemas, subgraph tables)
- Data schema migration (sgdXXX schemas with all tables and indexes)
- Automatic ID sequence management
- Data consistency verification
- Streaming data transfer (no intermediate disk storage required)
- Optional graphman integration for pausing/resuming subgraphs

## Prerequisites

- PostgreSQL client tools (`psql`, `pg_dump`)
- Appropriate database permissions for reading and writing
- Network connectivity to all database instances
- `pv` (optional, for progress monitoring during data transfer)

## Database Structure

The script works with Graph Node's sharded architecture:

- **Metadata Database (primary)**: Contains `deployment_schemas`, `subgraphs.subgraph_version`, `subgraphs.subgraph`, and coordination tables
- **Data Database (shard)**: Contains the actual subgraph data in schemas named `sgdXXX`, plus `subgraphs.head`, `subgraphs.deployment`, `subgraphs.subgraph_manifest`, `subgraphs.subgraph_error`, and `subgraphs.graph_node_versions`
- **Both databases**: `subgraphs.subgraph_features`, `subgraphs.dynamic_ethereum_contract_data_source`, `subgraphs.subgraph_deployment_assignment`

## Setup

### Configure Environment Variables

**Required** environment variables:

```bash
export TARGET_METADATA_DB="postgresql://user:password@target-host:5432/graph-metadata"
export TARGET_DATA_DB="postgresql://user:password@target-host:5432/graph-data"
```

**Source database configuration** (one of the following):

Option 1 - Use GRAPH_NODE_CONFIG (recommended):
```bash
export GRAPH_NODE_CONFIG="/path/to/graph-node-config.toml"
```
The script will automatically derive source databases from the config file based on where the deployment is located. It will also pause the source subgraph before migration using graphman and resume it after completion (or on failure).

**Note**: The `graphman` command is known to segfault after successfully completing operations. The script handles this gracefully and continues execution.

Option 2 - Explicit source databases:
```bash
export SOURCE_METADATA_DB="postgresql://user:password@source-host:5432/graph-metadata"
export SOURCE_DATA_DB="postgresql://user:password@source-host:5432/graph-data"
```

### Optional Environment Variables

**OVERRIDE_SHARD**: Override the shard value for the target deployment

By default, the script preserves the shard value from the source deployment. If you need to migrate a deployment to a shard with a different name:

```bash
export OVERRIDE_SHARD="shard2"
```

**TEMP_DIR**: Override the temporary directory for small metadata files

The script uses temporary files only for metadata records (small). Data is streamed directly without intermediate storage.

```bash
export TEMP_DIR="/var/lib/migrations/temp"
```

## Usage

```bash
./migrate_subgraph_deployment.sh <deployment_hash>
```

### Arguments

- `deployment_hash`: The IPFS hash of the subgraph deployment (e.g., `QmXYZ123...`)

### Example

```bash
./migrate_subgraph_deployment.sh QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5
```

## What the Script Does

### 1. Pre-flight Checks

- Validates required environment variables
- Tests connectivity to all databases
- Verifies the deployment exists in the source and is active
- Confirms the deployment doesn't already exist in the target

### 2. Deployment Information Gathering

- Retrieves deployment metadata from source `deployment_schemas` table
- Gets the next available ID from `deployment_schemas_id_seq` on target
- Generates the new schema name (e.g., `sgd123` where 123 is the new ID)

### 3. Metadata Migration

Migrates to **metadata DB (primary) only**:

- `deployment_schemas` - with new ID and schema name
- `subgraphs.subgraph_version` - version records
- `subgraphs.subgraph` - subgraph entry

Migrates to **data DB (shard) only**:

- `subgraphs.head` - block head tracking
- `subgraphs.deployment` - deployment state and sync status
- `subgraphs.subgraph_manifest` - deployment manifest and configuration
- `subgraphs.subgraph_error` - any error records
- `subgraphs.graph_node_versions` - version tracking

Migrates to **both databases**:

- `subgraphs.subgraph_deployment_assignment` - node assignments
- `subgraphs.subgraph_features` - feature flags
- `subgraphs.dynamic_ethereum_contract_data_source` - dynamic data sources

### 4. Data Migration

- Streams the entire schema (tables, data, and indexes) via `pg_dump | psql`
- No intermediate disk storage required - data flows directly between databases
- Schema name is transformed on-the-fly during streaming
- Progress monitoring available with `pv` (shows throughput)

### 5. Consistency Checks

Performs validation:

1. Verifies `deployment_schemas` entry exists with correct information
2. Confirms schema exists in target data database
3. Validates table count matches between source and target
4. Verifies row counts for all tables
5. Confirms `subgraph_manifest` entry exists in data DB
6. Validates `deployment_schemas_id_seq` was properly incremented

### 6. Summary Report

Generates a summary including:

- Deployment hash
- Source and target schema names
- Source and target IDs
- Network and shard information
- List of all migrated tables

## Important Notes

### Streaming Data Transfer

Data is streamed directly from source to target using `pg_dump | psql`. This means:
- No disk space required for data (only small metadata temp files)
- Migration of very large deployments (hundreds of GB) is supported
- Network bandwidth is the primary bottleneck

### Active Deployments Only

The script only migrates deployments marked as `active = true` in the source `deployment_schemas` table.

### Schema Name Mapping

- **Source**: `sgd<source_id>` (e.g., `sgd42`)
- **Target**: `sgd<target_id>` (e.g., `sgd123`)

All references to the schema name are automatically updated during migration.

### Rollback Considerations

This script does NOT automatically rollback on failure. If migration fails partway through:

1. Check the consistency check output to see what succeeded
2. Manually clean up the target if needed:
   ```sql
   -- On target metadata database
   DELETE FROM deployment_schemas WHERE subgraph = '<deployment_hash>';
   DELETE FROM subgraphs.subgraph_version WHERE deployment = '<deployment_hash>';

   -- On target data database
   DELETE FROM subgraphs.subgraph_manifest WHERE id = <target_id>;
   DELETE FROM subgraphs.deployment WHERE id = <target_id>;
   DROP SCHEMA IF EXISTS sgd<target_id> CASCADE;
   ```

## Troubleshooting

### Connection Issues

If you get connection errors:
- Verify the connection strings are correct
- Check network connectivity: `psql <connection_string> -c "SELECT 1;"`
- Ensure firewall rules allow connections

### Permission Denied

Ensure your database user has:
- `SELECT` on all source tables
- `INSERT` on target metadata tables
- `CREATE` on target data database (for schema creation)
- `USAGE` on sequences

### Row Count Mismatches

If consistency checks report row count mismatches:
1. Check for concurrent writes to source during migration
2. Consider using graphman to pause the subgraph during migration
3. Check PostgreSQL logs for errors

### Deployment Already Exists

```
ERROR: Deployment 'QmXYZ...' already exists in target database
```

The deployment was already migrated. To re-migrate:
1. Delete the existing deployment from target (see Rollback Considerations)
2. Re-run the script

## Safety Features

- **Pre-flight validation**: Checks everything before starting migration
- **User confirmation**: Prompts for confirmation before proceeding
- **Comprehensive logging**: Color-coded output for easy monitoring
- **Consistency checks**: Validates the migration was successful
- **Non-destructive**: Never modifies or deletes source data
- **Duplicate prevention**: Won't migrate if deployment already exists in target
- **Auto-resume**: Automatically resumes paused subgraph on completion or failure

## Performance Considerations

Migration time depends on:
- Size of the subgraph data
- Network bandwidth between source and target
- Database server performance

### Progress Monitoring

If `pv` is installed, the script displays real-time throughput during data transfer:
```
32.6MiB 0:00:01 [31.7MiB/s]
```

Install with: `apt-get install pv`

### Large Deployments

For large deployments (100GB+):
- Data streams directly without disk storage requirements
- Network throughput is the primary factor
- Consider running during low-traffic periods
- Monitor disk space on target for the final data

## Batch Migration

For migrating multiple deployments, use the included batch script:

```bash
./batch_migrate.sh deployment_list.txt
```

Where `deployment_list.txt` contains one deployment hash per line. Multiple instances with different ENV variables can be run in the same working directory without issue.

## Troubleshooting

For issues or questions:
1. Check the troubleshooting section above
2. Review the consistency check output for specific failures
3. Examine PostgreSQL logs on both source and target