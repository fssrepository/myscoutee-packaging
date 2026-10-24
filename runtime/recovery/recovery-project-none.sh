#!/usr/bin/env bash
# This template has no extra product identity or state to back up.
# MongoDB, configuration encryption keys and MinIO use the common recovery path.
project_recovery_init() { :; }
project_backup() { :; }
project_backup_manifest() { printf '{}\n'; }
project_restore_validate() { :; }
project_restore() { :; }
