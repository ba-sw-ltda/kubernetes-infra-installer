@{
    # Component metadata (NOT configurable by end user)
    Name        = "mqtt-broker"   # generic — stable across a broker swap (see RadioGroup below)
    DisplayName = "EMQX (native cluster)"
    Repository  = "https://repos.emqx.io/charts"
    ChartName   = "emqx"
    Version     = "5.8.9"
    RancherProject  = "Shared Infrastructure"
    RadioGroup      = "mqtt-broker"   # mutually exclusive with 10-mqtt-mosquitto
    RadioGroupLabel = "MQTT-Broker"
    RadioDefault    = $false

    RequiredPrereqs = @("storage")

    # User-configurable settings
    UserConfig = @{
        # Odd replica counts recommended by EMQX so the cluster can heal cleanly
        # after a net-split — this is the whole reason to pick EMQX over
        # Mosquitto: real distributed clustering, not a bolted-on active/passive.
        ReplicaCount = 3

        Persistence = @{
            Size = "2Gi"
        }

        Resources = @{
            Limits = @{
                Cpu    = "500m"
                Memory = "512Mi"
            }
            Requests = @{
                Cpu    = "200m"
                Memory = "256Mi"
            }
        }
    }
}
