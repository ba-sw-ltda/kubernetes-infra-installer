@{
    # Component metadata (NOT configurable by end user)
    Name        = "mqtt-broker"   # generic — stable across a broker swap (see RadioGroup below)
    DisplayName = "Mosquitto (active/passive/passive HA via Redis)"
    ChartPath   = "_charts\mosquitto-ha"
    RadioGroup      = "mqtt-broker"   # mutually exclusive with 10-mqtt-emqx
    RadioGroupLabel = "MQTT-Broker"   # shown as the group checkbox in Install-Infra.ps1's selection screen
    RadioDefault    = $true           # matches the pre-decided architecture (active/passive/passive)

    # Mosquitto-HA has no durable store of its own — Redis is required, not
    # optional, so Install-Infra.ps1's selection screen force-selects it (greyed
    # out, can't be unchecked) for as long as Mosquitto is the chosen broker.
    RequiresComponents = @("20-redis")

    # User-configurable settings
    UserConfig = @{
        ReplicaCount = 3   # always 3 (active + 2 passive) — the HA design assumes this

        # Set this (or override via Config.<PlatformShort>.psd1) to a registry the
        # *target cluster* can pull from before installing on anything but Kind —
        # Kind gets the locally-built image loaded directly, no registry needed.
        ImageRegistry = "proget.ds-automotion.com/docker-prototype/library"

        Resources = @{
            Limits = @{
                Cpu    = "200m"
                Memory = "128Mi"
            }
            Requests = @{
                Cpu    = "50m"
                Memory = "32Mi"
            }
        }
    }
}
