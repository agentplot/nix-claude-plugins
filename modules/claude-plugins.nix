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

  # Extract a single plugin from a marketplace source into a derivation.
  # Keyed by the plugin's friendly name (not the target) so identical plugins
  # shared across multiple targets resolve to the same store path.
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

  # Build the installed_plugins.json content for a single install target.
  mkInstalledPluginsJson =
    target:
    let
      mkEntry =
        _name: pluginCfg:
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
              installPath = "${target.pluginsDir}/cache/${cacheRelPath}";
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
      plugins = lib.mapAttrs' mkEntry target.plugins;
    };

  # Build the known_marketplaces.json content for a single install target.
  mkKnownMarketplacesJson =
    target:
    lib.mapAttrs' (
      _name: pluginCfg:
      let
        m = pluginCfg.marketplace;
      in
      lib.nameValuePair m.name {
        source = m.source;
        installLocation = "${target.pluginsDir}/marketplaces/${m.name}";
        lastUpdated = "1970-01-01T00:00:00.000Z";
      }
    ) target.plugins;

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

  # Install-target submodule type. Each target populates one Claude Code
  # plugins directory with its own plugin set and JSON state files.
  targetModule = lib.types.submodule {
    options = {
      pluginsDir = lib.mkOption {
        type = lib.types.str;
        description = "Base plugins directory for this target (e.g. ~/.claude/plugins).";
      };

      plugins = lib.mkOption {
        type = lib.types.attrsOf pluginModule;
        default = { };
        description = "Plugins to install into this target's pluginsDir.";
      };

      preserveExistingPlugins = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          When true, merge Nix-managed plugins into the existing
          installed_plugins.json for this target rather than overwriting it.
        '';
      };
    };
  };

  # All install targets: explicit `targets` plus a synthesized target derived
  # from the top-level pluginsDir/plugins options (back-compat for direct,
  # non-profile consumers).
  effectiveTargets =
    cfg.targets
    // lib.optionalAttrs (cfg.plugins != { }) {
      __toplevel = {
        inherit (cfg) pluginsDir plugins preserveExistingPlugins;
      };
    };

in
{
  options.programs.claude-plugins = {
    enable = lib.mkEnableOption "declarative Claude Code plugin management";

    pluginsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude/plugins";
      description = "Base directory for the top-level (implicit) plugin target.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf pluginModule;
      default = { };
      description = ''
        Set of plugins to install declaratively into the top-level pluginsDir.
        Each key is a friendly name used internally; the actual plugin identity
        comes from pluginName + marketplace.

        Treated as an implicit install target. For multiple config directories
        (e.g. profiles), use `targets` instead.
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

    targets = lib.mkOption {
      type = lib.types.attrsOf targetModule;
      default = { };
      description = ''
        Per-directory install targets. Each target installs its own plugin set
        into its own pluginsDir, with its own installed_plugins.json and
        known_marketplaces.json. Use this to populate multiple Claude Code
        config directories (e.g. identity-isolated profiles) with independent
        plugin sets.

        The top-level `plugins` / `pluginsDir` options remain supported and are
        installed as an additional implicit target.
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
        This preserves plugins installed via the CLI. Applies to the top-level
        implicit target; per-target overrides live on each `targets` entry.
      '';
    };
  };

  config = lib.mkMerge [
    # Bridge: when agentplot-kit's programs.claude-code is present, install each
    # config dir's enabled plugins into that dir's own plugins cache. The catalog
    # (programs.claude-code.plugins) says where to fetch each plugin; each
    # config's enabledPlugins selects which of them to install there.
    #
    # Gate on agentplot-kit-specific options (profiles/enabledPlugins/configDir).
    # Upstream home-manager also ships a programs.claude-code, but its `plugins`
    # is a list and it has none of these options — so this stays inert there.
    (lib.mkIf
      (
        let
          ccOpts = options.programs.claude-code or { };
        in
        (ccOpts ? profiles)
        && (ccOpts ? enabledPlugins)
        && (ccOpts ? configDir)
        && (config.programs.claude-code.plugins or { }) != { }
      )
      (
      let
        cc = config.programs.claude-code;
        home = config.home.homeDirectory;
        catalog = cc.plugins;

        enabledKeys = ep: lib.attrNames (lib.filterAttrs (_: v: v) ep);

        # Catalog entries whose "pluginName@marketplaceName" key is enabled.
        filterCatalog =
          ep:
          let
            keys = enabledKeys ep;
          in
          lib.filterAttrs (_: p: lib.elem "${p.pluginName}@${p.marketplace.name}" keys) catalog;

        # When availablePlugins is set, install that superset into EVERY target and
        # let enabledPlugins (settings.json) decide activation — install is decoupled
        # from enable. When null, install is gated by enabledPlugins (legacy).
        installOverride =
          if (cc.availablePlugins or null) != null
          then filterCatalog cc.availablePlugins
          else null;

        mkTarget = configDir: ep: {
          pluginsDir = "${home}/${configDir}/plugins";
          plugins = if installOverride != null then installOverride else filterCatalog ep;
        };

        profileTargets = lib.mapAttrs' (
          name: p: lib.nameValuePair "profile-${name}" (mkTarget p.configDir p.enabledPlugins)
        ) cc.profiles;
      in
      {
        programs.claude-plugins = {
          enable = true;
          targets = {
            default = mkTarget cc.configDir cc.enabledPlugins;
          } // profileTargets;
        };
      }
    ))

    (lib.mkIf (cfg.enable && effectiveTargets != { }) {
      # Place extracted plugin files into each target's cache via activation
      # script. We use activation rather than home.file because:
      # 1. Claude Code may write to these directories (updates, etc.)
      # 2. Symlinks from the Nix store would be read-only and could break Claude
      # 3. We need to merge with existing state when preserveExistingPlugins is true
      home.activation.installClaudePluginsDeclarative =
        let
          # Merge script for installed_plugins.json (shared across targets)
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

          # Build the activation block for one install target.
          mkTargetBlock =
            targetName: target:
            let
              pluginCopyCommands = lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  name: pluginCfg:
                  let
                    extracted = extractPlugin name pluginCfg;
                    marketplaceName = pluginCfg.marketplace.name;
                    pluginName = pluginCfg.pluginName;
                    version = pluginCfg.version;
                    destDir = "${target.pluginsDir}/cache/${marketplaceName}/${pluginName}/${version}";
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
                ) target.plugins
              );

              installedPluginsFile =
                jsonFormat.generate "installed-plugins-${targetName}.json"
                  (mkInstalledPluginsJson target);
              knownMarketplacesFile =
                jsonFormat.generate "known-marketplaces-${targetName}.json"
                  (mkKnownMarketplacesJson target);
            in
            ''
              # ── Install target: ${targetName} → ${target.pluginsDir} ──
              $DRY_RUN_CMD mkdir -p "${target.pluginsDir}/cache"
              $DRY_RUN_CMD mkdir -p "${target.pluginsDir}/marketplaces"

              # Copy plugin files to cache
              ${pluginCopyCommands}

              # Write installed_plugins.json
              ${
                if target.preserveExistingPlugins then
                  ''
                    PRESERVE_EXISTING=1 ${mergeScript} \
                      "${installedPluginsFile}" \
                      "${target.pluginsDir}/installed_plugins.json" \
                      "${target.pluginsDir}/installed_plugins.json.tmp"
                    $DRY_RUN_CMD mv "${target.pluginsDir}/installed_plugins.json.tmp" "${target.pluginsDir}/installed_plugins.json"
                  ''
                else
                  ''
                    $DRY_RUN_CMD cp "${installedPluginsFile}" "${target.pluginsDir}/installed_plugins.json"
                    $DRY_RUN_CMD chmod u+w "${target.pluginsDir}/installed_plugins.json"
                  ''
              }

              # Merge known_marketplaces.json (always merge to preserve manually added marketplaces)
              if [ -f "${target.pluginsDir}/known_marketplaces.json" ]; then
                ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
                  "${target.pluginsDir}/known_marketplaces.json" \
                  "${knownMarketplacesFile}" \
                  > "${target.pluginsDir}/known_marketplaces.json.tmp"
                $DRY_RUN_CMD mv "${target.pluginsDir}/known_marketplaces.json.tmp" "${target.pluginsDir}/known_marketplaces.json"
              else
                $DRY_RUN_CMD cp "${knownMarketplacesFile}" "${target.pluginsDir}/known_marketplaces.json"
                $DRY_RUN_CMD chmod u+w "${target.pluginsDir}/known_marketplaces.json"
              fi
            '';
        in
        lib.hm.dag.entryAfter [ "writeBoundary" ] (
          lib.concatStringsSep "\n" (lib.mapAttrsToList mkTargetBlock effectiveTargets)
        );
    })
  ];
}
