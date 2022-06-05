{ config, options, lib, pkgs, nixpkgsFork, ... }:

with lib;
let
  cfg = config.virtualisation.dockerServices;

  getNetworkName = network:
    if
      (isAttrs network)
    then network.name
    else network;

  isGlobalNetwork = network: if (isAttrs network) then (network.global or false) else false;

  getNetworkNames = serviceName: container: map (network: getFullNetworkName serviceName network) (container.networks or [ ]);

  getFullNetworkName = serviceName: network:
    let
      networkGlobal = isGlobalNetwork network;
      networkName = getNetworkName network;

      networkCreateServiceName =
        if networkGlobal then
          (mkFullGlobalNetworkName networkName)
        else (mkFullNetworkName serviceName networkName);
    in
    networkCreateServiceName;

  serviceOptions =
    { ... }: {
      options = {
        containers = mkOption {
          default = { };
          type = with types; attrs;
          description = "Set of Docker containers to run as systemd services.";
        };

        # options = {
        #   containers = mkOption {
        #     default = { };
        #     type = types.attrsOf
        #       (with types; submodule
        #         ({ ... }: {
        #           freeformType = with types; any;
        #           options = {
        #             networks = mkOption {
        #               type = with types; listOf str;
        #               default = [ ];
        #               description = "Networks the Docker container should be part of.";
        #             };
        #           };
        #         }));
        #     description = "Set of Docker containers to run as systemd services.";
        #   };

        networks =
          mkOption
            {
              default = { };
              type = types.attrsOf (types.submodule networkOptions);
              description = "Set of Docker networks to be created";
            };
      };
    };

  networkOptions =
    { ... }: {

      options = {
        subnet = mkOption {
          default = "10.0.0.0/24";
          type = with types; str;
          description = "Subnet in CIDR notation";
          example = "10.0.0.0/24";
        };
      };
    };

  mkContainer = serviceName: containerName: container:
    builtins.removeAttrs
      (container // {
        # Overwrite dependencies because we alter container name
        dependsOn = map (dependencyName: mkContainerName serviceName dependencyName) (container.dependsOn or [ ]);
        # We also want to communicate within our networks via intended container name
        # oci-containers module alters container name, so we have to supply an explicit host name
        extraOptions = (container.extraOptions or [ ]) ++ [ "--hostname=${containerName}" ];
        # Comment in for adding networks
        # This currently does not work
        #  ++
        #   map
        #     (network:
        #       let
        #         networkName = getNetworkName network;
        #         fullNetworkName = if (isGlobalNetwork network) then (mkFullGlobalNetworkName networkName) else (mkFullNetworkName serviceName networkName);
        #       in
        #       "--network=${fullNetworkName}")
        #     container.networks;
      }) [ "networks" ];

  mkContainerName = serviceName: containerName: "container-${serviceName}-${containerName}";
  mkServiceName = serviceName: containerName: let fullContainerName = mkContainerName serviceName containerName; in "docker-${fullContainerName}";

  mkFullGlobalNetworkName = networkName: "network-${networkName}";
  mkFullNetworkName = serviceName: networkName: mkFullGlobalNetworkName "${serviceName}-${networkName}";

  mkGlobalNetworkCreateServiceName = networkName: "createDockerNetwork-${networkName}";
  mkNetworkCreateServiceName = serviceName: networkName: mkGlobalNetworkCreateServiceName "${serviceName}-${networkName}";

  mkGlobalNetworkCreateService = networkName: network:
    let
      fullNetworkName = mkFullGlobalNetworkName networkName;
      dockercli = "${config.virtualisation.docker.package}/bin/docker";
    in
    {
      description = "Create the docker network ${fullNetworkName}";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;

      script =
        ''
          # Put a true at the end to prevent getting non-zero return code, which will
          # crash the whole service.
          check=$(${dockercli} network ls | grep "${escapeShellArg fullNetworkName}" || true)
          if [ -z "$check" ]; then
            ${dockercli} network create ${escapeShellArg fullNetworkName} --subnet ${escapeShellArg network.subnet}
          else
            echo "${escapeShellArg fullNetworkName} already exists in docker"
          fi
        '';

      # Remove network on post stop
      postStop = ''${dockercli} network rm "${escapeShellArg fullNetworkName}"'';
      
    };
  mkNetworkCreateService = serviceName: networkName: network:
    mkGlobalNetworkCreateService "${serviceName}-${networkName}" network;


in
{
  disabledModules = ["virtualisation/oci-containers.nix"];

  options.virtualisation.dockerServices = {
    services = mkOption {
      default = { };
      type = types.attrsOf (types.submodule serviceOptions);
      description = "Set services, each containing Docker containers to run as systemd services.";
    };

    networks =
      mkOption
        {
          default = { };
          type = types.attrsOf (types.submodule networkOptions);
          description = "Set of Docker networks to be created and used globally";
        };

  };

  config = lib.mkIf (cfg.services != { })
    # Create Docker containers
    {
      virtualisation.oci-containers =
        (lib.mkMerge
          ([{ backend = "docker"; }] ++
            (mapAttrsToList
              (serviceName: service:
                {
                  containers =
                    mapAttrs'
                      (containerName: container:
                        {
                          name = mkContainerName serviceName containerName;
                          value = mkContainer serviceName containerName container;
                        }
                      )
                      service.containers;

                })
              cfg.services)));
      systemd =
        (lib.mkMerge
          (
            (mapAttrsToList  # Network creation services for global networks
              (networkName: network: {
                services."${mkGlobalNetworkCreateServiceName networkName}" = mkGlobalNetworkCreateService networkName network;
              })
              cfg.networks) ++
            (mapAttrsToList
              (serviceName: service:
                {
                  services = # Network creation services for Docker Services
                    (attrsets.mapAttrs'
                      (networkName: network:
                        {
                          name = mkNetworkCreateServiceName serviceName networkName;
                          value = mkNetworkCreateService serviceName networkName network;
                        })
                      service.networks) //
                    # Override requires and after of systemd units of docker containers for network creation
                    # Also override postStart for joining all networks
                    # Differentiate between global and local networks
                    (mapAttrs'
                      (containerName: container:
                        {
                          name = mkServiceName serviceName containerName;
                          value =
                            let
                              units = map
                                (network:
                                  let
                                    networkGlobal = isGlobalNetwork network;
                                    networkName = getNetworkName network;

                                    networkCreateServiceName =
                                      if networkGlobal then
                                        (mkGlobalNetworkCreateServiceName networkName)
                                      else (mkNetworkCreateServiceName serviceName networkName);
                                  in
                                  "${networkCreateServiceName}.service")
                                container.networks;
                            in
                            {
                              after = units;
                              requires = units;
                              postStart =
                                # Connect to every network after grace period of one second
                                builtins.concatStringsSep "\n"
                                  (map (networkName: "sleep 1; docker network connect ${escapeShellArg networkName} ${escapeShellArg (mkContainerName serviceName containerName)}")
                                    (getNetworkNames serviceName container));
                            };
                        }
                      )
                      service.containers);
                })
              cfg.services)
          ));
    };
}
