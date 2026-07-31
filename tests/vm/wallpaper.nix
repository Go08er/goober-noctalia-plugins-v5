{
  pkgs,
  noctaliaPackage,
  pluginRoot,
}:

let
  inherit (pkgs) lib;

  testUser = "vmtester";
  runtimeRoot = "/run/noctalia-wallpaper-vm";
  stateRoot = "/var/lib/noctalia-wallpaper-vm";
  cacheRoot = "/var/cache/noctalia-wallpaper-vm";
  guestSourceRoot = "${stateRoot}/plugin-source";
  sourceName = "wallpaper-vm";
  sourceUrl = "file://${guestSourceRoot}";
  pluginId = "goober/wallpaper-director";
  serviceId = "${pluginId}:hub";
  widgetId = "${pluginId}:wallpapers";
  materializedRoot =
    "${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/wallpaper-director";
  pluginDataRoot =
    "${stateRoot}/state/noctalia/plugins/data/goober/wallpaper-director";

  manifest = builtins.fromTOML (
    builtins.readFile (pluginRoot + "/wallpaper-director/plugin.toml")
  );
  catalog = (pkgs.formats.toml { }).generate "wallpaper-vm-catalog.toml" {
    plugin = [
      {
        inherit (manifest)
          id
          name
          version
          author
          license
          icon
          description
          plugin_api
          tags
          dependencies
          ;
        deprecated = manifest.deprecated or false;
      }
      {
        id = "noctalia/wallhaven";
        name = "Wallhaven VM Fixture";
        version = "1.0.10";
        author = "VM fixture";
        license = "MIT";
        icon = "world-www";
        description = "Offline panel target for Wallpaper Director tests.";
        plugin_api = 9;
        deprecated = false;
        tags = [ "test" ];
        dependencies = [ ];
      }
      {
        id = "tadomika_ari/w-engine";
        name = "W Engine VM Fixture";
        version = "1.1.0";
        author = "VM fixture";
        license = "MIT";
        icon = "player-play";
        description = "Offline panel target for Wallpaper Director tests.";
        plugin_api = 9;
        deprecated = false;
        tags = [ "test" ];
        dependencies = [ ];
      }
    ];
  };

  wallhavenManifest = pkgs.writeText "wallhaven-vm-plugin.toml" ''
    id = "noctalia/wallhaven"
    name = "Wallhaven VM Fixture"
    version = "1.0.10"
    plugin_api = 9
    author = "VM fixture"
    license = "MIT"
    icon = "world-www"
    description = "Offline panel target for Wallpaper Director tests."
    deprecated = false
    tags = ["test"]
    dependencies = []

    [[panel]]
    id = "browser"
    entry = "panel.luau"
    width = 360
    height = 240
    placement = "floating"
    position = "center"
  '';
  wallhavenPanel = pkgs.writeText "wallhaven-vm-panel.luau" ''
    local function render()
        panel.render(ui.column({ padding = 20 }, {
            ui.label({ text = "Wallhaven VM fixture", fontSize = 18 }),
        }))
    end

    function onOpen(_context)
        noctalia.log("WALLHAVEN_VM_PANEL_OPEN")
        render()
    end

    render()
  '';
  wEngineManifest = pkgs.writeText "w-engine-vm-plugin.toml" ''
    id = "tadomika_ari/w-engine"
    name = "W Engine VM Fixture"
    version = "1.1.0"
    plugin_api = 9
    author = "VM fixture"
    license = "MIT"
    icon = "player-play"
    description = "Offline panel target for Wallpaper Director tests."
    deprecated = false
    tags = ["test"]
    dependencies = []

    [[panel]]
    id = "w-engine-panel"
    entry = "panel.luau"
    width = 360
    height = 240
    placement = "floating"
    position = "center"
  '';
  wEnginePanel = pkgs.writeText "w-engine-vm-panel.luau" ''
    local function render()
        panel.render(ui.column({ padding = 20 }, {
            ui.label({ text = "W Engine VM fixture", fontSize = 18 }),
        }))
    end

    function onOpen(_context)
        noctalia.log("W_ENGINE_VM_PANEL_OPEN")
        render()
    end

    render()
  '';

  rawPluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = pluginRoot + "/wallpaper-director";
  };
  stagedSource = pkgs.runCommand "noctalia-wallpaper-vm-source" { } ''
    mkdir -p "$out/wallpaper-director" "$out/wallhaven" "$out/w-engine"
    cp -R ${rawPluginSource}/wallpaper-director/. "$out/wallpaper-director/"
    cp ${catalog} "$out/catalog.toml"
    cp ${wallhavenManifest} "$out/wallhaven/plugin.toml"
    cp ${wallhavenPanel} "$out/wallhaven/panel.luau"
    cp ${wEngineManifest} "$out/w-engine/plugin.toml"
    cp ${wEnginePanel} "$out/w-engine/panel.luau"
  '';

  fakeNoctalia = pkgs.writeShellApplication {
    name = "noctalia";
    text = ''
      {
        printf '%s' "$$"
        for argument in "$@"; do
          printf '\t%q' "$argument"
        done
        printf '\n'
      } >> /tmp/wallpaper-vm-noctalia-calls.log

      if [[ "$#" -eq 3 && "$1" == "msg" && "$2" == "plugins" && "$3" == "list" ]]; then
        mode="$(cat /tmp/wallpaper-vm-provider-mode 2>/dev/null || printf none)"
        if [[ "$mode" == "fail" ]]; then
          printf '%s\n' "fixture provider probe failed" >&2
          exit 17
        fi

        printf '%s\n' "goober/wallpaper-director [wallpaper-vm] 0.1.0 enabled"
        case "$mode" in
          both)
            printf '%s\n' \
              "noctalia/wallhaven [wallpaper-vm] 1.0.10 enabled" \
              "tadomika_ari/w-engine [wallpaper-vm] 1.1.0 enabled"
            ;;
          wallhaven)
            printf '%s\n' \
              "noctalia/wallhaven [wallpaper-vm] 1.0.10 enabled" \
              "tadomika_ari/w-engine [wallpaper-vm] 1.1.0"
            ;;
          w-engine)
            printf '%s\n' \
              "noctalia/wallhaven [wallpaper-vm] 1.0.10" \
              "tadomika_ari/w-engine [wallpaper-vm] 1.1.0 enabled"
            ;;
          tricky)
            printf '%s\n' \
              "noctalia/wallhaven [wallpaper-vm] 1.0.10 enabled incompatible" \
              "tadomika_ari/w-engine [wallpaper-vm] 1.1.0 enabled-ish"
            ;;
          none) ;;
          *)
            printf 'unknown provider fixture mode: %s\n' "$mode" >&2
            exit 18
            ;;
        esac
        exit 0
      fi

      if [[ "$#" -ge 2 && "$1" == "msg" ]]; then
        case "$2" in
          wallpaper-next|wallpaper-previous|wallpaper-random)
            printf '%s\n' "ok"
            exit 0
            ;;
        esac
      fi

      printf 'unexpected noctalia fixture invocation\n' >&2
      exit 64
    '';
  };

  fakeWallpaperEngine = pkgs.writeShellApplication {
    name = "linux-wallpaperengine";
    text = ''
      printf '%s\n' "$*" >> /tmp/wallpaper-vm-engine-invocations.log
      printf '%s\n' "Wallpaper Director must not own this process" >&2
      exit 97
    '';
  };

  # Appended only to the guest's materialized service. It makes the private
  # state bus observable and drives persistence through the production command
  # handler without adding test APIs to the shipped plugin.
  vmProbe = pkgs.writeText "wallpaper-vm-probe.luau" ''
    local vmProductionOnIpc = onIpc
    local vmCommandSequence = 900000

    function onIpc(event, payload)
        if event == "vm-probe" then
            noctalia.log(
                "WALLPAPER_VM_PROBE "
                    .. tostring(payload or "")
                    .. " probe_ok="
                    .. tostring(providers.probe_ok)
                    .. " wallhaven="
                    .. tostring(providers.wallhaven.available)
                    .. " w_enabled="
                    .. tostring(providers.w_engine.plugin_enabled)
                    .. " w_command="
                    .. tostring(providers.w_engine.command_available)
                    .. " w_available="
                    .. tostring(providers.w_engine.available)
                    .. " left="
                    .. tostring(config.gestures.left)
                    .. " middle="
                    .. tostring(config.gestures.middle)
                    .. " right="
                    .. tostring(config.gestures.right)
                    .. " storage="
                    .. tostring(configValid and runtimeValid)
            )
        elseif event == "vm-map-right-random" then
            vmCommandSequence += 1
            handleCommand({
                kind = "set_mapping",
                button = "right",
                action = "native_random",
                sequence = vmCommandSequence,
            })
        elseif event == "vm-map-left-previous" then
            vmCommandSequence += 1
            handleCommand({
                kind = "set_mapping",
                button = "left",
                action = "native_previous",
                sequence = vmCommandSequence,
            })
        elseif type(vmProductionOnIpc) == "function" then
            vmProductionOnIpc(event, payload)
        end
    end
  '';

  pluginRuntimePackages = [
    fakeNoctalia
    pkgs.bash
    pkgs.coreutils
  ];
  noctaliaRuntimePackages = pluginRuntimePackages ++ [ pkgs.git ];

  vmConfig = pkgs.writeText "noctalia-wallpaper-vm-config.toml" ''
    [shell]
    offline_mode = true
    telemetry_enabled = false
    setup_wizard_enabled = false
    clipboard_enabled = false
    settings_show_advanced = true

    [plugins]
    enabled = []
    auto_update = false
    source = []

    [widget.wallpaper-a]
    type = "${widgetId}"
    glyph = "library-photo"
    label = "Wallpapers"
    show_label = true
    color = "on_surface"

    [widget.wallpaper-b]
    type = "${widgetId}"
    glyph = "photo"
    label = "Scenes"
    show_label = false
    color = "primary"

    [bar.wallpaper-test]
    start = ["wallpaper-a"]
    center = []
    end = ["wallpaper-b"]
    reserve_space = false
    hover_highlight = false
  '';

  runner = pkgs.writeShellApplication {
    name = "noctalia-wallpaper-vm-run";
    runtimeInputs = noctaliaRuntimePackages;
    text = ''
      install -d -m 0755 \
        "${guestSourceRoot}" \
        "${stateRoot}/state/noctalia" \
        "${stateRoot}/data/noctalia" \
        "${cacheRoot}/noctalia" \
        /tmp/noctalia-wallpaper-tools
      cp -R --no-preserve=ownership ${stagedSource}/. "${guestSourceRoot}/"
      chmod -R u+w "${guestSourceRoot}"
      cp ${fakeWallpaperEngine}/bin/linux-wallpaperengine \
        /tmp/noctalia-wallpaper-tools/linux-wallpaperengine
      chmod u+w /tmp/noctalia-wallpaper-tools/linux-wallpaperengine
      git -C "${guestSourceRoot}" init --initial-branch=main
      git -C "${guestSourceRoot}" config user.name "Noctalia VM Test"
      git -C "${guestSourceRoot}" config user.email "noctalia-vm@example.invalid"
      git -C "${guestSourceRoot}" add .
      git -C "${guestSourceRoot}" commit -m "Wallpaper VM fixture"

      : > /tmp/wallpaper-vm-noctalia-calls.log
      : > /tmp/wallpaper-vm-engine-invocations.log
      printf '%s\n' both > /tmp/wallpaper-vm-provider-mode
      touch "${stateRoot}/state/noctalia/.setup-complete"

      export PATH="${fakeNoctalia}/bin:/tmp/noctalia-wallpaper-tools:$PATH"
      export NOCTALIA_CONFIG_HOME=/etc/noctalia-wallpaper-vm
      export NOCTALIA_STATE_HOME="${stateRoot}/state"
      export NOCTALIA_DATA_HOME="${stateRoot}/data"
      export XDG_CACHE_HOME="${cacheRoot}"
      export NOCTALIA_LOG_LEVEL=debug

      exec "${lib.getExe noctaliaPackage}"
    '';
  };

  swayConfig = pkgs.writeText "noctalia-wallpaper-vm-sway.conf" ''
    xwayland disable
    output HEADLESS-1 mode 1280x720
    exec ${lib.getExe runner}
  '';

in
pkgs.testers.runNixOSTest (
  { ... }:
  {
    name = "noctalia-wallpaper-director-vm";

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
          etc."noctalia-wallpaper-vm/noctalia/config.toml".source = vmConfig;
          systemPackages = [
            noctaliaPackage
            pkgs.grim
            pkgs.jq
            pkgs.python3
          ];
        };

        systemd.services.wallpaper-engine-sentinel = {
          description = "Live-wallpaper lifecycle sentinel";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${lib.getExe' pkgs.coreutils "sleep"} infinity";
            Restart = "always";
          };
        };

        systemd.services.noctalia-wallpaper-vm-session = {
          description = "Isolated Noctalia Wallpaper Director test session";
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
            RuntimeDirectory = "noctalia-wallpaper-vm";
            RuntimeDirectoryMode = "0700";
            StateDirectory = "noctalia-wallpaper-vm";
            CacheDirectory = "noctalia-wallpaper-vm";
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

      journal = "journalctl -u noctalia-wallpaper-vm-session.service -b --no-pager"

      def wait_log(text: str):
          machine.wait_until_succeeds(
              f"{journal} | grep -F -- {shlex.quote(text)}"
          )

      def fixture_calls():
          result = []
          for line in machine.succeed("cat /tmp/wallpaper-vm-noctalia-calls.log").splitlines():
              fields = shlex.split(line)
              result.append(fields[1:])
          return result

      def set_provider_mode(mode: str):
          command = "printf '%s\\n' " + shlex.quote(mode) + " > /tmp/wallpaper-vm-provider-mode"
          machine.succeed(
              "runuser -u ${testUser} -- sh -c " + shlex.quote(command)
          )

      probe_number = [0]
      def wait_provider(
          *,
          probe_ok: bool,
          wallhaven: bool,
          w_enabled: bool,
          w_command: bool,
          w_available: bool,
          left: str | None = None,
          right: str | None = None,
          storage: bool = True,
      ):
          probe_number[0] += 1
          token = f"probe-{probe_number[0]}"
          fragments = [
              f"WALLPAPER_VM_PROBE {token}",
              f"probe_ok={str(probe_ok).lower()}",
              f"wallhaven={str(wallhaven).lower()}",
              f"w_enabled={str(w_enabled).lower()}",
              f"w_command={str(w_command).lower()}",
              f"w_available={str(w_available).lower()}",
              f"storage={str(storage).lower()}",
          ]
          if left is not None:
              fragments.append(f"left={left}")
          if right is not None:
              fragments.append(f"right={right}")
          filters = journal
          for fragment in fragments:
              filters += f" | grep -F -- {shlex.quote(fragment)}"
          # Probe and observation are retried together so asynchronous completion
          # cannot make this assertion timing-dependent.
          machine.wait_until_succeeds(
              noctalia_command("plugin ${serviceId} all probe")
              + " >/dev/null && "
              + noctalia_command(f"plugin ${serviceId} all vm-probe {token}")
              + " >/dev/null && "
              + filters
          )

      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("wallpaper-engine-sentinel.service")
      machine.wait_for_unit("noctalia-wallpaper-vm-session.service")
      machine.wait_until_succeeds(
          "find ${runtimeRoot} -maxdepth 1 -type s "
          "-name 'noctalia-wayland-*.sock' | grep -q ."
      )

      socket_path = machine.succeed(
          "find ${runtimeRoot} -maxdepth 1 -type s "
          "-name 'noctalia-wayland-*.sock' -print -quit"
      ).strip()
      display = pathlib.Path(socket_path).name.removeprefix("noctalia-").removesuffix(".sock")
      clean_environment = (
          "HOME=/home/${testUser} "
          "PATH=/run/current-system/sw/bin "
          "XDG_DATA_HOME=/home/${testUser}/.local/share "
          "XDG_DATA_DIRS=/run/current-system/sw/share"
      )
      ipc_environment = (
          f"{clean_environment} XDG_RUNTIME_DIR=${runtimeRoot} "
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
          "${guestSourceRoot}/wallpaper-director"
      )
      machine.succeed(
          "python3 ${guestSourceRoot}/wallpaper-director/tests/test_contract.py"
      )
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{clean_environment} "
          "${lib.getExe noctaliaPackage} config validate "
          "/etc/noctalia-wallpaper-vm/noctalia/config.toml"
      )

      assert noctalia_msg(
          "plugins source add ${sourceName} git ${sourceUrl}"
      ).strip() == "ok"
      for fixture_id in ("noctalia/wallhaven", "tadomika_ari/w-engine"):
          assert noctalia_msg(f"plugins enable {fixture_id}").strip().startswith("ok")
      assert noctalia_msg("plugins enable ${pluginId}").strip().startswith("ok")
      wait_log("started service '${serviceId}'")
      wait_log('creating #0 "wallpaper-test"')

      # Pin the exact beta.7 output grammar before feeding equivalent controlled
      # snapshots to the service subprocess fixture.
      real_plugin_list = noctalia_msg("plugins list")
      assert "noctalia/wallhaven [${sourceName}] 1.0.10 enabled" in real_plugin_list
      assert "tadomika_ari/w-engine [${sourceName}] 1.1.0 enabled" in real_plugin_list
      assert "${pluginId} [${sourceName}] ${manifest.version} enabled" in real_plugin_list

      machine.succeed(
          "cat ${materializedRoot}/service.luau ${vmProbe} "
          "> ${materializedRoot}/service.luau.new; "
          "mv ${materializedRoot}/service.luau.new ${materializedRoot}/service.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          left="native_open",
          right="w_engine_open",
      )

      # Initial storage is versioned and contains only the documented registry.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 1 and .gestures.left == \"native_open\" "
          "and .gestures.middle == \"wallhaven_open\" "
          "and .gestures.right == \"w_engine_open\"' "
          "${pluginDataRoot}/config.json"
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 1 and .providers.probe_ok == true' "
          "${pluginDataRoot}/runtime.json"
      )

      # Exact-token provider parsing: incompatible/enabled-ish lines do not count.
      set_provider_mode("tricky")
      wait_provider(
          probe_ok=True,
          wallhaven=False,
          w_enabled=False,
          w_command=True,
          w_available=False,
      )
      before_open = machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN")
      noctalia_msg("plugin ${serviceId} all open-provider wallhaven")
      machine.sleep(1)
      assert machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN") == before_open

      # A separately enabled W Engine plugin is still unavailable when its
      # renderer command disappears; no fallback/remapping occurs.
      set_provider_mode("both")
      machine.succeed("rm /tmp/noctalia-wallpaper-tools/linux-wallpaperengine")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=False,
          w_available=False,
          right="w_engine_open",
      )
      machine.succeed(
          "cp ${fakeWallpaperEngine}/bin/linux-wallpaperengine "
          "/tmp/noctalia-wallpaper-tools/linux-wallpaperengine"
      )
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          right="w_engine_open",
      )

      # Available provider targets resolve to real VM-only panels.
      assert noctalia_msg(
          "plugin ${serviceId} all open-provider wallhaven"
      ).strip() == "ok: dispatched 1"
      wait_log("WALLHAVEN_VM_PANEL_OPEN")
      noctalia_msg("plugin ${serviceId} all open-provider w_engine")
      wait_log("W_ENGINE_VM_PANEL_OPEN")

      # Native switching uses only Noctalia's fixed IPC verbs and an optional
      # validated output name.
      for event, verb in (
          ("next", "wallpaper-next"),
          ("previous", "wallpaper-previous"),
          ("random", "wallpaper-random"),
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
          machine.wait_until_succeeds(
              f"grep -F $'\\tmsg\\t{verb}' "
              "/tmp/wallpaper-vm-noctalia-calls.log"
          )

      native_calls = [
          call for call in fixture_calls()
          if len(call) >= 2 and call[0] == "msg" and call[1].startswith("wallpaper-")
      ]
      assert all(len(call) in (2, 3) for call in native_calls), native_calls
      assert all(len(call) == 2 or call[2] == "HEADLESS-1" for call in native_calls), native_calls

      # Mapping changes use atomic replacement. A second write rotates the
      # previous valid file into .bak and reload preserves the current mapping.
      noctalia_msg("plugin ${serviceId} all vm-map-right-random")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e '.gestures.right == \"native_random\"' "
          "${pluginDataRoot}/config.json"
      )
      noctalia_msg("plugin ${serviceId} all vm-map-left-previous")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.gestures.left == \"native_previous\" and .gestures.right == \"native_random\"' "
          "${pluginDataRoot}/config.json"
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.gestures.left == \"native_open\" and .gestures.right == \"native_random\"' "
          "${pluginDataRoot}/config.json.bak"
      )
      machine.fail("test -e ${pluginDataRoot}/config.json.tmp")

      machine.succeed("printf '\\n-- VM persistence reload probe\\n' >> ${materializedRoot}/service.luau")
      wait_log("hot reload: reloaded service '${serviceId}'")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          left="native_previous",
          right="native_random",
      )
      noctalia_msg("plugin ${serviceId} all gesture right")
      machine.wait_until_succeeds(
          "test $(grep -Fc $'\\tmsg\\twallpaper-random' "
          "/tmp/wallpaper-vm-noctalia-calls.log) -ge 2"
      )

      # Render the Director panel after the provider and persistence matrix.
      assert noctalia_msg("panel-toggle ${pluginId}:director").strip().startswith("ok")
      wait_log("panel.luau")
      machine.sleep(1)
      screenshot = "/tmp/noctalia-wallpaper-director-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} ${lib.getExe pkgs.grim} -o HEADLESS-1 {screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {screenshot}) -gt 1000")
      machine.copy_from_machine(screenshot)

      # Corrupt user data is evidence: reload must not reset or overwrite it,
      # and action dispatch remains disabled.
      assert noctalia_msg("plugins disable ${pluginId}").strip().startswith("ok")
      machine.succeed("printf '%s\\n' '{broken-json' > ${pluginDataRoot}/config.json")
      before_native = len([
          call for call in fixture_calls()
          if len(call) >= 2 and call[:2] == ["msg", "wallpaper-next"]
      ])
      assert noctalia_msg("plugins enable ${pluginId}").strip().startswith("ok")
      wait_log("started service '${serviceId}'")
      machine.sleep(1)
      assert machine.succeed("cat ${pluginDataRoot}/config.json").strip() == "{broken-json"
      noctalia_msg("plugin ${serviceId} all next")
      machine.sleep(1)
      after_native = len([
          call for call in fixture_calls()
          if len(call) >= 2 and call[:2] == ["msg", "wallpaper-next"]
      ])
      assert after_native == before_native

      # Phase-one ownership boundaries are enforced both statically and at
      # runtime. The external live-wallpaper sentinel remains untouched.
      machine.fail("grep -R --include='*.luau' -F 'setWallpaperEnabled(' ${materializedRoot}")
      machine.fail("grep -R --include='*.luau' -F 'setWallpaper(' ${materializedRoot}")
      machine.succeed("test ! -s /tmp/wallpaper-vm-engine-invocations.log")
      machine.fail(
          "test -e ${stateRoot}/state/noctalia/plugins/data/tadomika_ari/w-engine"
      )
      machine.succeed("systemctl is-active --quiet wallpaper-engine-sentinel.service")

      logs = machine.succeed(journal)
      for forbidden in (
          "ignoring plugin '${pluginId}'",
          "[luau] ERR",
          "[glyph] missing glyph",
          "undeclared setting",
          "hot reload: failed",
      ):
          assert forbidden not in logs, f"unexpected log marker: {forbidden}"

      noctalia_msg("plugins disable ${pluginId}")
      machine.succeed("systemctl is-active --quiet wallpaper-engine-sentinel.service")
      machine.succeed("systemctl stop noctalia-wallpaper-vm-session.service")
      machine.wait_until_fails("pgrep -x noctalia")
    '';
  }
)
