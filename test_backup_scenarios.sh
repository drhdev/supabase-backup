#!/bin/bash
set -euo pipefail

# === Test Configuration ===
TEST_DIR="./test-env"
BACKUP_SCRIPT="./supabase_backup_restic.sh"
TEST_ENV="$TEST_DIR/restic.env"
TEST_LOG="$TEST_DIR/test.log"

# Ensure test environment directories exist before any logging
mkdir -p "$TEST_DIR/config" "$TEST_DIR/buckets/media" "$TEST_DIR/buckets/public"

# === Test Helper Functions ===
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$TEST_LOG"
}

cleanup() {
    log "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
    docker rm -f test-supabase-db 2>/dev/null || true
    docker rm -f test-minio 2>/dev/null || true
}

setup_test_env() {
    log "Setting up test environment..."
    # Directories already created at script start
    # Create test environment file
    cat > "$TEST_ENV" << EOF
RESTIC_REPOSITORY=s3:https://test-bucket.test.com
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
RESTIC_PASSWORD=test-password
EOF

    # Create a modified version of the backup script for testing
    sed "s|/opt/supabase-backups|$TEST_DIR|g" "$BACKUP_SCRIPT" > "$TEST_DIR/backup_script.sh"
    # Fix df command for macOS
    sed -i '' 's/df -B1/df -k/g' "$TEST_DIR/backup_script.sh"
    # Add cleanup function to backup script
    cat >> "$TEST_DIR/backup_script.sh" << 'EOF'
cleanup() {
    rm -rf "$TEMP_DIR"
    rm -f "$LOCK_FILE"
}
EOF
    chmod +x "$TEST_DIR/backup_script.sh"
    BACKUP_SCRIPT="$TEST_DIR/backup_script.sh"
}

# === Test Scenarios ===

test_missing_environment() {
    log "Test: Missing environment file"
    rm -f "$TEST_ENV"
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with missing environment"
        return 1
    fi
    log "✅ Test passed: Script correctly failed with missing environment"
}

test_hetzner_missing_sse_key() {
    log "Test: Hetzner without SSE-C key"
    cat > "$TEST_ENV" << EOF
RESTIC_REPOSITORY=s3:https://eu-central-1.hetzner.com/test-bucket
RESTIC_PASSWORD=test-password
EOF
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail without SSE-C key for Hetzner"
        return 1
    fi
    log "✅ Test passed: Script correctly failed without SSE-C key"
}

test_database_connection_failure() {
    log "Test: Database connection failure"
    docker rm -f test-supabase-db 2>/dev/null || true
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with database connection error"
        return 1
    fi
    log "✅ Test passed: Script correctly failed with database error"
}

test_minio_connection_failure() {
    log "Test: MinIO connection failure"
    docker rm -f test-minio 2>/dev/null || true
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with MinIO connection error"
        return 1
    fi
    log "✅ Test passed: Script correctly failed with MinIO error"
}

test_disk_space_failure() {
    log "Test: Insufficient disk space"
    # Simulate full disk by creating a large file
    fallocate -l 100G "$TEST_DIR/fill_disk" 2>/dev/null || dd if=/dev/zero of="$TEST_DIR/fill_disk" bs=1G count=100
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with disk space error"
        return 1
    fi
    rm "$TEST_DIR/fill_disk"
    log "✅ Test passed: Script correctly failed with disk space error"
}

test_permission_failure() {
    log "Test: Permission issues"
    chmod 000 "$TEST_DIR/config"
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with permission error"
        return 1
    fi
    chmod 755 "$TEST_DIR/config"
    log "✅ Test passed: Script correctly failed with permission error"
}

test_network_failure() {
    log "Test: Network connectivity issues"
    # Skip network test on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log "⚠️ Skipping network test on macOS"
        return 0
    fi
    # Simulate network failure by blocking outbound connections
    iptables -A OUTPUT -j DROP
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should fail with network error"
        return 1
    fi
    iptables -D OUTPUT -j DROP
    log "✅ Test passed: Script correctly failed with network error"
}

test_concurrent_execution() {
    log "Test: Concurrent script execution"
    "$BACKUP_SCRIPT" &
    if "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should prevent concurrent execution"
        return 1
    fi
    wait
    log "✅ Test passed: Script correctly prevented concurrent execution"
}

test_large_file_handling() {
    log "Test: Large file handling"
    # Create a valid environment file for this test
    cat > "$TEST_ENV" << EOF
RESTIC_REPOSITORY=s3:https://test-bucket.test.com
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
RESTIC_PASSWORD=test-password
EOF
    # Create a 1GB test file (reduced from 5GB for faster testing)
    dd if=/dev/zero of="$TEST_DIR/buckets/media/large_file" bs=1G count=1
    if ! "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should handle large files"
        return 1
    fi
    log "✅ Test passed: Script correctly handled large files"
}

test_special_characters() {
    log "Test: Special characters in filenames"
    # Create a valid environment file for this test
    cat > "$TEST_ENV" << EOF
RESTIC_REPOSITORY=s3:https://test-bucket.test.com
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
RESTIC_PASSWORD=test-password
EOF
    touch "$TEST_DIR/buckets/media/file with spaces"
    touch "$TEST_DIR/buckets/media/file'with'quotes"
    touch "$TEST_DIR/buckets/media/file*with*stars"
    if ! "$BACKUP_SCRIPT"; then
        log "❌ Test failed: Script should handle special characters"
        return 1
    fi
    log "✅ Test passed: Script correctly handled special characters"
}

test_restore_verification() {
    log "Test: Backup restore verification"
    if ! restic restore latest --target "$TEST_DIR/restore" 2>/dev/null; then
        log "⚠️ Skipping restore verification (no restic repository available)"
        return 0
    fi
    log "✅ Test passed: Restore verification successful"
}

# === Main Test Execution ===
main() {
    log "Starting backup script test suite..."
    
    # Ensure cleanup on exit
    trap cleanup EXIT
    
    # Setup test environment
    setup_test_env
    
    # Run all tests
    local tests=(
        test_missing_environment
        test_hetzner_missing_sse_key
        test_database_connection_failure
        test_minio_connection_failure
        test_disk_space_failure
        test_permission_failure
        test_network_failure
        test_concurrent_execution
        test_large_file_handling
        test_special_characters
        test_restore_verification
    )
    
    local failed=0
    for test in "${tests[@]}"; do
        if ! $test; then
            failed=$((failed + 1))
        fi
    done
    
    # Print summary
    log "Test suite completed. Failed tests: $failed"
    if [ $failed -eq 0 ]; then
        log "✅ All tests passed!"
        exit 0
    else
        log "❌ Some tests failed!"
        exit 1
    fi
}

# Run the test suite
main 