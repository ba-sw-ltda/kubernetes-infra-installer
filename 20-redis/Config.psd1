@{
    # Component metadata (NOT configurable by end user)
    Name        = "redis"
    DisplayName = "Redis"
    Repository  = "oci://registry-1.docker.io/bitnamicharts/redis"
    Version     = "27.0.12"
    Namespace   = "shared-infra"

    # Gates this component on the ClusterSecretStore 'cluster-secrets' being
    # Ready (Test-SecretsBackendPresent) — needed because ACL credentials are
    # provisioned through Vault/CSI, not a chart-managed password anymore.
    RequiredPrereqs = @("secrets-backend")

    # Redis ACL users provisioned alongside the "default" superuser — one
    # Vault key per username under "$Namespace/redis-acl-users", mounted via
    # CSI (never as a k8s Secret) and composed into users.acl by an
    # initContainer in Install.ps1. Commands/Keys/Channels use real Redis ACL
    # syntax verbatim. Adding a consumer here + re-running Install.ps1 is the
    # whole onboarding step for anything installed through this installer —
    # see Install.ps1's ACL section for the data flow and the "Extensibility"
    # note in the design doc for a consumer that isn't.
    AclUsers = @(
        @{
            Username = "mosquitto"
            # Exact commands/keys Mosquitto-HA's scripts use (entrypoint.sh,
            # renew-lease.sh, replay-retain.sh, retain-sync.sh): GET/SET/DEL on
            # the leader key + retained-message keys, EVAL for the
            # lease-renewal Lua script (which itself calls GET+PEXPIRE), SCAN
            # to enumerate retained keys. No KEYS, no FLUSHALL, no pub/sub.
            Commands = "-@all +get +set +del +eval +scan +pexpire"
            Keys     = "~mosquitto:leader ~mqtt:retain:*"
            Channels = ""
        }
    )

    # User-configurable settings
    UserConfig = @{
        # standalone is the simplest correct start; switch to "replication" if
        # Mosquitto/EMQX HA ends up needing a real Sentinel-backed shared store.
        Architecture = "standalone"

        Persistence = @{
            Size = "4Gi"
        }

        Resources = @{
            Limits = @{
                Cpu    = "500m"
                Memory = "512Mi"
            }
            Requests = @{
                Cpu    = "100m"
                Memory = "128Mi"
            }
        }
    }
}
