{
  description = "Declarative Claude Code plugin management via home-manager — no CLI, pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      flake-utils,
    }:
    {
      homeManagerModules.claude-plugins = import ./modules/claude-plugins.nix;
      homeManagerModules.default = self.homeManagerModules.claude-plugins;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        checks = import ./tests { inherit pkgs home-manager; };
      }
    );
}
