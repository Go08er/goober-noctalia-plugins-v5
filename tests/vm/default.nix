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
    settings_show_advanced = false

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
    display_mode = "on_hover"
    running_color = "tertiary"
    stalled_color = "error"
    close_color = "primary"
    launched_color = "primary"
    running_glyph = "server"
    stalled_glyph = "alert-circle"
    close_glyph = "rocket"
    launched_glyph = "circle-check"

    [widget.hydra-override]
    type = "${widgetId}"
    display_mode = "icon_only"
    running_color = "secondary"
    stalled_color = "error"
    close_color = "tertiary"
    launched_color = "secondary"
    running_glyph = "server-bolt"
    stalled_glyph = "server-off"
    close_glyph = "server-spark"
    launched_glyph = "rocket"

    [bar.hydra-test]
    start = ["hydra-override"]
    center = ["hydra-readiness"]
    end = []
    reserve_space = false
    hover_highlight = false
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

      def wtype(arguments: str) -> str:
          return machine.succeed(
              "runuser -u ${testUser} -- env -i "
              f"{ipc_environment} "
              "${lib.getExe pkgs.wtype} "
              f"{arguments}"
          )

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
      wait_log("loaded plugin '${pluginId}' (3 entries)")
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
          "test -f ${materializedPluginRoot}/panel.luau && "
          "test -f ${materializedPluginRoot}/service.luau"
      )

      plugin_list = noctalia_msg("plugins list")
      assert "${pluginId} [${sourceName}] 0.4.0 enabled" in plugin_list
      assert "incompatible" not in plugin_list

      assert noctalia_msg(
          "plugin ${serviceId} all force-refresh"
      ).strip() == "ok: dispatched 1"
      assert noctalia_msg(
          "plugin ${widgetId} all force-refresh"
      ).strip() == "ok: dispatched 2"

      machine.wait_until_succeeds(
          "grep -Fx 'https://hydra.nixos.org/build/9001/constituents' "
          "/tmp/noctalia-vm-curl.log"
      )
      machine.wait_until_succeeds(
          noctalia_command("plugin ${widgetId} all open")
          + " | grep -Fx 'ok: dispatched 2' && "
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

      # The headless Sway backend has no physical pointer. Exercise the exact
      # production callback by hot-reloading the guest copy with a direct
      # onHover(true) invocation and require its top-center render to change.
      machine.sleep(1)
      hover_hidden = "/tmp/noctalia-hydra-hover-hidden.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -g '540,0 200x40' "
          f"{hover_hidden}"
      )
      # Golden crops pin two independent widget presentations in the launched
      # state: circle-check + primary, and rocket + secondary.
      assert machine.succeed(f"sha256sum {hover_hidden}").split()[0] == (
          "fc2a34b67fb9fd4183dfb2ef0d9559d8d7be9d9d106ba975407342dfff065bf1"
      )
      alternate_placement = "/tmp/noctalia-hydra-alternate-placement.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -g '80,0 160x40' "
          f"{alternate_placement}"
      )
      machine.succeed(f"test $(stat -c %s {alternate_placement}) -gt 500")
      assert machine.succeed(f"sha256sum {alternate_placement}").split()[0] == (
          "5265010082eb59d96c46a39f7791beb0766a84a49e52fffe2392a3060e590c03"
      )
      machine.succeed(
          "printf '\\nonHover(true)\\n' >> "
          "${materializedPluginRoot}/widget.luau"
      )
      wait_log("hot reload: reloaded 'widget.luau'")
      machine.sleep(1)
      hover_visible = "/tmp/noctalia-hydra-hover-visible.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -g '540,0 200x40' "
          f"{hover_visible}"
      )
      machine.fail(f"cmp -s {hover_hidden} {hover_visible}")

      # Open the attached action panel through the same command declared as the
      # widget's right-click default. This instantiates and renders panel.luau.
      panel_result = noctalia_msg("panel-toggle ${pluginId}:actions").strip()
      assert panel_result.startswith("ok"), panel_result
      wait_log("panel.luau")
      machine.sleep(1)
      panel_screenshot = "/tmp/noctalia-hydra-actions-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -o HEADLESS-1 "
          f"{panel_screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {panel_screenshot}) -gt 1000")

      assert noctalia_msg(
          "plugin ${pluginId}:actions all documentation"
      ).strip() == "ok: dispatched 1"
      machine.wait_until_succeeds(
          "grep -Fx "
          "'https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/"
          "hydra-update-examiner#readme' /tmp/noctalia-vm-xdg-open.log"
      )

      machine.succeed(
          "printf '\\n-- VM service hot-reload probe\\n' >> "
          "${materializedPluginRoot}/service.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")
      machine.succeed(
          "printf '\\n-- VM panel hot-reload probe\\n' >> "
          "${materializedPluginRoot}/panel.luau"
      )
      wait_log("hot reload: reloaded 'panel.luau'")

      assert noctalia_msg(
          "plugin ${widgetId} all force-refresh"
      ).strip() == "ok: dispatched 2"
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
      machine.copy_from_machine(hover_hidden)
      machine.copy_from_machine(hover_visible)
      machine.copy_from_machine(alternate_placement)
      machine.copy_from_machine(panel_screenshot)

      # Exercise API 15's scoped settings opener after the rendering captures.
      assert noctalia_msg(
          "plugin ${pluginId}:actions all settings"
      ).strip() == "ok: dispatched 1"
      machine.sleep(1)
      settings_screenshot = "/tmp/noctalia-hydra-settings-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -o HEADLESS-1 "
          f"{settings_screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {settings_screenshot}) -gt 1000")
      machine.copy_from_machine(settings_screenshot)

      # The native searchable glyph selector is attached by Noctalia to
      # widget-scoped `type = "glyph"` controls. Open the center placement's
      # editor and capture its glyph controls.
      assert noctalia_msg(
          "settings-open-widget hydra-test hydra-readiness"
      ).strip() == "ok"
      machine.sleep(1)
      widget_settings_screenshot = "/tmp/noctalia-hydra-widget-settings-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -o HEADLESS-1 "
          f"{widget_settings_screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {widget_settings_screenshot}) -gt 1000")
      machine.copy_from_machine(widget_settings_screenshot)

      # Open the first glyph control's native searchable selector. The sheet
      # starts without keyboard focus; the first pass verifies the streamlined
      # widget surface before opening its first native glyph picker.
      for _ in range(10):
          wtype("-k Tab")
      wtype("-k Return")
      wait_log("logical=568x570")
      machine.sleep(1)
      glyph_picker_screenshot = "/tmp/noctalia-hydra-glyph-picker-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} "
          "${lib.getExe pkgs.grim} -o HEADLESS-1 "
          f"{glyph_picker_screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {glyph_picker_screenshot}) -gt 1000")
      machine.fail(f"cmp -s {widget_settings_screenshot} {glyph_picker_screenshot}")
      machine.copy_from_machine(glyph_picker_screenshot)

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
