@{
    Name             = "redis-insight"
    DisplayName      = "Redis Insight (Web UI)"
    RancherProject   = "Shared Infrastructure"
    RequiredPrereqs  = @("ingress", "secrets-backend", "storage")
    RequiresComponents = @("20-redis")

    PortalTitle     = "Redis Insight"
    PortalSubtitle  = "Web UI for Redis"
    PortalIcon      = "logo.svg"

    UserConfig = @{
        Image        = "redis/redisinsight"
        Version      = "2.70.1"
        Port         = 5540
        SidecarImage = "alpine/k8s:1.31.4"

        Persistence = @{
            Size = "1Gi"
        }

        Resources = @{
            Limits = @{
                Cpu    = "500m"
                Memory = "512Mi"
            }
            Requests = @{
                Cpu    = "100m"
                Memory = "256Mi"
            }
        }

        SidecarResources = @{
            Limits = @{
                Cpu    = "100m"
                Memory = "64Mi"
            }
            Requests = @{
                Cpu    = "20m"
                Memory = "32Mi"
            }
        }
    }
}
