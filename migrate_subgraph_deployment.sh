#!/bin/bash

################################################################################
# Subgraph Deployment Migration Script
#
# Purpose: Migrate specific subgraph deployments from one sharded database
#          cluster to another, handling both metadata and data schemas.
#
# Usage: ./migrate_subgraph_deployment.sh <deployment_hash>
#
# Environment Variables Required:
#   SOURCE_METADATA_DB - Source metadata database connection string
#   SOURCE_DATA_DB     - Source data database connection string
#   TARGET_METADATA_DB - Target metadata database connection string
#   TARGET_DATA_DB     - Target data database connection string
#
# Optional Environment Variables:
#   OVERRIDE_SHARD     - Override the shard value for the target deployment
#                        (defaults to source shard if not set)
#   TEMP_DIR           - Override the temporary directory for migration files
#                        (defaults to /tmp/subgraph_migration_$$)
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check required environment variables
check_environment() {
    log_info "Checking environment variables..."

    local required_vars=(
        "SOURCE_METADATA_DB"
        "SOURCE_DATA_DB"
        "TARGET_METADATA_DB"
        "TARGET_DATA_DB"
    )

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi

    log_success "All required environment variables are set"
}

# Function to setup temporary directory
setup_temp_dir() {
    if [[ -n "${TEMP_DIR:-}" ]]; then
        # Use user-specified temp directory
        export MIGRATION_TEMP_DIR="$TEMP_DIR"
        log_info "Using custom temp directory: $MIGRATION_TEMP_DIR"
    else
        # Use default temp directory with process ID
        export MIGRATION_TEMP_DIR="/tmp/subgraph_migration_$$"
        log_info "Using default temp directory: $MIGRATION_TEMP_DIR"
    fi

    # Create the directory if it doesn't exist
    if [[ ! -d "$MIGRATION_TEMP_DIR" ]]; then
        mkdir -p "$MIGRATION_TEMP_DIR" || {
            log_error "Failed to create temp directory: $MIGRATION_TEMP_DIR"
            exit 1
        }
        log_success "Temp directory created"
    else
        log_success "Temp directory already exists"
    fi
}

# Function to cleanup temporary directory
cleanup_temp_dir() {
    if [[ -d "$MIGRATION_TEMP_DIR" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$MIGRATION_TEMP_DIR"
        log_success "Temp directory cleaned up"
    fi
}

# Function to validate database connectivity
validate_connectivity() {
    log_info "Validating database connectivity..."

    if ! psql "$SOURCE_METADATA_DB" -c "SELECT 1;" &>/dev/null; then
        log_error "Cannot connect to source metadata database"
        exit 1
    fi

    if ! psql "$SOURCE_DATA_DB" -c "SELECT 1;" &>/dev/null; then
        log_error "Cannot connect to source data database"
        exit 1
    fi

    if ! psql "$TARGET_METADATA_DB" -c "SELECT 1;" &>/dev/null; then
        log_error "Cannot connect to target metadata database"
        exit 1
    fi

    if ! psql "$TARGET_DATA_DB" -c "SELECT 1;" &>/dev/null; then
        log_error "Cannot connect to target data database"
        exit 1
    fi

    log_success "All database connections validated"
}

# Function to check if deployment exists in source
check_deployment_exists() {
    local deployment_hash=$1

    log_info "Checking if deployment '$deployment_hash' exists in source..."

    local exists=$(psql "$SOURCE_METADATA_DB" -t -A -c "
        SELECT COUNT(*)
        FROM deployment_schemas
        WHERE subgraph = '$deployment_hash' AND active = true;
    ")

    if [[ $exists -eq 0 ]]; then
        log_error "Deployment '$deployment_hash' not found or not active in source database"
        exit 1
    fi

    log_success "Deployment found in source database"
}

# Function to check if deployment already exists in target
check_deployment_not_in_target() {
    local deployment_hash=$1

    log_info "Checking if deployment already exists in target..."

    local exists=$(psql "$TARGET_METADATA_DB" -t -A -c "
        SELECT COUNT(*)
        FROM deployment_schemas
        WHERE subgraph = '$deployment_hash';
    ")

    if [[ $exists -gt 0 ]]; then
        log_error "Deployment '$deployment_hash' already exists in target database"
        exit 1
    fi

    log_success "Deployment does not exist in target (safe to proceed)"
}

# Function to get deployment information from source
get_deployment_info() {
    local deployment_hash=$1

    log_info "Retrieving deployment information from source..."

    # Get deployment_schemas info
    local query="
        SELECT
            id,
            subgraph,
            name,
            shard,
            version,
            network,
            active,
            created_at
        FROM deployment_schemas
        WHERE subgraph = '$deployment_hash' AND active = true
        LIMIT 1;
    "

    local result=$(psql "$SOURCE_METADATA_DB" -t -A -F'|' -c "$query")

    if [[ -z "$result" ]]; then
        log_error "Failed to retrieve deployment information"
        exit 1
    fi

    # Parse result into variables
    IFS='|' read -r SOURCE_ID SOURCE_SUBGRAPH SOURCE_NAME SOURCE_SHARD \
                     SOURCE_VERSION SOURCE_NETWORK SOURCE_ACTIVE SOURCE_CREATED_AT <<< "$result"

    export SOURCE_ID SOURCE_SUBGRAPH SOURCE_NAME SOURCE_SHARD \
           SOURCE_VERSION SOURCE_NETWORK SOURCE_ACTIVE SOURCE_CREATED_AT

    log_success "Retrieved deployment info: schema=$SOURCE_NAME, shard=$SOURCE_SHARD, network=$SOURCE_NETWORK"
}

# Function to get next deployment_schemas ID for target
get_next_deployment_id() {
    log_info "Getting next deployment_schemas ID for target..."

    local next_id=$(psql "$TARGET_METADATA_DB" -t -A -c "
        SELECT nextval('deployment_schemas_id_seq');
    ")

    if [[ -z "$next_id" ]]; then
        log_error "Failed to get next deployment ID"
        exit 1
    fi

    export TARGET_ID=$next_id
    log_success "Next deployment ID: $TARGET_ID"
}

# Function to generate new schema name for target
generate_target_schema_name() {
    log_info "Generating target schema name..."

    # Schema names are typically sgd<id>, so we use the new target ID
    export TARGET_NAME="sgd${TARGET_ID}"

    log_success "Target schema name: $TARGET_NAME"
}

# Function to determine target shard
determine_target_shard() {
    log_info "Determining target shard..."

    if [[ -n "${OVERRIDE_SHARD:-}" ]]; then
        export TARGET_SHARD="$OVERRIDE_SHARD"
        log_success "Using override shard: $TARGET_SHARD (source was: $SOURCE_SHARD)"
    else
        export TARGET_SHARD="$SOURCE_SHARD"
        log_success "Using source shard: $TARGET_SHARD"
    fi
}

# Function to migrate metadata tables
migrate_metadata() {
    local deployment_hash=$1

    log_info "Migrating metadata for deployment '$deployment_hash'..."

    # Insert into deployment_schemas with new ID and schema name
    log_info "Inserting into deployment_schemas..."
    psql "$TARGET_METADATA_DB" -c "
        INSERT INTO deployment_schemas (id, created_at, subgraph, name, shard, version, network, active)
        VALUES (
            $TARGET_ID,
            '$SOURCE_CREATED_AT',
            '$SOURCE_SUBGRAPH',
            '$TARGET_NAME',
            '$TARGET_SHARD',
            '$SOURCE_VERSION',
            '$SOURCE_NETWORK',
            '$SOURCE_ACTIVE'
        );
    "

    # Migrate graph_node_versions (if referenced by manifest and not already in target)
    log_info "Migrating graph_node_versions..."

    # Get the version ID needed by this deployment (with error handling)
    local version_id=""
    version_id=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT graph_node_version_id
        FROM subgraphs.subgraph_manifest
        WHERE id = $SOURCE_ID;
    " 2>&1) || {
        log_warning "Could not query graph_node_version_id: $version_id"
        version_id=""
    }

    # Trim whitespace
    version_id=$(echo "$version_id" | xargs 2>/dev/null || echo "")

    if [ -n "$version_id" ] && [ "$version_id" != "" ]; then
        log_info "Found graph_node_version_id: $version_id"

        # Check if this version already exists in target (check data DB)
        local version_exists=$(psql "$TARGET_DATA_DB" -t -A -c "
            SELECT COUNT(*) FROM subgraphs.graph_node_versions WHERE id = $version_id;
        " 2>&1) || {
            log_warning "Could not check if version exists in target data DB"
            version_exists="0"
        }

        # Also check metadata DB
        local version_exists_metadata=$(psql "$TARGET_METADATA_DB" -t -A -c "
            SELECT COUNT(*) FROM subgraphs.graph_node_versions WHERE id = $version_id;
        " 2>&1) || {
            log_warning "Could not check if version exists in target metadata DB"
            version_exists_metadata="0"
        }

        # If exists in either, skip migration
        if [ "$version_exists" != "0" ] || [ "$version_exists_metadata" != "0" ]; then
            version_exists="1"
        fi

        if [ "$version_exists" = "0" ]; then
            log_info "Migrating graph_node_version $version_id..."
            # Version doesn't exist, migrate it
            psql "$SOURCE_DATA_DB" -c "
                COPY (SELECT * FROM subgraphs.graph_node_versions WHERE id = $version_id)
                TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
            " > "$MIGRATION_TEMP_DIR/graph_node_versions.tsv" 2>&1 || {
                log_warning "Could not export graph_node_version"
            }

            if [ -s "$MIGRATION_TEMP_DIR/graph_node_versions.tsv" ]; then
                log_info "Importing graph_node_version to data database..."
                cat "$MIGRATION_TEMP_DIR/graph_node_versions.tsv" | psql "$TARGET_DATA_DB" -c "
                    COPY subgraphs.graph_node_versions FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
                " 2>&1 | grep -v "^COPY" || true

                log_info "Importing graph_node_version to metadata database..."
                cat "$MIGRATION_TEMP_DIR/graph_node_versions.tsv" | psql "$TARGET_METADATA_DB" -c "
                    COPY subgraphs.graph_node_versions FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
                " 2>&1 | grep -v "^COPY" || true

                log_info "Graph node version $version_id migrated"
            else
                log_warning "No graph_node_version data to migrate"
            fi
        else
            log_info "Graph node version $version_id already exists in target (skipped)"
        fi
    else
        log_info "No graph node version to migrate"
    fi

    # Migrate subgraphs.head (required by deployment FK)
    log_info "Migrating subgraph head..."

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.head WHERE id = $SOURCE_ID)
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/head_source.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/head_source.tsv" ]; then
        # Replace the source ID with target ID using Python for CSV parsing
        python3 -c "
import csv
target_id = '${TARGET_ID}'.strip()
with open('$MIGRATION_TEMP_DIR/head_source.tsv', 'r') as infile, \
     open('$MIGRATION_TEMP_DIR/head.tsv', 'w') as outfile:
    reader = csv.reader(infile, delimiter='\t')
    writer = csv.writer(outfile, delimiter='\t', lineterminator='\n')
    for row in reader:
        if row:  # Just check row exists
            row[0] = target_id  # Replace ID unconditionally
        writer.writerow(row)
"
        log_info "Importing head to data database..."
        cat "$MIGRATION_TEMP_DIR/head.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.head FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_info "Head record already exists in data DB (ignored)"

        log_info "Importing head to metadata database..."
        cat "$MIGRATION_TEMP_DIR/head.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.head FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_info "Head record already exists in metadata DB (ignored)"
    else
        log_info "No head record found (will be created by graph-node)"
    fi

    # Migrate subgraphs.deployment with new ID (MUST be before manifest due to FK)
    log_info "Migrating subgraph deployment record..."

    # First, get the column order to understand the structure
    log_info "Getting column structure for subgraphs.deployment..."
    local deployment_columns=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'subgraphs' AND table_name = 'deployment';
    ")
    log_info "Deployment table columns: $deployment_columns"

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.deployment WHERE subgraph = '$deployment_hash')
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/deployment_source.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/deployment_source.tsv" ]; then
        # Debug: show the source data
        log_info "Source deployment data:"
        cat "$MIGRATION_TEMP_DIR/deployment_source.tsv"

        # CSV format may quote fields, use python for reliable CSV parsing and field replacement
        # Note: We need to find which column is the 'id' field
        python3 -c "
import sys
import csv

target_id = '${TARGET_ID}'.strip()
columns = '${deployment_columns}'.split(', ')

# Find the index of the 'id' column
try:
    id_index = columns.index('id')
except ValueError:
    print('ERROR: Could not find id column in deployment table', file=sys.stderr)
    sys.exit(1)

print(f'DEBUG: ID column is at index {id_index}', file=sys.stderr)

with open('$MIGRATION_TEMP_DIR/deployment_source.tsv', 'r') as infile, \
     open('$MIGRATION_TEMP_DIR/deployment.tsv', 'w') as outfile:
    reader = csv.reader(infile, delimiter='\t')
    writer = csv.writer(outfile, delimiter='\t', lineterminator='\n')

    for row in reader:
        if row and len(row) > id_index:
            print(f'DEBUG: Replacing row[{id_index}]={row[id_index]} with {target_id}', file=sys.stderr)
            row[id_index] = target_id
        writer.writerow(row)
"

        # Debug: show the transformed data
        log_info "Transformed deployment data:"
        cat "$MIGRATION_TEMP_DIR/deployment.tsv"

        log_info "Importing deployment to data database..."
        cat "$MIGRATION_TEMP_DIR/deployment.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.deployment FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Deployment record may already exist in data DB (ignored)"

        log_info "Importing deployment to metadata database..."
        cat "$MIGRATION_TEMP_DIR/deployment.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.deployment FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Deployment record may already exist in metadata DB (ignored)"

        # Verify what we just inserted
        log_info "Verifying deployment record in target databases..."
        psql "$TARGET_DATA_DB" -c "SELECT id, subgraph FROM subgraphs.deployment WHERE subgraph = '$deployment_hash';"
        psql "$TARGET_METADATA_DB" -c "SELECT id, subgraph FROM subgraphs.deployment WHERE subgraph = '$deployment_hash';"
    else
        log_info "No deployment record found (will be created by graph-node)"
    fi

    # Migrate subgraphs.subgraph_manifest with new ID (AFTER deployment due to FK)
    log_info "Migrating subgraph_manifest..."

    # Get column structure for manifest table
    log_info "Getting column structure for subgraphs.subgraph_manifest..."
    local manifest_columns=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'subgraphs' AND table_name = 'subgraph_manifest';
    ")
    log_info "Manifest table columns: $manifest_columns"

    # Use COPY to export with proper NULL handling
    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.subgraph_manifest WHERE id = $SOURCE_ID)
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/manifest_source.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/manifest_source.tsv" ]; then
        # Debug: show the source data
        log_info "Source manifest data (first 200 chars):"
        head -c 200 "$MIGRATION_TEMP_DIR/manifest_source.tsv"
        echo ""

        # Replace the source ID with target ID using Python for CSV parsing
        python3 -c "
import sys
import csv

target_id = '${TARGET_ID}'.strip()
columns = '${manifest_columns}'.split(', ')

# Find the index of the 'id' column
try:
    id_index = columns.index('id')
except ValueError:
    print('ERROR: Could not find id column in manifest table', file=sys.stderr)
    sys.exit(1)

print(f'DEBUG: Manifest ID column is at index {id_index}', file=sys.stderr)

with open('$MIGRATION_TEMP_DIR/manifest_source.tsv', 'r') as infile, \
     open('$MIGRATION_TEMP_DIR/manifest.tsv', 'w') as outfile:
    reader = csv.reader(infile, delimiter='\t')
    writer = csv.writer(outfile, delimiter='\t', lineterminator='\n')
    for row in reader:
        if row and len(row) > id_index:
            print(f'DEBUG: Replacing manifest row[{id_index}]={row[id_index]} with {target_id}', file=sys.stderr)
            row[id_index] = target_id
        writer.writerow(row)
"
        # Debug: show the transformed data
        log_info "Transformed manifest data (first 200 chars):"
        head -c 200 "$MIGRATION_TEMP_DIR/manifest.tsv"
        echo ""

        # Import to both metadata and data databases
        log_info "Importing manifest to data database..."
        cat "$MIGRATION_TEMP_DIR/manifest.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.subgraph_manifest FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Manifest may already exist in data DB (ignored)"

        log_info "Importing manifest to metadata database..."
        cat "$MIGRATION_TEMP_DIR/manifest.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.subgraph_manifest FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Manifest may already exist in metadata DB (ignored)"
    else
        log_warning "No manifest data found for deployment"
    fi

    # Migrate subgraphs.subgraph_error (if any)
    log_info "Migrating subgraph_error records..."

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.subgraph_error WHERE subgraph_id = '$deployment_hash')
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/errors.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/errors.tsv" ]; then
        log_info "Importing errors to data database..."
        cat "$MIGRATION_TEMP_DIR/errors.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.subgraph_error FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some errors may already exist in data DB (ignored)"

        log_info "Importing errors to metadata database..."
        cat "$MIGRATION_TEMP_DIR/errors.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.subgraph_error FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some errors may already exist in metadata DB (ignored)"
    else
        log_info "No subgraph errors to migrate"
    fi

    # Migrate subgraphs.subgraph_features (if any)
    log_info "Migrating subgraph_features records..."

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.subgraph_features WHERE id = $SOURCE_ID)
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/features_source.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/features_source.tsv" ]; then
        # Replace the source ID with target ID
        sed "s/^$SOURCE_ID\t/$TARGET_ID\t/" "$MIGRATION_TEMP_DIR/features_source.tsv" > "$MIGRATION_TEMP_DIR/features.tsv"

        log_info "Importing features to data database..."
        cat "$MIGRATION_TEMP_DIR/features.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.subgraph_features FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some features may already exist in data DB (ignored)"

        log_info "Importing features to metadata database..."
        cat "$MIGRATION_TEMP_DIR/features.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.subgraph_features FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some features may already exist in metadata DB (ignored)"
    else
        log_info "No subgraph features to migrate"
    fi

    # Migrate dynamic data sources (if any)
    log_info "Migrating dynamic ethereum contract data sources..."

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.dynamic_ethereum_contract_data_source WHERE deployment = '$deployment_hash')
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/dynamic_sources.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/dynamic_sources.tsv" ]; then
        log_info "Importing dynamic sources to data database..."
        cat "$MIGRATION_TEMP_DIR/dynamic_sources.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.dynamic_ethereum_contract_data_source FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some dynamic sources may already exist in data DB (ignored)"

        log_info "Importing dynamic sources to metadata database..."
        cat "$MIGRATION_TEMP_DIR/dynamic_sources.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.dynamic_ethereum_contract_data_source FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Some dynamic sources may already exist in metadata DB (ignored)"
    else
        log_info "No dynamic data sources to migrate"
    fi

    # Migrate subgraphs.subgraph_version (deployment to subgraph mapping)
    log_info "Migrating subgraph_version..."

    # Get column structure for subgraph_version table
    local version_columns=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'subgraphs' AND table_name = 'subgraph_version';
    ")
    log_info "Subgraph_version table columns: $version_columns"

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.subgraph_version WHERE deployment = '$deployment_hash')
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/subgraph_version.tsv"

    local subgraph_id=""
    if [ -s "$MIGRATION_TEMP_DIR/subgraph_version.tsv" ]; then
        # Extract the subgraph ID from the subgraph_version record using column-aware approach
        subgraph_id=$(python3 -c "
import sys
import csv

columns = '${version_columns}'.split(', ')

# Find the index of the 'subgraph' column
try:
    subgraph_index = columns.index('subgraph')
except ValueError:
    print('ERROR: Could not find subgraph column in subgraph_version table', file=sys.stderr)
    sys.exit(1)

with open('$MIGRATION_TEMP_DIR/subgraph_version.tsv', 'r') as infile:
    reader = csv.reader(infile, delimiter='\t')
    for row in reader:
        if row and len(row) > subgraph_index:
            print(row[subgraph_index], end='')
        break
")

        log_info "Found subgraph_id: $subgraph_id"

        log_info "Importing subgraph_version to data database..."
        cat "$MIGRATION_TEMP_DIR/subgraph_version.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.subgraph_version FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Subgraph version may already exist in data DB (ignored)"

        log_info "Importing subgraph_version to metadata database..."
        cat "$MIGRATION_TEMP_DIR/subgraph_version.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.subgraph_version FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Subgraph version may already exist in metadata DB (ignored)"
    else
        log_info "No subgraph_version to migrate"
    fi

    # Migrate subgraphs.subgraph (if we found a subgraph_id)
    if [ -n "$subgraph_id" ] && [ "$subgraph_id" != "" ]; then
        log_info "Migrating subgraph entry for id=$subgraph_id..."

        psql "$SOURCE_DATA_DB" -c "
            COPY (SELECT * FROM subgraphs.subgraph WHERE id = '$subgraph_id')
            TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " > "$MIGRATION_TEMP_DIR/subgraph.tsv"

        if [ -s "$MIGRATION_TEMP_DIR/subgraph.tsv" ]; then
            log_info "Importing subgraph to data database..."
            cat "$MIGRATION_TEMP_DIR/subgraph.tsv" | psql "$TARGET_DATA_DB" -c "
                COPY subgraphs.subgraph FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
            " 2>&1 | grep -v "^COPY" || log_warning "Subgraph entry may already exist in data DB (ignored)"

            log_info "Importing subgraph to metadata database..."
            cat "$MIGRATION_TEMP_DIR/subgraph.tsv" | psql "$TARGET_METADATA_DB" -c "
                COPY subgraphs.subgraph FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
            " 2>&1 | grep -v "^COPY" || log_warning "Subgraph entry may already exist in metadata DB (ignored)"
        else
            log_info "No subgraph entry found"
        fi
    else
        log_info "No subgraph_id found, skipping subgraph migration"
    fi

    # Migrate subgraphs.subgraph_deployment_assignment (node assignments)
    log_info "Migrating deployment assignments..."

    # Get column structure for assignment table
    log_info "Getting column structure for subgraphs.subgraph_deployment_assignment..."
    local assignment_columns=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'subgraphs' AND table_name = 'subgraph_deployment_assignment';
    ")
    log_info "Assignment table columns: $assignment_columns"

    psql "$SOURCE_DATA_DB" -c "
        COPY (SELECT * FROM subgraphs.subgraph_deployment_assignment WHERE id = $SOURCE_ID)
        TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
    " > "$MIGRATION_TEMP_DIR/assignment_source.tsv"

    if [ -s "$MIGRATION_TEMP_DIR/assignment_source.tsv" ]; then
        # Replace the source ID with target ID using Python for CSV parsing
        # Note: We only replace the 'id' column, NOT the 'node_id' column
        python3 -c "
import sys
import csv

target_id = '${TARGET_ID}'.strip()
columns = '${assignment_columns}'.split(', ')

# Find the index of the 'id' column (deployment ID, not node_id)
try:
    id_index = columns.index('id')
except ValueError:
    print('ERROR: Could not find id column in assignment table', file=sys.stderr)
    sys.exit(1)

print(f'DEBUG: Assignment ID column is at index {id_index}', file=sys.stderr)

with open('$MIGRATION_TEMP_DIR/assignment_source.tsv', 'r') as infile, \
     open('$MIGRATION_TEMP_DIR/assignment.tsv', 'w') as outfile:
    reader = csv.reader(infile, delimiter='\t')
    writer = csv.writer(outfile, delimiter='\t', lineterminator='\n')
    for row in reader:
        if row and len(row) > id_index:
            print(f'DEBUG: Replacing assignment row[{id_index}]={row[id_index]} with {target_id}', file=sys.stderr)
            row[id_index] = target_id
        writer.writerow(row)
"
        log_info "Importing deployment assignment to data database..."
        cat "$MIGRATION_TEMP_DIR/assignment.tsv" | psql "$TARGET_DATA_DB" -c "
            COPY subgraphs.subgraph_deployment_assignment FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Deployment assignment may already exist in data DB (ignored)"

        log_info "Importing deployment assignment to metadata database..."
        cat "$MIGRATION_TEMP_DIR/assignment.tsv" | psql "$TARGET_METADATA_DB" -c "
            COPY subgraphs.subgraph_deployment_assignment FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', NULL '\\N', ENCODING 'UTF8');
        " 2>&1 | grep -v "^COPY" || log_warning "Deployment assignment may already exist in metadata DB (ignored)"
    else
        log_info "No deployment assignment to migrate"
    fi

    log_success "Metadata migration completed"
}

# Function to create target schema in data database
create_target_schema() {
    log_info "Creating target schema '$TARGET_NAME' in data database..."

    psql "$TARGET_DATA_DB" -c "CREATE SCHEMA IF NOT EXISTS $TARGET_NAME;"

    log_success "Schema created"
}

# Function to get all tables in source schema
get_source_tables() {
    local schema_name=$1

    log_info "Retrieving table list from source schema '$schema_name'..."

    local tables=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = '$schema_name'
        AND table_type = 'BASE TABLE'
        ORDER BY table_name;
    ")

    if [[ -z "$tables" ]]; then
        log_warning "No tables found in source schema"
        return 1
    fi

    export SOURCE_TABLES="$tables"
    local table_count=$(echo "$tables" | wc -l)
    log_success "Found $table_count tables in source schema"
}

# Function to migrate schema structure
migrate_schema_structure() {
    local source_schema=$1
    local target_schema=$2

    log_info "Migrating schema structure from '$source_schema' to '$target_schema'..."

    # Dump schema structure (without data)
    local temp_schema_file="/tmp/schema_${source_schema}_$$.sql"

    pg_dump "$SOURCE_DATA_DB" \
        --schema="$source_schema" \
        --schema-only \
        --no-owner \
        --no-privileges \
        > "$temp_schema_file"

    # Replace schema name in dump
    sed -i "s/${source_schema}/${target_schema}/g" "$temp_schema_file"

    # Apply schema to target
    psql "$TARGET_DATA_DB" < "$temp_schema_file"

    # Clean up
    rm -f "$temp_schema_file"

    log_success "Schema structure migrated"
}

# Function to migrate table data
migrate_table_data() {
    local source_schema=$1
    local target_schema=$2
    local table=$3

    log_info "Migrating data for table '$table'..."

    # Get row count for progress
    local row_count=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM ${source_schema}.${table};
    ")

    log_info "Table has $row_count rows"

    # Dump and restore data
    pg_dump "$SOURCE_DATA_DB" \
        --schema="$source_schema" \
        --table="${source_schema}.${table}" \
        --data-only \
        --no-owner \
        --no-privileges \
        | sed "s/${source_schema}/${target_schema}/g" \
        | psql "$TARGET_DATA_DB" -q

    # Verify row count
    local target_row_count=$(psql "$TARGET_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM ${target_schema}.${table};
    ")

    if [[ $row_count -ne $target_row_count ]]; then
        log_error "Row count mismatch for table $table: source=$row_count, target=$target_row_count"
        return 1
    fi

    log_success "Table '$table' migrated successfully ($target_row_count rows)"
}

# Function to migrate all data
migrate_data() {
    local deployment_hash=$1

    log_info "Starting data migration for deployment '$deployment_hash'..."

    # Get source tables
    if ! get_source_tables "$SOURCE_NAME"; then
        log_warning "No data to migrate"
        return 0
    fi

    # Create target schema
    create_target_schema

    # Migrate schema structure
    migrate_schema_structure "$SOURCE_NAME" "$TARGET_NAME"

    # Migrate each table
    while IFS= read -r table; do
        migrate_table_data "$SOURCE_NAME" "$TARGET_NAME" "$table"
    done <<< "$SOURCE_TABLES"

    log_success "Data migration completed"
}

# Function to perform consistency checks
perform_consistency_checks() {
    local deployment_hash=$1

    log_info "Performing data consistency checks..."

    local checks_passed=true

    # Check 1: Verify deployment_schemas entry exists
    log_info "Check 1: Verifying deployment_schemas entry..."
    local ds_count=$(psql "$TARGET_METADATA_DB" -t -A -c "
        SELECT COUNT(*) FROM deployment_schemas
        WHERE subgraph = '$deployment_hash' AND name = '$TARGET_NAME';
    ")

    if [[ $ds_count -ne 1 ]]; then
        log_error "deployment_schemas check failed: expected 1 entry, found $ds_count"
        checks_passed=false
    else
        log_success "deployment_schemas entry verified"
    fi

    # Check 2: Verify schema exists in data database
    log_info "Check 2: Verifying schema exists in data database..."
    local schema_exists=$(psql "$TARGET_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM information_schema.schemata
        WHERE schema_name = '$TARGET_NAME';
    ")

    if [[ $schema_exists -ne 1 ]]; then
        log_error "Schema check failed: schema '$TARGET_NAME' not found"
        checks_passed=false
    else
        log_success "Schema exists in data database"
    fi

    # Check 3: Verify table count matches
    log_info "Check 3: Verifying table count..."
    local source_table_count=$(psql "$SOURCE_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = '$SOURCE_NAME' AND table_type = 'BASE TABLE';
    ")

    local target_table_count=$(psql "$TARGET_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = '$TARGET_NAME' AND table_type = 'BASE TABLE';
    ")

    if [[ $source_table_count -ne $target_table_count ]]; then
        log_error "Table count mismatch: source=$source_table_count, target=$target_table_count"
        checks_passed=false
    else
        log_success "Table count verified: $target_table_count tables"
    fi

    # Check 4: Verify row counts for each table
    log_info "Check 4: Verifying row counts for all tables..."
    if [[ -n "$SOURCE_TABLES" ]]; then
        while IFS= read -r table; do
            local source_rows=$(psql "$SOURCE_DATA_DB" -t -A -c "
                SELECT COUNT(*) FROM ${SOURCE_NAME}.${table};
            ")

            local target_rows=$(psql "$TARGET_DATA_DB" -t -A -c "
                SELECT COUNT(*) FROM ${TARGET_NAME}.${table};
            ")

            if [[ $source_rows -ne $target_rows ]]; then
                log_error "Row count mismatch for table $table: source=$source_rows, target=$target_rows"
                checks_passed=false
            else
                log_info "Table '$table': $target_rows rows verified"
            fi
        done <<< "$SOURCE_TABLES"
        log_success "All row counts verified"
    fi

    # Check 5: Verify subgraph_manifest exists with correct ID in both databases
    log_info "Check 5: Verifying subgraph_manifest entry..."

    local manifest_exists_data=$(psql "$TARGET_DATA_DB" -t -A -c "
        SELECT COUNT(*) FROM subgraphs.subgraph_manifest
        WHERE id = $TARGET_ID;
    ")

    local manifest_exists_metadata=$(psql "$TARGET_METADATA_DB" -t -A -c "
        SELECT COUNT(*) FROM subgraphs.subgraph_manifest
        WHERE id = $TARGET_ID;
    ")

    if [[ $manifest_exists_data -ne 1 ]]; then
        log_error "subgraph_manifest check failed in data DB: expected 1 entry, found $manifest_exists_data"
        checks_passed=false
    else
        log_success "subgraph_manifest entry verified in data DB with ID $TARGET_ID"
    fi

    if [[ $manifest_exists_metadata -ne 1 ]]; then
        log_error "subgraph_manifest check failed in metadata DB: expected 1 entry, found $manifest_exists_metadata"
        checks_passed=false
    else
        log_success "subgraph_manifest entry verified in metadata DB with ID $TARGET_ID"
    fi

    # Check 6: Verify deployment_schemas_id_seq is updated
    log_info "Check 6: Verifying deployment_schemas_id_seq..."
    local current_seq=$(psql "$TARGET_METADATA_DB" -t -A -c "
        SELECT last_value FROM deployment_schemas_id_seq;
    ")

    if [[ $current_seq -lt $TARGET_ID ]]; then
        log_error "Sequence not properly updated: current=$current_seq, expected>=$TARGET_ID"
        checks_passed=false
    else
        log_success "Sequence verified: current value is $current_seq"
    fi

    if [[ "$checks_passed" == true ]]; then
        log_success "All consistency checks passed!"
        return 0
    else
        log_error "Some consistency checks failed"
        return 1
    fi
}

# Function to generate migration summary
generate_summary() {
    local deployment_hash=$1

    echo ""
    echo "========================================"
    echo "Migration Summary"
    echo "========================================"
    echo "Deployment Hash:    $deployment_hash"
    echo "Source Schema:      $SOURCE_NAME"
    echo "Target Schema:      $TARGET_NAME"
    echo "Source ID:          $SOURCE_ID"
    echo "Target ID:          $TARGET_ID"
    echo "Network:            $SOURCE_NETWORK"
    echo "Source Shard:       $SOURCE_SHARD"
    echo "Target Shard:       $TARGET_SHARD"
    echo ""

    if [[ -n "$SOURCE_TABLES" ]]; then
        local table_count=$(echo "$SOURCE_TABLES" | wc -l)
        echo "Tables Migrated:    $table_count"
        echo ""
        echo "Tables:"
        echo "$SOURCE_TABLES" | sed 's/^/  - /'
    fi

    echo "========================================"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "Subgraph Deployment Migration Tool"
    echo "========================================"
    echo ""

    # Check arguments
    if [[ $# -ne 1 ]]; then
        log_error "Usage: $0 <deployment_hash>"
        echo ""
        echo "Example:"
        echo "  $0 QmXYZ123..."
        echo ""
        exit 1
    fi

    local deployment_hash=$1

    # Validate deployment hash format (should start with Qm for IPFS)
    if [[ ! "$deployment_hash" =~ ^Qm[a-zA-Z0-9]{44}$ ]]; then
        log_warning "Deployment hash doesn't match typical IPFS format (Qm...)"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Pre-flight checks
    check_environment
    validate_connectivity
    setup_temp_dir
    check_deployment_exists "$deployment_hash"
    check_deployment_not_in_target "$deployment_hash"

    # Setup cleanup trap
    trap cleanup_temp_dir EXIT

    # Get deployment info and prepare target
    get_deployment_info "$deployment_hash"
    get_next_deployment_id
    generate_target_schema_name
    determine_target_shard

    # Confirmation
    echo ""
    log_warning "About to migrate deployment:"
    echo "  Deployment:    $deployment_hash"
    echo "  Source Schema: $SOURCE_NAME (ID: $SOURCE_ID)"
    echo "  Target Schema: $TARGET_NAME (ID: $TARGET_ID)"
    echo "  Source Shard:  $SOURCE_SHARD"
    echo "  Target Shard:  $TARGET_SHARD"
    echo ""
    read -p "Proceed with migration? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user"
        exit 0
    fi

    # Perform migration
    echo ""
    log_info "Starting migration..."

    migrate_metadata "$deployment_hash"
    migrate_data "$deployment_hash"

    # Perform consistency checks
    echo ""
    if perform_consistency_checks "$deployment_hash"; then
        generate_summary "$deployment_hash"
        log_success "Migration completed successfully!"
        exit 0
    else
        log_error "Migration completed with consistency check failures"
        log_warning "Please review the errors above and verify the migration manually"
        exit 1
    fi
}

# Run main function
main "$@"
