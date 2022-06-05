{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.nixpkgsFork.url = "github:glanch/nixpkgs";

  outputs = { self, nixpkgs, nixpkgsFork }@inputs:
    {
      nixosModule = { imports = [ ./docker-services.nix ]; };
    };
}
