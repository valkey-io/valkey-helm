# Helm Chart Fixes and Improvements

## Fixed Schema and Configuration Issues
- 2026-04-02
  - Fixed missing comma in `values.schema.json` that caused validation errors
  - Added `sentinelAclUsers` definition to the JSON schema for proper validation
  - Fixed HAProxy image tag value: converted `tag: 2.9` to `tag: "2.9"` (string instead of number) to match schema definition
  - All changes ensure `helm lint` passes without errors

## Added Native ACL Support for Sentinel

- 2026-04-02
  - Implemented Access Control List (ACL) management for Valkey Sentinel in `sentinel-configmap.yaml` (lines 92-120)

  **Features:**
  - Generate NATIVE ACLs for INBOUND connections to Sentinel from `values.auth.sentinelAclUsers`
  - Generate OUTBOUND authentication configuration for Sentinel to connect to Valkey master/replicas using `values.auth.aclUsers`
  - Secure password handling with SHA256 hashing to prevent plaintext credentials in config files
  - Automatic replication user authentication for master/replica monitoring

  **Security Improvements:**
  - Modified logging function to output to stderr (`>&2`) instead of stdout to prevent passwords and sensitive data from leaking into command substitutions or configuration files
  - Ensures log messages do not interfere with command output that may contain credentials

  **Implementation Details:**

  1. **INBOUND ACL Generation (lines 93-105):**
     - Generates native ACL entries for clients connecting to Sentinel
     - Iterates through `values.auth.sentinelAclUsers` configuration
     - Retrieves password for each Sentinel ACL user
     - Hashes password with SHA256: `PASSHASH=$(echo -n "$PASSWORD" | sha256sum | cut -f 1 -d " ")`
     - Writes ACL entry: `echo "user {{ $username }} on #$PASSHASH {{ $user.permissions }}" >> "$SENTINEL_CONF"`

  2. **OUTBOUND Authentication Configuration (lines 107-120):**
     - Configures Sentinel authentication credentials to connect to Valkey master and replicas
     - Fetches replication user from `values.auth.aclUsers` (Valkey ACL block)
     - Retrieves password using `get_user_password()` helper function
     - Sets: `sentinel auth-user` and `sentinel auth-pass` for master set monitoring
