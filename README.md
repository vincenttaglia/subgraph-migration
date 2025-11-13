# Subgraph Deployment Migration Script

A comprehensive bash script for migrating specific subgraph deployments from one Graph Node database cluster to another.

## Overview

This script handles the complete migration of subgraph deployments between sharded database clusters, including:

- Metadata migration (deployment_schemas, subgraph tables)
- Data schema migration (sgdXXX schemas and all tables)
- Automatic ID sequence management
- Data consistency verification
- Support for separate metadata and data databases

## Prerequisites

- PostgreSQL client tools (`psql`, `pg_dump`)
- Appropriate database permissions for reading and writing
- Network connectivity to all database instances
- Sufficient disk space in `/tmp` for temporary export files

## Database Structure

The script works with Graph Node's sharded architecture:

- **Metadata Database**: Contains `deployment_schemas`, `subgraphs.subgraph_manifest`, `subgraphs.subgraph_deployment`, and related metadata tables
- **Data Database**: Contains the actual subgraph data in schemas named `sgdXXX` where XXX corresponds to the `id` in `deployment_schemas`

## Setup

### Configure Environment Variables

Set the following required environment variables with your database connection strings:

```bash
export SOURCE_METADATA_DB="postgresql://user:password@source-host:5432/graph-metadata"
export SOURCE_DATA_DB="postgresql://user:password@source-host:5432/graph-data"
export TARGET_METADATA_DB="postgresql://user:password@target-host:5432/graph-metadata"
export TARGET_DATA_DB="postgresql://user:password@target-host:5432/graph-data"
```

Connection string format:
```
postgresql://[user[:password]@][host][:port][/dbname][?param1=value1&...]
```

#### Optional Environment Variables

**OVERRIDE_SHARD**: Override the shard value for the target deployment

By default, the script preserves the shard value from the source deployment. If you need to migrate a deployment to a different shard in the target database, set this variable:

```bash
export OVERRIDE_SHARD="shard2"
```

This is useful when:
- Rebalancing deployments across shards
- Migrating to a cluster with different shard naming conventions
- Moving deployments to specific shards for performance optimization

Example:
```bash
# Migrate deployment from "primary" shard to "shard2"
export OVERRIDE_SHARD="shard2"
./migrate_subgraph_deployment.sh QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5
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

- Validates all required environment variables are set
- Tests connectivity to all four databases
- Verifies the deployment exists in the source and is active
- Confirms the deployment doesn't already exist in the target

### 2. Deployment Information Gathering

- Retrieves deployment metadata from source `deployment_schemas` table
- Gets the next available ID from `deployment_schemas_id_seq` on target
- Generates the new schema name (e.g., `sgd123` where 123 is the new ID)

### 3. Metadata Migration

Migrates the following tables from source to target metadata database:

- `deployment_schemas` - with new ID and schema name
- `subgraphs.subgraph_manifest` - deployment manifest and configuration (with new ID matching deployment_schemas)
- `subgraphs.deployment` - deployment state and sync status
- `subgraphs.subgraph_error` - any error records
- `subgraphs.dynamic_ethereum_contract_data_source` - dynamic data sources

### 4. Data Migration

- Creates the new schema in the target data database
- Migrates the complete schema structure (tables, indexes, constraints)
- Copies all data from each table
- Verifies row counts match for each table

### 5. Consistency Checks

Performs comprehensive validation:

1. Verifies `deployment_schemas` entry exists with correct information
2. Confirms schema exists in target data database
3. Validates table count matches between source and target
4. Verifies row counts for all tables
5. Confirms `subgraph_manifest` entry exists
6. Validates `deployment_schemas_id_seq` was properly incremented

### 6. Summary Report

Generates a detailed summary of the migration including:

- Deployment hash
- Source and target schema names
- Source and target IDs
- Network and shard information
- List of all migrated tables

## Important Notes

### ID Sequence Management

The script automatically:
- Calls `nextval('deployment_schemas_id_seq')` to get the next ID
- Uses this ID for the new deployment_schemas entry
- Generates the schema name as `sgd<ID>`
- The sequence is automatically incremented by the `nextval()` call

### Active Deployments Only

The script only migrates deployments marked as `active = true` in the source `deployment_schemas` table. This ensures you're migrating the current active version.

### Schema Name Mapping

- **Source**: `sgd<source_id>` (e.g., `sgd42`)
- **Target**: `sgd<target_id>` (e.g., `sgd123`)

All references to the schema name are automatically updated during migration.

### Transaction Safety

- Metadata migration is wrapped in a transaction
- If metadata migration fails, it will roll back
- Data migration uses `pg_dump`/`psql` which handles its own consistency

### Rollback Considerations

This script does NOT automatically rollback on failure. If migration fails partway through:

1. Check the consistency check output to see what succeeded
2. Manually clean up the target if needed:
   ```sql
   -- On target metadata database
   DELETE FROM deployment_schemas WHERE subgraph = '<deployment_hash>';
   DELETE FROM subgraphs.subgraph_manifest WHERE id = <target_id>;
   DELETE FROM subgraphs.deployment WHERE deployment = '<deployment_hash>';

   -- On target data database
   DROP SCHEMA IF EXISTS sgd<target_id> CASCADE;
   ```

## Troubleshooting

### Connection Issues

If you get connection errors:
- Verify the connection strings are correct
- Check network connectivity: `psql <connection_string> -c "SELECT 1;"`
- Ensure firewall rules allow connections
- Verify SSL/TLS settings if required

### Permission Denied

Ensure your database user has:
- `SELECT` on all source tables
- `INSERT` on target metadata tables
- `CREATE` on target data database (for schema creation)
- `USAGE` on sequences

### Row Count Mismatches

If consistency checks report row count mismatches:
1. Check for concurrent writes to source during migration
2. Verify no triggers or constraints prevented data insertion
3. Check PostgreSQL logs for errors
4. Re-run the migration on an idle source

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

## Performance Considerations

Migration time depends on:
- Size of the subgraph data
- Network bandwidth between source and target
- Database server performance
- Number of tables and indexes

For large deployments (>100GB):
- Consider running during low-traffic periods
- Monitor disk space on target
- Use connection pooling if available
- Consider parallel table migration for very large deployments (requires script modification)

## Example Session

```bash
$ export SOURCE_METADATA_DB="postgresql://graph@source-db:5432/graph"
$ export SOURCE_DATA_DB="postgresql://graph@source-db:5432/graph"
$ export TARGET_METADATA_DB="postgresql://graph@target-db:5432/graph"
$ export TARGET_DATA_DB="postgresql://graph@target-db:5432/graph"

$ ./migrate_subgraph_deployment.sh QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5

========================================
Subgraph Deployment Migration Tool
========================================

[INFO] Checking environment variables...
[SUCCESS] All required environment variables are set
[INFO] Validating database connectivity...
[SUCCESS] All database connections validated
[INFO] Checking if deployment 'QmYg7...' exists in source...
[SUCCESS] Deployment found in source database
[INFO] Checking if deployment already exists in target...
[SUCCESS] Deployment does not exist in target (safe to proceed)
[INFO] Retrieving deployment information from source...
[SUCCESS] Retrieved deployment info: schema=sgd42, shard=primary, network=mainnet
[INFO] Getting next deployment_schemas ID for target...
[SUCCESS] Next deployment ID: 123
[INFO] Generating target schema name...
[SUCCESS] Target schema name: sgd123
[INFO] Determining target shard...
[SUCCESS] Using source shard: primary

[WARNING] About to migrate deployment:
  Deployment:    QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5
  Source Schema: sgd42 (ID: 42)
  Target Schema: sgd123 (ID: 123)
  Source Shard:  primary
  Target Shard:  primary

Proceed with migration? (y/N): y

[INFO] Starting migration...
[INFO] Migrating metadata for deployment 'QmYg7...'
[INFO] Inserting into deployment_schemas...
[INFO] Migrating subgraph_manifest...
[INFO] Migrating subgraph_deployment...
[INFO] Migrating subgraph_error records...
[INFO] Migrating dynamic ethereum contract data sources...
[SUCCESS] Metadata migration completed
[INFO] Starting data migration for deployment 'QmYg7...'
[INFO] Retrieving table list from source schema 'sgd42'...
[SUCCESS] Found 15 tables in source schema
[INFO] Creating target schema 'sgd123' in data database...
[SUCCESS] Schema created
[INFO] Migrating schema structure from 'sgd42' to 'sgd123'...
[SUCCESS] Schema structure migrated
[INFO] Migrating data for table 'poi2$'...
[INFO] Table has 50000 rows
[SUCCESS] Table 'poi2$' migrated successfully (50000 rows)
[INFO] Migrating data for table 'transfer'...
[INFO] Table has 1000000 rows
[SUCCESS] Table 'transfer' migrated successfully (1000000 rows)
...
[SUCCESS] Data migration completed

[INFO] Performing data consistency checks...
[INFO] Check 1: Verifying deployment_schemas entry...
[SUCCESS] deployment_schemas entry verified
[INFO] Check 2: Verifying schema exists in data database...
[SUCCESS] Schema exists in data database
[INFO] Check 3: Verifying table count...
[SUCCESS] Table count verified: 15 tables
[INFO] Check 4: Verifying row counts for all tables...
[INFO] Table 'poi2$': 50000 rows verified
[INFO] Table 'transfer': 1000000 rows verified
...
[SUCCESS] All row counts verified
[INFO] Check 5: Verifying subgraph_manifest entry...
[SUCCESS] subgraph_manifest entry verified
[INFO] Check 6: Verifying deployment_schemas_id_seq...
[SUCCESS] Sequence verified: current value is 123

[SUCCESS] All consistency checks passed!

========================================
Migration Summary
========================================
Deployment Hash:    QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5
Source Schema:      sgd42
Target Schema:      sgd123
Source ID:          42
Target ID:          123
Network:            mainnet
Source Shard:       primary
Target Shard:       primary

Tables Migrated:    15

Tables:
  - poi2$
  - transfer
  - token
  - account
  ...
========================================

[SUCCESS] Migration completed successfully!
```

## Advanced Usage

### Migrating Multiple Deployments

Create a wrapper script to migrate multiple deployments:

```bash
#!/bin/bash

deployments=(
    "QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5"
    "QmXYZ123..."
    "QmABC456..."
)

for deployment in "${deployments[@]}"; do
    echo "Migrating $deployment..."
    ./migrate_subgraph_deployment.sh "$deployment"
    if [ $? -eq 0 ]; then
        echo "✓ $deployment migrated successfully"
    else
        echo "✗ $deployment migration failed"
        exit 1
    fi
done
```

### Migrating to Different Shards

You can migrate deployments to specific shards using the `OVERRIDE_SHARD` environment variable:

```bash
#!/bin/bash

# Migrate deployments to different shards for load balancing
export OVERRIDE_SHARD="shard1"
./migrate_subgraph_deployment.sh QmYg7FibZJJDvS4PZu8kXF5iCkCqGH7PjCPjXP8gZiH5J5

export OVERRIDE_SHARD="shard2"
./migrate_subgraph_deployment.sh QmXYZ123...

export OVERRIDE_SHARD="shard3"
./migrate_subgraph_deployment.sh QmABC456...

# Or migrate all to the same shard
export OVERRIDE_SHARD="primary"
for deployment in "${deployments[@]}"; do
    ./migrate_subgraph_deployment.sh "$deployment"
done
```

### Dry Run Mode

To test without making changes, you can modify the script to add a `DRY_RUN` variable at the top:

```bash
DRY_RUN=true  # Set to false for actual migration
```

Then wrap all write operations in conditionals.

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review the consistency check output for specific failures
3. Examine PostgreSQL logs on both source and target
4. Verify the Graph Node schema documentation: https://github.com/graphprotocol/graph-node

## License

This script is provided as-is for use with Graph Node database migrations.
