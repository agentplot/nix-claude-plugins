# nix-claude-plugins

Declarative Claude Code plugin management via home-manager. Fetches plugin sources at Nix eval time and places them directly into Claude Code's plugin directories — no CLI commands, no git clones at activation, fully reproducible.

## Why?

Existing approaches (including the `claude-plugins` CLI and wrappers like `claude-plugins-nix`) shell out to `git clone` during home-manager activation. This means:

- Network access required at activation time
- Not reproducible — depends on remote state
- Re-checks every activation even when nothing changed
- Requires git in PATH (problematic on nix-darwin)

This module fetches sources via `fetchFromGitHub` at Nix eval time (pinned in `flake.lock`), extracts plugin files, and copies them to Claude Code's expected directories. Fully content-addressed and idempotent.

## Usage

### flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    nix-claude-plugins.url = "github:agentplot/nix-claude-plugins";

    # Pin your marketplace sources as flake inputs
    claude-plugins-official = {
      url = "github:anthropics/claude-plugins-official";
      flake = false;
    };
    claude-code-plugins = {
      url = "github:anthropics/claude-code/main?dir=plugins";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, nix-claude-plugins, ... } @ inputs: {
    # Add the module to your home-manager config
    homeConfigurations.you = home-manager.lib.homeManagerConfiguration {
      # ...
      modules = [
        nix-claude-plugins.homeManagerModules.default
        # your config that uses programs.claude-plugins
      ];
    };
  };
}
```

### Plugin configuration

```nix
{ inputs, ... }:
{
  programs.claude-plugins = {
    enable = true;

    plugins = {
      pr-review-toolkit = {
        pluginName = "pr-review-toolkit";
        version = "1.0.0";
        marketplace = {
          name = "claude-code-plugins";
          src = inputs.claude-code-plugins;
          source = {
            source = "git";
            url = "https://github.com/anthropics/claude-code.git";
          };
        };
      };

      pyright-lsp = {
        pluginName = "pyright-lsp";
        version = "1.0.0";
        marketplace = {
          name = "claude-plugins-official";
          src = inputs.claude-plugins-official;
          source = {
            source = "git";
            url = "https://github.com/anthropics/claude-plugins-official.git";
          };
        };
      };
    };

    # Preserve plugins installed manually via CLI (default: true)
    preserveExistingPlugins = true;
  };
}
```

### Marketplace helper

To reduce repetition, define marketplace sources once:

```nix
let
  marketplaces = {
    official = {
      name = "claude-plugins-official";
      src = inputs.claude-plugins-official;
      source = { source = "git"; url = "https://github.com/anthropics/claude-plugins-official.git"; };
    };
    code = {
      name = "claude-code-plugins";
      src = inputs.claude-code-plugins;
      source = { source = "git"; url = "https://github.com/anthropics/claude-code.git"; };
    };
  };

  mkPlugin = marketplace: pluginName: {
    inherit pluginName marketplace;
    version = "1.0.0";
  };
in
{
  programs.claude-plugins.plugins = {
    pyright-lsp = mkPlugin marketplaces.official "pyright-lsp";
    typescript-lsp = mkPlugin marketplaces.official "typescript-lsp";
    pr-review-toolkit = mkPlugin marketplaces.code "pr-review-toolkit";
  };
}
```

## How it works

1. **Nix eval time**: `fetchFromGitHub` fetches marketplace repos → pinned in `flake.lock`
2. **Build time**: `runCommand` extracts each plugin's subdirectory from the marketplace
3. **Activation time**: Copies extracted files to `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`
4. **Registry**: Generates `installed_plugins.json` and `known_marketplaces.json` so Claude Code recognizes the plugins

Plugins are content-addressed — if the Nix store path hasn't changed, the copy is skipped. A `.nix-source` marker file tracks which store path is currently deployed.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable declarative plugin management |
| `pluginsDir` | string | `~/.claude/plugins` | Base directory for plugins |
| `plugins` | attrsOf plugin | `{}` | Plugins to install |
| `preserveExistingPlugins` | bool | `true` | Merge with CLI-installed plugins |

### Plugin options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pluginName` | string | — | Plugin name within marketplace |
| `pluginPath` | string? | `null` | Custom path in marketplace (default: `plugins/<name>`) |
| `marketplace` | marketplace | — | Marketplace source |
| `version` | string | `"1.0.0"` | Version string |
| `scope` | enum | `"user"` | `"user"`, `"project"`, or `"local"` |
| `projectPath` | string? | `null` | Project path for non-user scopes |
| `gitCommitSha` | string? | `null` | Optional commit SHA for tracking |

### Marketplace options

| Option | Type | Description |
|--------|------|-------------|
| `name` | string | Short marketplace name |
| `src` | path | Fetched marketplace source (e.g., `fetchFromGitHub` result) |
| `source` | attrs | Source metadata for `known_marketplaces.json` |

## Compatibility

Works alongside the upstream `programs.claude-code` home-manager module. This module manages the plugin cache and registry; the upstream module manages settings, MCP servers, commands, etc.

## License

MIT
