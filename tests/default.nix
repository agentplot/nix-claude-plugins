{ pkgs, home-manager }:

let
  eval = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../modules/claude-plugins.nix
      {
        home.username = "testuser";
        home.homeDirectory = "/home/testuser";
        home.stateVersion = "24.11";

        programs.claude-plugins = {
          enable = true;
          plugins = {
            pr-review-toolkit = {
              pluginName = "pr-review-toolkit";
              marketplace = {
                name = "claude-code-plugins";
                src = pkgs.runCommand "fake-marketplace" { } ''
                  mkdir -p $out/plugins/pr-review-toolkit/.claude-plugin
                  echo '{"name":"pr-review-toolkit"}' > $out/plugins/pr-review-toolkit/.claude-plugin/plugin.json
                  echo "test" > $out/plugins/pr-review-toolkit/README.md
                '';
                source = {
                  source = "git";
                  url = "https://github.com/anthropics/claude-code.git";
                };
              };
            };
          };
        };
      }
    ];
  };

  fakeMarketplace = pkgs.runCommand "fake-marketplace-multi" { } ''
    for p in alpha beta; do
      mkdir -p "$out/plugins/$p/.claude-plugin"
      echo "{\"name\":\"$p\"}" > "$out/plugins/$p/.claude-plugin/plugin.json"
      echo "test" > "$out/plugins/$p/README.md"
    done
  '';

  mkPlugin = name: {
    pluginName = name;
    marketplace = {
      name = "test-mp";
      src = fakeMarketplace;
      source = {
        source = "git";
        url = "https://github.com/example/test.git";
      };
    };
  };

  # Multi-target eval: a default config dir and a profile dir each install a
  # different subset, exercising the per-target activation path.
  evalTargets = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../modules/claude-plugins.nix
      {
        home.username = "testuser";
        home.homeDirectory = "/home/testuser";
        home.stateVersion = "24.11";

        programs.claude-plugins = {
          enable = true;
          targets = {
            default = {
              pluginsDir = "/home/testuser/.claude/plugins";
              plugins.alpha = mkPlugin "alpha";
            };
            profile-work = {
              pluginsDir = "/home/testuser/.claude-work/plugins";
              plugins = {
                alpha = mkPlugin "alpha";
                beta = mkPlugin "beta";
              };
            };
          };
        };
      }
    ];
  };

  targetsScript = evalTargets.config.home.activation.installClaudePluginsDeclarative.data;
in
{
  # Eval check — does the module evaluate without errors?
  eval-check = pkgs.runCommand "claude-plugins-eval-check" { } ''
    # If we get here, evaluation succeeded
    echo "Module evaluation succeeded"
    echo "Activation script present: ${
      if eval.config.home.activation ? installClaudePluginsDeclarative then "yes" else "no"
    }"
    mkdir -p $out
    touch $out/passed
  '';

  # Multi-target check — both target dirs appear in the activation script and
  # the profile dir gets its extra plugin.
  targets-check = pkgs.runCommand "claude-plugins-targets-check" { } ''
    script=${pkgs.lib.escapeShellArg targetsScript}
    echo "$script" | grep -q "/home/testuser/.claude/plugins/cache" \
      || { echo "FAIL: default target dir missing"; exit 1; }
    echo "$script" | grep -q "/home/testuser/.claude-work/plugins/cache" \
      || { echo "FAIL: profile target dir missing"; exit 1; }
    echo "$script" | grep -q "test-mp/beta" \
      || { echo "FAIL: profile-only plugin missing"; exit 1; }
    echo "Multi-target activation generated correctly"
    mkdir -p $out
    touch $out/passed
  '';
}
