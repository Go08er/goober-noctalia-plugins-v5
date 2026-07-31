{
  pkgs,
  noctaliaPackage,
  pluginRoot,
}:

let
  inherit (pkgs) lib;

  testUser = "vmtester";
  runtimeRoot = "/run/noctalia-vm";
  stateRoot = "/var/lib/noctalia-vm";
  cacheRoot = "/var/cache/noctalia-vm";
  guestPluginRoot = "${stateRoot}/plugin-source";
  sourceName = "vm-git";
  sourceUrl = "file://${guestPluginRoot}";
  clonedRepoRoot = "${stateRoot}/state/noctalia/plugins/sources/${sourceName}/repo";
  materializedPluginRoot = "${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/hydra-update-examiner";
  pluginId = "goober/hydra-update-examiner";
  serviceId = "${pluginId}:status";
  widgetId = "${pluginId}:hydra";

  pluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = lib.fileset.unions [
      (pluginRoot + "/catalog.toml")
      (pluginRoot + "/hydra-update-examiner")
    ];
  };

  fakeCurl = pkgs.writeShellApplication {
    name = "curl";
    text = ''
      url=""
      accept_json=0

      for argument in "$@"; do
        case "$argument" in
          https://*) url="$argument" ;;
          "Accept: application/json") accept_json=1 ;;
        esac
      done

      printf '%s\n' "$url" >> /tmp/noctalia-vm-curl.log

      case "$url" in
        "https://channels.nixos.org/nixos-unstable/git-revision")
          printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          ;;
        "https://hydra.nixos.org/jobset/nixos/unstable/evals")
          printf '%s\n' '<a href="/eval/4242">evaluation 4242</a>'
          ;;
        "https://hydra.nixos.org/eval/4242")
          if [[ "$accept_json" -eq 1 ]]; then
            printf '%s\n' '{"jobsetevalinputs":{"nixpkgs":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}'
          else
            printf '%s\n' \
              '<span>nixos-unstable.aaaaaaaaaaaa</span>' \
              '<ul class="nav nav-tabs">' \
              '<li>Queued Jobs (0)</li>' \
              '<li>Still Succeeding Jobs (1)</li>' \
              '<li>Still Failing Jobs (0)</li>' \
              '<li>Newly Succeeding Jobs (0)</li>' \
              '<li>Newly Failing Jobs (0)</li>' \
              '<li>Aborted / Timed out Jobs (0)</li>' \
              '<li>New Jobs (0)</li>' \
              '<div class="tab-content">'
          fi
          ;;
        "https://hydra.nixos.org/eval/4242/job/tested")
          printf '%s\n' '{"id":9001,"finished":1,"buildstatus":0,"starttime":1,"nixname":"nixos-system.aaaaaaaaaaaa"}'
          ;;
        "https://hydra.nixos.org/build/9001/constituents")
          printf '%s\n' '[{"finished":1,"buildstatus":0}]'
          ;;
        *)
          printf 'VM fixture has no response for %s\n' "$url" >&2
          exit 22
          ;;
      esac
    '';
  };

  fakeXdgOpen = pkgs.writeShellApplication {
    name = "xdg-open";
    text = ''
      if [[ "$#" -ne 1 ]]; then
        printf 'expected one URL, received %s arguments\n' "$#" >&2
        exit 2
      fi
      printf '%s\n' "$1" >> /tmp/noctalia-vm-xdg-open.log
    '';
  };

  pluginRuntimePackages = [
    fakeCurl
    fakeXdgOpen
    pkgs.bash
    pkgs.jq
    pkgs.perl
    pkgs.gnugrep
    pkgs.gawk
    pkgs.gnused
    pkgs.coreutils
  ];
  noctaliaRuntimePackages = pluginRuntimePackages ++ [ pkgs.git ];
  pluginRuntimePath = lib.makeBinPath pluginRuntimePackages;

  vmConfig = pkgs.writeText "noctalia-vm-config.toml" ''
    [shell]
    offline_mode = true
    telemetry_enabled = false
    setup_wizard_enabled = false
    clipboard_enabled = false

    [plugins]
    enabled = []
    auto_update = false
    source = []

    [plugin_settings."${pluginId}"]
    channel_preset = "nixos-unstable"
    refresh_interval_minutes = 60
    close_threshold = 90

    [widget.hydra-readiness]
    type = "${widgetId}"
    display_mode = "always"

    [bar.hydra-test]
    start = []
    center = ["hydra-readiness"]
    end = []
    reserve_space = false
  '';

  runner = pkgs.writeShellApplication {
    name = "noctalia-vm-run";
    runtimeInputs = noctaliaRuntimePackages;
    text = ''
      install -d -m 0755 \
        "${guestPluginRoot}" \
        "${stateRoot}/state/noctalia" \
        "${stateRoot}/data/noctalia" \
        "${cacheRoot}/noctalia"
      cp -R --no-preserve=ownership "${pluginSource}/." "${guestPluginRoot}/"
      chmod -R u+w "${guestPluginRoot}"
      git -C "${guestPluginRoot}" init --initial-branch=main
      git -C "${guestPluginRoot}" config user.name "Noctalia VM Test"
      git -C "${guestPluginRoot}" config user.email "noctalia-vm@example.invalid"
      git -C "${guestPluginRoot}" add .
      git -C "${guestPluginRoot}" commit -m "VM plugin source fixture"
      touch "${stateRoot}/state/noctalia/.setup-complete"

      export NOCTALIA_CONFIG_HOME=/etc/noctalia-vm
      export NOCTALIA_STATE_HOME="${stateRoot}/state"
      export NOCTALIA_DATA_HOME="${stateRoot}/data"
      export XDG_CACHE_HOME="${cacheRoot}"
      export NOCTALIA_LOG_LEVEL=debug

      exec "${lib.getExe noctaliaPackage}"
    '';
  };

  swayConfig = pkgs.writeText "noctalia-vm-sway.conf" ''
    xwayland disable
    output HEADLESS-1 mode 1280x720
    exec ${lib.getExe runner}
  '';

in
pkgs.testers.runNixOSTest (
  { ... }:
  {
    name = "noctalia-hydra-plugin-vm";

    nodes.machine =
      { pkgs, ... }:
      {
        users.users.${testUser} = {
          isNormalUser = true;
          uid = 1000;
          home = "/home/${testUser}";
          createHome = true;
        };

        services.dbus.enable = true;
        hardware.graphics.enable = true;
        fonts.packages = [ pkgs.dejavu_fonts ];

        environment = {
          etc."noctalia-vm/noctalia/config.toml".source = vmConfig;
          systemPackages = [
            noctaliaPackage
            pkgs.grim
            pkgs.jq
          ];
        };

        systemd.services.noctalia-vm-session = {
          description = "Isolated Noctalia v5 plugin test session";
          # dbus-run-session resolves dbus-daemon through PATH, and Sway's
          # `exec` command resolves a shell before launching the runner.
          path = [
            pkgs.dbus
            pkgs.bash
          ];
          wantedBy = [ "multi-user.target" ];
          after = [
            "dbus.service"
            "systemd-user-sessions.service"
          ];
          requires = [ "dbus.service" ];
          environment = {
            HOME = "/home/${testUser}";
            XDG_RUNTIME_DIR = runtimeRoot;
            WLR_BACKENDS = "headless";
            WLR_HEADLESS_OUTPUTS = "1";
            WLR_RENDERER = "pixman";
            WLR_LIBINPUT_NO_DEVICES = "1";
            LIBGL_ALWAYS_SOFTWARE = "1";
          };
          serviceConfig = {
            User = testUser;
            Group = "users";
            RuntimeDirectory = "noctalia-vm";
            RuntimeDirectoryMode = "0700";
            StateDirectory = "noctalia-vm";
            CacheDirectory = "noctalia-vm";
            ExecStart =
              "${pkgs.dbus}/bin/dbus-run-session -- "
              + "${lib.getExe pkgs.sway} --unsupported-gpu --config ${swayConfig}";
            KillMode = "control-group";
            TimeoutStopSec = 5;
          };
        };

        virtualisation = {
          cores = 2;
          memorySize = 2048;
        };
      };

    testScript = ''
      import pathlib
      import shlex

      journal = "journalctl -u noctalia-vm-session.service -b --no-pager"

      def wait_log(text: str):
          machine.wait_until_succeeds(
              f"{journal} | grep -F -- {shlex.quote(text)}"
          )

      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("noctalia-vm-session.service")
      machine.wait_until_succeeds(
          "find ${runtimeRoot} -maxdepth 1 -type s "
          "-name 'noctalia-wayland-*.sock' | grep -q ."
      )

      socket_path = machine.succeed(
          "find ${runtimeRoot} -maxdepth 1 -type s "
          "-name 'noctalia-wayland-*.sock' -print -quit"
      ).strip()
      socket_name = pathlib.Path(socket_path).name
      display = socket_name.removeprefix("noctalia-").removesuffix(".sock")
      clean_environment = (
          "HOME=/home/${testUser} "
          "PATH=/run/current-system/sw/bin "
          "XDG_DATA_HOME=/home/${testUser}/.local/share "
          "XDG_DATA_DIRS=/run/current-system/sw/share"
      )
      ipc_environment = (
          f"{clean_environment} "
          "XDG_RUNTIME_DIR=${runtimeRoot} "
          f"WAYLAND_DISPLAY={shlex.quote(display)}"
      )

      def noctalia_command(arguments: str) -> str:
          return (
              "runuser -u ${testUser} -- env -i "
              f"{ipc_environment} "
              "${lib.getExe noctaliaPackage} msg "
              f"{arguments}"
          )

      def noctalia_msg(arguments: str) -> str:
          return machine.succeed(noctalia_command(arguments))

      wait_log("layer-shell=yes")

      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{clean_environment} "
          "${lib.getExe noctaliaPackage} plugins lint "
          "${guestPluginRoot}/hydra-update-examiner"
      )
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{clean_environment} "
          "${lib.getExe noctaliaPackage} config validate "
          "/etc/noctalia-vm/noctalia/config.toml"
      )

      # Exercise the same source-add and enable path used for a GitHub source,
      # but clone a deterministic in-guest file:// repository instead.
      assert "${sourceName}" not in noctalia_msg("plugins source list")
      machine.fail("test -e ${clonedRepoRoot}/.git")
      assert "${pluginId}" not in noctalia_msg("plugins list")

      assert noctalia_msg(
          "plugins source add ${sourceName} git ${sourceUrl}"
      ).strip() == "ok"
      assert (
          "${sourceName} git ${sourceUrl}"
          in noctalia_msg("plugins source list")
      )
      # `plugins list` is intentionally local-only and must not clone on the
      # main loop. Enabling performs the network-capable catalog resolution.
      assert "${pluginId}" not in noctalia_msg("plugins list")
      machine.fail("test -e ${clonedRepoRoot}/.git")

      enable_result = noctalia_msg("plugins enable ${pluginId}").strip()
      assert enable_result.startswith("ok"), enable_result

      wait_log("adding plugin source '${sourceName}' (${sourceUrl})")
      wait_log(
          "git clone --filter=blob:none --no-checkout ${sourceUrl} "
          "${clonedRepoRoot}"
      )
      wait_log("enabling plugin '${pluginId}' (resolved + exported")
      wait_log("loaded plugin '${pluginId}' (2 entries)")
      wait_log('creating #0 "hydra-test"')
      wait_log("started service '${serviceId}'")
      wait_log("service.luau")
      wait_log("widget.luau")

      machine.wait_until_succeeds(
          "test -d ${clonedRepoRoot}/.git && "
          "test -f ${materializedPluginRoot}/plugin.toml"
      )
      # A git source is catalog-driven: the cache has no checkout, so discovery
      # must read catalog.toml from the repository root via git-show before the
      # plugin subdirectory can be exported to the materialized runtime tree.
      machine.succeed(
          "runuser -u ${testUser} -- ${lib.getExe pkgs.git} "
          "-C ${clonedRepoRoot} "
          "cat-file -e HEAD:catalog.toml"
      )
      machine.fail("test -e ${clonedRepoRoot}/catalog.toml")
      machine.succeed(
          "test ! -e ${materializedPluginRoot}/catalog.toml && "
          "test -f ${materializedPluginRoot}/widget.luau && "
          "test -f ${materializedPluginRoot}/service.luau"
      )

      plugin_list = noctalia_msg("plugins list")
      assert "${pluginId} [${sourceName}] 0.1.0 enabled" in plugin_list
      assert "incompatible" not in plugin_list

      assert noctalia_msg(
          "plugin ${serviceId} all force-refresh"
      ).strip() == "ok: dispatched 1"
      assert noctalia_msg(
          "plugin ${widgetId} all force-refresh"
      ).strip() == "ok: dispatched 1"

      machine.wait_until_succeeds(
          "grep -Fx 'https://hydra.nixos.org/build/9001/constituents' "
          "/tmp/noctalia-vm-curl.log"
      )
      machine.wait_until_succeeds(
          noctalia_command("plugin ${widgetId} all open")
          + " | grep -Fx 'ok: dispatched 1' && "
          "grep -Fx 'https://hydra.nixos.org/jobset/nixos/unstable/evals' "
          "/tmp/noctalia-vm-xdg-open.log"
      )

      machine.succeed(
          "runuser -u ${testUser} -- env PATH=${pluginRuntimePath} "
          "bash ${materializedPluginRoot}/scripts/hydra-channel-progress "
          "--channel nixos-unstable | "
          "${lib.getExe pkgs.jq} -e "
          "'.state == \"launched\" and .text == \"Launched\"'"
      )

      machine.succeed(
          "printf '\\n-- VM widget hot-reload probe\\n' >> "
          "${materializedPluginRoot}/widget.luau"
      )
      wait_log("hot reload: reloaded 'widget.luau'")
      machine.succeed(
          "printf '\\n-- VM service hot-reload probe\\n' >> "
          "${materializedPluginRoot}/service.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")

      assert noctalia_msg(
          "plugin ${widgetId} all force-refresh"
      ).strip() == "ok: dispatched 1"
      machine.wait_until_succeeds(
          "test $(grep -Fc "
          "'https://hydra.nixos.org/build/9001/constituents' "
          "/tmp/noctalia-vm-curl.log) -ge 2"
      )

      screenshot = "/tmp/noctalia-hydra-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -o HEADLESS-1 "
          f"{screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {screenshot}) -gt 1000")
      machine.copy_from_machine(screenshot)

      logs = machine.succeed(journal)
      for forbidden in (
          "ignoring plugin '${pluginId}'",
          "[luau] ERR",
          "undeclared setting",
          "hot reload: failed",
      ):
          assert forbidden not in logs, f"unexpected log marker: {forbidden}"

      machine.succeed("systemctl stop noctalia-vm-session.service")
      machine.wait_until_fails("pgrep -x noctalia")
    '';
  }
)
