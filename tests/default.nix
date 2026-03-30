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
}
