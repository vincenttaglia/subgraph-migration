#!/bin/bash

################################################################################
# Batch Subgraph Deployment Migration Script
#
# Purpose: Migrate multiple subgraph deployments from a file containing
#          deployment hashes (one per line).
#
# Usage: ./batch_migrate.sh <hash_file> [parallelism]
#
# Arguments:
#   hash_file   - File containing deployment hashes, one per line
#   parallelism - Number of parallel migrations (default: 1)
#
# Environment Variables:
#   Same as migrate_subgraph_deployment.sh:
#   - TARGET_METADATA_DB, TARGET_DATA_DB (required)
#   - SOURCE_METADATA_DB, SOURCE_DATA_DB, GRAPH_NODE_CONFIG (optional)
#   - OVERRIDE_SHARD (optional)
#
# Notes:
#   - Empty lines and lines starting with # are ignored
#   - Failed migrations are logged but don't stop the batch
#   - Use parallelism > 1 with caution (may cause database contention)
#   - Multiple instances can run simultaneously without interference
#     (unique batch ID ensures isolated log/temp directories)
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION_SCRIPT="$SCRIPT_DIR/migrate_subgraph_deployment.sh"

# Logging functions
log_info() {
    echo -e "${BLUE}[BATCH INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[BATCH SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[BATCH WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[BATCH ERROR]${NC} $1"
}

# Function to display usage
usage() {
    echo "Usage: $0 <hash_file> [parallelism]"
    echo ""
    echo "Arguments:"
    echo "  hash_file   - File containing deployment hashes, one per line"
    echo "  parallelism - Number of parallel migrations (default: 1)"
    echo ""
    echo "Example:"
    echo "  $0 deployments.txt"
    echo "  $0 deployments.txt 4"
    echo ""
    echo "Hash file format:"
    echo "  # This is a comment"
    echo "  QmXYZ123..."
    echo "  QmABC456..."
    exit 1
}

# Check arguments
if [[ $# -lt 1 ]] || [[ $# -gt 2 ]]; then
    usage
fi

HASH_FILE="$1"
PARALLELISM="${2:-1}"

# Validate hash file exists
if [[ ! -f "$HASH_FILE" ]]; then
    log_error "Hash file not found: $HASH_FILE"
    exit 1
fi

# Validate migration script exists
if [[ ! -x "$MIGRATION_SCRIPT" ]]; then
    log_error "Migration script not found or not executable: $MIGRATION_SCRIPT"
    exit 1
fi

# Validate parallelism is a positive integer
if ! [[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Parallelism must be a positive integer"
    exit 1
fi

# Count valid hashes (non-empty, non-comment lines)
TOTAL_HASHES=$(grep -v '^\s*#' "$HASH_FILE" | grep -v '^\s*$' | wc -l)

if [[ $TOTAL_HASHES -eq 0 ]]; then
    log_error "No deployment hashes found in $HASH_FILE"
    exit 1
fi

echo ""
echo "========================================"
echo "Batch Subgraph Migration"
echo "========================================"
echo ""
log_info "Hash file: $HASH_FILE"
log_info "Total deployments: $TOTAL_HASHES"
log_info "Parallelism: $PARALLELISM"
echo ""

if [[ $PARALLELISM -gt 1 ]]; then
    log_warning "Running with parallelism > 1. Ensure your databases can handle concurrent migrations."
fi

# Create results directory with unique identifier (timestamp + PID + random)
BATCH_ID="$(date +%Y%m%d_%H%M%S)_$$_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
RESULTS_DIR="$(pwd)/batch_migration_${BATCH_ID}"
mkdir -p "$RESULTS_DIR"
log_info "Batch ID: $BATCH_ID"
log_info "Results directory: $RESULTS_DIR"

# Export environment variables for child processes
export MIGRATION_SCRIPT
export RESULTS_DIR
export BATCH_ID

# Function to run a single migration (used by xargs)
run_migration() {
    local hash="$1"
    local log_file="$RESULTS_DIR/${hash}.log"

    # Create a unique temp directory for this specific migration in results dir
    # Uses batch ID + hash to ensure uniqueness across parallel runs
    local migration_temp_dir="$RESULTS_DIR/temp_${hash}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting migration: $hash"

    # Run migration with auto-yes for confirmation prompts
    # Set TEMP_DIR to ensure each migration uses its own temp directory
    if yes | TEMP_DIR="$migration_temp_dir" "$MIGRATION_SCRIPT" "$hash" > "$log_file" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $hash"
        # Use flock to safely append to shared files
        flock "$RESULTS_DIR/success.lock" -c "echo '$hash' >> '$RESULTS_DIR/success.txt'"
        return 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $hash (see $log_file)"
        # Use flock to safely append to shared files
        flock "$RESULTS_DIR/failed.lock" -c "echo '$hash' >> '$RESULTS_DIR/failed.txt'"
        return 1
    fi
}
export -f run_migration

# Run migrations using xargs
# Filter out comments and empty lines, then pipe to xargs
log_info "Starting batch migration..."
echo ""

grep -v '^\s*#' "$HASH_FILE" | grep -v '^\s*$' | \
    xargs -P "$PARALLELISM" -I {} bash -c 'run_migration "{}"' || true

# Generate summary
echo ""
echo "========================================"
echo "Batch Migration Summary"
echo "========================================"
echo ""

SUCCESS_COUNT=0
FAILED_COUNT=0

if [[ -f "$RESULTS_DIR/success.txt" ]]; then
    SUCCESS_COUNT=$(wc -l < "$RESULTS_DIR/success.txt")
fi

if [[ -f "$RESULTS_DIR/failed.txt" ]]; then
    FAILED_COUNT=$(wc -l < "$RESULTS_DIR/failed.txt")
fi

log_info "Total deployments: $TOTAL_HASHES"
log_success "Successful: $SUCCESS_COUNT"

if [[ $FAILED_COUNT -gt 0 ]]; then
    log_error "Failed: $FAILED_COUNT"
    echo ""
    log_error "Failed deployments:"
    cat "$RESULTS_DIR/failed.txt" | sed 's/^/  - /'
else
    log_info "Failed: 0"
fi

echo ""
log_info "Detailed logs available in: $RESULTS_DIR"
echo ""

# Exit with error if any migrations failed
if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
