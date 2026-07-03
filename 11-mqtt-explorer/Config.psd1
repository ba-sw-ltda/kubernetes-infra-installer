@{
    # Component metadata (NOT configurable by end user)
    Name        = "mqtt-explorer"
    DisplayName = "MQTT Explorer (Web UI)"
    Image       = "ghcr.io/thomasnordquist/mqtt-explorer"
    Version     = "latest"
    Namespace   = "shared-infra"

    # Gates this component on the ClusterSecretStore 'cluster-secrets' being
    # Ready (Test-SecretsBackendPresent) — its admin password is provisioned
    # through Vault/CSI, not a plain Secret (see Install.ps1).
    DefaultSelected = $false
    RequiresGroups  = @("mqtt-broker")
    RequiredPrereqs = @("secrets-backend")

    # User-configurable settings
    UserConfig = @{
        Port = 3000

        Persistence = @{
            Size = "1Gi"
        }

        Resources = @{
            Limits = @{
                Cpu    = "200m"
                Memory = "256Mi"
            }
            Requests = @{
                Cpu    = "50m"
                Memory = "64Mi"
            }
        }
    }
}
