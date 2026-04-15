{
  config,
  lib,
  pkgs,
  options,
  ...
}:

let
  cfg = config.programs.claude-plugins;

  jsonFormat = pkgs.formats.json { };

  # Extract a single plugin from a marketplace source into a derivation
  extractPlugin =
    name: pluginCfg:
    let
      marketplace = pluginCfg.marketplace;
      pluginSubdir =
        if pluginCfg.pluginPath != null then
          pluginCfg.pluginPath
        else
          "plugins/${pluginCfg.pluginName}";
    in
    pkgs.runCommand "claude-plugin-${name}" { } ''
      src="${marketplace.src}"
      plugin_dir="$src/${pluginSubdir}"

      if [ ! -d "$plugin_dir" ]; then
        echo "ERROR: Plugin directory not found: ${pluginSubdir}"
        echo "Available directories in marketplace:"
        ls -la "$src/plugins/" 2>/dev/null || ls -la "$src/" || true
        exit 1
      fi

      mkdir -p "$out"
      cp -r "$plugin_dir"/. "$out/"
    '';

  # Build the installed_plugins.json content
  installedPluginsJson =
    let
      mkEntry =
        name: pluginCfg:
        let
          pluginName = pluginCfg.pluginName;
          marketplaceName = pluginCfg.marketplace.name;
          key = "${pluginName}@${marketplaceName}";
          version = pluginCfg.version;
          cacheRelPath = "${marketplaceName}/${pluginName}/${version}";
        in
        lib.nameValuePair key [
          (
            {
              scope = pluginCfg.scope;
              installPath = "${cfg.pluginsDir}/cache/${cacheRelPath}";
              inherit version;
              installedAt = "1970-01-01T00:00:00.000Z";
              lastUpdated = "1970-01-01T00:00:00.000Z";
            }
            // lib.optionalAttrs (pluginCfg.scope != "user") {
              projectPath = pluginCfg.projectPath;
            }
            // lib.optionalAttrs (pluginCfg.gitCommitSha != null) {
              inherit (pluginCfg) gitCommitSha;
            }
          )
        ];
    in
    {
      version = 2;
      plugins = lib.mapAttrs' mkEntry cfg.plugins;
    };

  # Build the known_marketplaces.json content
  knownMarketplacesJson = lib.mapAttrs' (
    _name: pluginCfg:
    let
      m = pluginCfg.marketplace;
    in
    lib.nameValuePair m.name {
      source = m.source;
      installLocation = "${cfg.pluginsDir}/marketplaces/${m.name}";
      lastUpdated = "1970-01-01T00:00:00.000Z";
    }
  ) cfg.plugins;

  # Plugin submodule type
  pluginModule = lib.types.submodule {
    options = {
      pluginName = lib.mkOption {
        type = lib.types.str;
        description = "Name of the plugin within its marketplace.";
      };

      pluginPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to the plugin within the marketplace source, relative to root.
          Defaults to "plugins/<pluginName>" if not set.
        '';
      };

      marketplace = lib.mkOption {
        type = marketplaceModule;
        description = "The marketplace this plugin belongs to.";
      };

      version = lib.mkOption {
        type = lib.types.str;
        default = "1.0.0";
        description = "Version string for the plugin.";
      };

      scope = lib.mkOption {
        type = lib.types.enum [
          "user"
          "project"
          "local"
        ];
        default = "user";
        description = "Installation scope.";
      };

      projectPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Project path for project/local scoped plugins.";
      };

      gitCommitSha = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Git commit SHA for tracking. Optional.";
      };
    };
  };

  # Marketplace submodule type
  marketplaceModule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Short name for the marketplace (e.g., 'claude-plugins-official').";
      };

      src = lib.mkOption {
        type = lib.types.path;
        description = ''
          Source of the marketplace. Typically a fetchFromGitHub derivation.
          This should point to the root of the marketplace repo.
        '';
      };

      source = lib.mkOption {
        type = jsonFormat.type;
        default = {
          source = "git";
          url = "https://github.com/unknown/unknown.git";
        };
        description = "Source metadata written to known_marketplaces.json.";
      };
    };
  };

in
{
  options.programs.claude-plugins = {
    enable = lib.mkEnableOption "declarative Claude Code plugin management";

    pluginsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude/plugins";
      description = "Base directory for Claude Code plugins.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf pluginModule;
      default = { };
      description = ''
        Set of plugins to install declaratively.
        Each key is a friendly name used internally; the actual plugin identity
        comes from pluginName + marketplace.
      '';
      example = lib.literalExpression ''
        {
          pr-review-toolkit = {
            pluginName = "pr-review-toolkit";
            marketplace = {
              name = "claude-code-plugins";
              src = inputs.claude-code-plugins;
              source = {
                source = "git";
                url = "https://github.com/anthropics/claude-code.git";
              };
            };
          };
        }
      '';
    };

    # Convenience: allow extra entries in installed_plugins.json
    # for plugins managed outside this module (e.g., manually installed)
    preserveExistingPlugins = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When true, the activation script merges Nix-managed plugins into
        the existing installed_plugins.json rather than overwriting it.
        This preserves plugins installed via the CLI.
      '';
    };
  };

  config = lib.mkMerge [
    # Bridge: import plugins from programs.claude-code.plugins when agentplot-kit module is present
    (lib.mkIf (options.programs ? claude-code && (config.programs.claude-code.plugins or { }) != { }) {
      programs.claude-plugins = {
        enable = true;
        plugins = config.programs.claude-code.plugins;
      };
    })

    (lib.mkIf (cfg.enable && cfg.plugins != { }) {
    # Place extracted plugin files into the cache via activation script.
    # We use activation rather than home.file because:
    # 1. Claude Code may write to these directories (updates, etc.)
    # 2. Symlinks from the Nix store would be read-only and could break Claude
    # 3. We need to merge with existing state when preserveExistingPlugins is true
    home.activation.installClaudePluginsDeclarative =
      let
        # Build a script that copies each plugin to the cache
        pluginCopyCommands = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: pluginCfg:
            let
              extracted = extractPlugin name pluginCfg;
              marketplaceName = pluginCfg.marketplace.name;
              pluginName = pluginCfg.pluginName;
              version = pluginCfg.version;
              destDir = "${cfg.pluginsDir}/cache/${marketplaceName}/${pluginName}/${version}";
            in
            ''
              # Plugin: ${pluginName} from ${marketplaceName}
              nix_src="${extracted}"
              dest="${destDir}"

              # Check if content has changed by comparing store path marker
              marker="$dest/.nix-source"
              if [ -f "$marker" ] && [ "$(cat "$marker")" = "$nix_src" ]; then
                $VERBOSE_ECHO "Plugin ${pluginName} unchanged, skipping"
              else
                $VERBOSE_ECHO "Installing plugin: ${pluginName} → $dest"
                # chmod before rm: previous installs (or older versions of this
                # module) may have left read-only files/dirs from the nix store.
                # Without this, `rm -rf` fails under `set -eu` and activation
                # aborts before the post-copy chmod can repair perms,
                # self-perpetuating the failure on every rebuild.
                if [ -e "$dest" ]; then
                  $DRY_RUN_CMD chmod -R u+w "$dest" 2>/dev/null || true
                fi
                $DRY_RUN_CMD rm -rf "$dest"
                $DRY_RUN_CMD mkdir -p "$dest"
                $DRY_RUN_CMD cp -rL "$nix_src"/. "$dest/"
                $DRY_RUN_CMD chmod -R u+w "$dest"
                echo "$nix_src" > "$dest/.nix-source"
              fi
            ''
          ) cfg.plugins
        );

        # Generate the JSON files as Nix store paths
        installedPluginsFile = jsonFormat.generate "installed-plugins.json" installedPluginsJson;
        knownMarketplacesFile = jsonFormat.generate "known-marketplaces.json" knownMarketplacesJson;

        # Merge script for installed_plugins.json
        mergeScript = pkgs.writeScript "merge-installed-plugins" ''
          #!${pkgs.bash}/bin/bash
          # Merge Nix-managed plugins into existing installed_plugins.json
          nix_json="$1"
          existing="$2"
          output="$3"

          if [ -f "$existing" ] && [ "$PRESERVE_EXISTING" = "1" ]; then
            # Merge: existing entries preserved, Nix-managed entries override on conflict
            ${pkgs.jq}/bin/jq -s '
              .[0] as $existing | .[1] as $nix |
              {
                version: $nix.version,
                plugins: (($existing.plugins // {}) * $nix.plugins)
              }
            ' "$existing" "$nix_json" > "$output"
          else
            cp "$nix_json" "$output"
          fi
        '';
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # Ensure base directories exist
        $DRY_RUN_CMD mkdir -p "${cfg.pluginsDir}/cache"
        $DRY_RUN_CMD mkdir -p "${cfg.pluginsDir}/marketplaces"

        # Copy plugin files to cache
        ${pluginCopyCommands}

        # Write installed_plugins.json
        ${
          if cfg.preserveExistingPlugins then
            ''
              PRESERVE_EXISTING=1 ${mergeScript} \
                "${installedPluginsFile}" \
                "${cfg.pluginsDir}/installed_plugins.json" \
                "${cfg.pluginsDir}/installed_plugins.json.tmp"
              $DRY_RUN_CMD mv "${cfg.pluginsDir}/installed_plugins.json.tmp" "${cfg.pluginsDir}/installed_plugins.json"
            ''
          else
            ''
              $DRY_RUN_CMD cp "${installedPluginsFile}" "${cfg.pluginsDir}/installed_plugins.json"
              $DRY_RUN_CMD chmod u+w "${cfg.pluginsDir}/installed_plugins.json"
            ''
        }

        # Merge known_marketplaces.json (always merge to preserve manually added marketplaces)
        if [ -f "${cfg.pluginsDir}/known_marketplaces.json" ]; then
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
            "${cfg.pluginsDir}/known_marketplaces.json" \
            "${knownMarketplacesFile}" \
            > "${cfg.pluginsDir}/known_marketplaces.json.tmp"
          $DRY_RUN_CMD mv "${cfg.pluginsDir}/known_marketplaces.json.tmp" "${cfg.pluginsDir}/known_marketplaces.json"
        else
          $DRY_RUN_CMD cp "${knownMarketplacesFile}" "${cfg.pluginsDir}/known_marketplaces.json"
          $DRY_RUN_CMD chmod u+w "${cfg.pluginsDir}/known_marketplaces.json"
        fi
      '';
    })
  ];
}
