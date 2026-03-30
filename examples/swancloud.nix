# Example: swancloud integration
#
# Shows how to migrate from the imperative claude-plugins-nix to this module.
#
# In flake.nix inputs, replace:
#   inputs.claude-plugins-nix.url = "github:afterthought/claude-plugins-nix";
# With:
#   inputs.nix-claude-plugins.url = "github:agentplot/nix-claude-plugins";
#   inputs.claude-plugins-official = { url = "github:anthropics/claude-plugins-official"; flake = false; };
#   inputs.claude-code-src = { url = "github:anthropics/claude-code"; flake = false; };
#   inputs.mdserve-src = { url = "github:jfernandez/mdserve"; flake = false; };
#
# In home-manager.sharedModules, replace:
#   inputs.claude-plugins-nix.homeManagerModules.default
# With:
#   inputs.nix-claude-plugins.homeManagerModules.default

{ inputs, ... }:

let
  # Define marketplaces once, reuse across plugins
  marketplaces = {
    official = {
      name = "claude-plugins-official";
      src = inputs.claude-plugins-official;
      source = {
        source = "git";
        url = "https://github.com/anthropics/claude-plugins-official.git";
      };
    };
    # claude-code monorepo — plugins live at plugins/<name>/ (the default pluginPath)
    code = {
      name = "claude-code-plugins";
      src = inputs.claude-code-src;
      source = {
        source = "git";
        url = "https://github.com/anthropics/claude-code.git";
      };
    };
    mdserve = {
      name = "mdserve";
      src = inputs.mdserve-src;
      source = {
        source = "git";
        url = "https://github.com/jfernandez/mdserve.git";
      };
    };
  };

  mkPlugin = marketplace: pluginName: {
    inherit pluginName marketplace;
    version = "1.0.0";
  };
in
{
  home-manager.users.chuck.programs.claude-plugins = {
    enable = true;

    plugins = {
      # From claude-plugins-official marketplace (plugins/<name>/)
      pyright-lsp = mkPlugin marketplaces.official "pyright-lsp";
      typescript-lsp = mkPlugin marketplaces.official "typescript-lsp";
      claude-md-management = mkPlugin marketplaces.official "claude-md-management";
      plugin-dev = mkPlugin marketplaces.official "plugin-dev";
      playground = mkPlugin marketplaces.official "playground";

      # From claude-code monorepo (also plugins/<name>/)
      pr-review-toolkit = mkPlugin marketplaces.code "pr-review-toolkit";

      # Standalone plugin repos (plugin at repo root)
      mdserve = {
        pluginName = "mdserve";
        marketplace = marketplaces.mdserve;
        pluginPath = ".";
        version = "1.1.0";
      };
    };
  };

  # Remove old imperative module:
  # - Delete setupClaudePluginsPath activation (no longer needed — no git at activation)
  # - Delete claude-plugins-nix homeManagerModule import
}
