{
  pkgs,
  noctaliaPackage,
  pluginRoot,
}:

let
  inherit (pkgs) lib;

  testUser = "vmtester";
  runtimeRoot = "/run/noctalia-wall-in-one-vm";
  stateRoot = "/var/lib/noctalia-wall-in-one-vm";
  cacheRoot = "/var/cache/noctalia-wall-in-one-vm";
  guestSourceRoot = "${stateRoot}/plugin-source";
  sourceName = "wall-in-one-vm";
  sourceUrl = "file://${guestSourceRoot}";
  sourceStorageRoot =
    "${stateRoot}/state/noctalia/plugins/sources/${sourceName}";
  clonedRepoRoot = "${sourceStorageRoot}/repo";
  pluginId = "goober/wall-in-one";
  serviceId = "${pluginId}:coordinator";
  widgetId = "${pluginId}:wall-in-one";
  materializedRoot =
    "${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/wall-in-one";
  pluginDataRoot =
    "${stateRoot}/state/noctalia/plugins/data/goober/wall-in-one";
  captureRoot = "/home/${testUser}/Pictures/Wall-in-One";

  manifest = builtins.fromTOML (
    builtins.readFile (pluginRoot + "/wall-in-one/plugin.toml")
  );
  catalog = (pkgs.formats.toml { }).generate "wall-in-one-vm-catalog.toml" {
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
        description = "Offline Wallhaven target for Wall-in-One tests.";
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
        description = "Offline W Engine target for Wall-in-One tests.";
        plugin_api = 9;
        deprecated = false;
        tags = [ "test" ];
        dependencies = [ ];
      }
      {
        id = "noctalia/mpvpaper";
        name = "mpvpaper VM Fixture";
        version = "1.0.7";
        author = "VM fixture";
        license = "MIT";
        icon = "movie";
        description = "Offline mpvpaper target for Wall-in-One tests.";
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
    description = "Offline Wallhaven target for Wall-in-One tests."
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
    description = "Offline W Engine target for Wall-in-One tests."
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

    [[service]]
    id = "start"
    entry = "service.luau"
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

  fixtureStill = pkgs.runCommand "wall-in-one-vm-still.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 96x64 'xc:#406080' "png:$out"
  '';

  fixtureVideo = pkgs.runCommand "wall-in-one-vm-video.mp4" {
    nativeBuildInputs = [ pkgs.ffmpeg ];
  } ''
    ffmpeg -nostdin -y -loglevel error \
      -f lavfi -i 'color=c=#804060:s=96x64:d=2' \
      -c:v mpeg4 -pix_fmt yuv420p -f mp4 "$out"
  '';

  wEngineService = pkgs.writeText "w-engine-vm-service.luau" ''
    local TARGET = "${serviceId}"
    local CAPTURE_SOURCE = "${fixtureStill}"
    local announcing = false
    local announced = false
    local silent = false

    local function shellQuote(value)
        return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
    end

    local function tabFields(payload)
        local fields = {}
        for value in (tostring(payload or "") .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(fields, value)
        end
        return fields
    end

    local function announce()
        if silent or announcing or announced then
            return
        end
        announcing = true
        local capabilities = shellQuote("w_engine\t1\tcapture,status")
        local current = shellQuote("w_engine\tHEADLESS-1\t431960001")
        local command = "noctalia msg plugin "
            .. TARGET
            .. " all provider-capabilities-v1 "
            .. capabilities
            .. " && noctalia msg plugin "
            .. TARGET
            .. " all provider-current-v1 "
            .. current
        noctalia.runAsync(command, function(result)
            announcing = false
            announced = type(result) == "table"
                and not result.timedOut
                and tonumber(result.exitCode) == 0
            if announced then
                noctalia.log("W_ENGINE_VM_ADAPTER_ANNOUNCED")
            end
        end, 5000)
    end

    function update()
        noctalia.setUpdateInterval(1000)
        announce()
    end

    function onIpc(event, payload)
        noctalia.log("W_ENGINE_VM_SERVICE " .. tostring(event) .. " " .. tostring(payload or ""))
        if event == "silence" then
            silent = true
            announced = false
            return
        elseif event == "resume" then
            silent = false
            announced = false
            announce()
            return
        end
        if event == "announce" or event == "wall-in-one-probe-v1" then
            if silent then
                return
            end
            announced = false
            announce()
            return
        end
        if event ~= "capture-v1" then
            return
        end

        local fields = tabFields(payload)
        local requestId = tostring(fields[1] or "")
        local output = tostring(fields[2] or "")
        local projectId = tostring(fields[3] or "")
        local destination = tostring(fields[4] or "")
        if requestId == ""
            or output ~= "HEADLESS-1"
            or projectId ~= "431960001"
            or destination:sub(1, 1) ~= "/"
            or destination:find("[%c]") ~= nil
        then
            return
        end

        local resultPayload = requestId .. "\tok\t" .. destination
        local command = "cp -- "
            .. shellQuote(CAPTURE_SOURCE)
            .. " "
            .. shellQuote(destination)
            .. " && noctalia msg plugin "
            .. TARGET
            .. " all capture-result-v1 "
            .. shellQuote(resultPayload)
        noctalia.runAsync(command, function(result)
            if type(result) == "table" and tonumber(result.exitCode) == 0 then
                noctalia.log("W_ENGINE_VM_CAPTURE_RETURNED " .. requestId)
            else
                noctalia.log("W_ENGINE_VM_CAPTURE_FAILED " .. requestId)
            end
        end, 5000)
    end
  '';

  mpvpaperManifest = pkgs.writeText "mpvpaper-vm-plugin.toml" ''
    id = "noctalia/mpvpaper"
    name = "mpvpaper VM Fixture"
    version = "1.0.7"
    plugin_api = 9
    author = "VM fixture"
    license = "MIT"
    icon = "movie"
    description = "Offline mpvpaper target for Wall-in-One tests."
    deprecated = false
    tags = ["test"]
    dependencies = []

    [[panel]]
    id = "picker"
    entry = "panel.luau"
    width = 360
    height = 240
    placement = "floating"
    position = "center"

    [[service]]
    id = "service"
    entry = "service.luau"
  '';
  mpvpaperPanel = pkgs.writeText "mpvpaper-vm-panel.luau" ''
    local function render()
        panel.render(ui.column({ padding = 20 }, {
            ui.label({ text = "mpvpaper VM fixture", fontSize = 18 }),
        }))
    end

    function onOpen(_context)
        noctalia.log("MPVPAPER_VM_PANEL_OPEN")
        render()
    end

    render()
  '';
  mpvpaperService = pkgs.writeText "mpvpaper-vm-service.luau" ''
    function onIpc(event, payload)
        noctalia.log("MPVPAPER_VM_SERVICE " .. tostring(event) .. " " .. tostring(payload or ""))
    end
  '';

  rawPluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = pluginRoot + "/wall-in-one";
  };
  stagedSource = pkgs.runCommand "noctalia-wall-in-one-vm-source" { } ''
    mkdir -p "$out/wall-in-one" "$out/wallhaven" "$out/w-engine" "$out/mpvpaper"
    cp -R ${rawPluginSource}/wall-in-one/. "$out/wall-in-one/"
    cp ${catalog} "$out/catalog.toml"
    cp ${wallhavenManifest} "$out/wallhaven/plugin.toml"
    cp ${wallhavenPanel} "$out/wallhaven/panel.luau"
    cp ${wEngineManifest} "$out/w-engine/plugin.toml"
    cp ${wEnginePanel} "$out/w-engine/panel.luau"
    cp ${wEngineService} "$out/w-engine/service.luau"
    cp ${mpvpaperManifest} "$out/mpvpaper/plugin.toml"
    cp ${mpvpaperPanel} "$out/mpvpaper/panel.luau"
    cp ${mpvpaperService} "$out/mpvpaper/service.luau"
  '';

  fakeNoctalia = pkgs.writeShellApplication {
    name = "noctalia";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      {
        printf '%s' "$$"
        for argument in "$@"; do
          printf '\t%q' "$argument"
        done
        printf '\n'
      } >> /tmp/wall-in-one-vm-noctalia-calls.log

      if [[ "$#" -eq 3 && "$1" == "msg" && "$2" == "plugins" && "$3" == "list" ]]; then
        mode="$(cat /tmp/wall-in-one-vm-provider-mode 2>/dev/null || printf none)"
        if [[ "$mode" == "fail" ]]; then
          printf '%s\n' "fixture provider probe failed" >&2
          exit 17
        fi

        printf '%s\n' "${pluginId} [${sourceName}] ${manifest.version} enabled"
        case "$mode" in
          all)
            printf '%s\n' \
              "noctalia/wallhaven [${sourceName}] 1.0.10 enabled" \
              "tadomika_ari/w-engine [${sourceName}] 1.1.0 enabled" \
              "noctalia/mpvpaper [${sourceName}] 1.0.7 enabled"
            ;;
          tricky)
            printf '%s\n' \
              "noctalia/wallhaven [${sourceName}] 1.0.10 enabled incompatible" \
              "tadomika_ari/w-engine [${sourceName}] 1.1.0 enabled-ish" \
              "noctalia/mpvpaper [${sourceName}] 1.0.7 disabled enabled-ish"
            ;;
          none) ;;
          *)
            printf 'unknown provider fixture mode: %s\n' "$mode" >&2
            exit 18
            ;;
        esac
        exit 0
      fi

      if [[ "$#" -ge 3 && "$1" == "msg" && "$2" == "plugin" ]]; then
        exec ${lib.getExe noctaliaPackage} "$@"
      fi

      if [[ "$#" -ge 2 && "$1" == "msg" && "$2" == color-scheme-* ]]; then
        exec ${lib.getExe noctaliaPackage} "$@"
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
      printf '%s\n' "$*" >> /tmp/wall-in-one-vm-engine-invocations.log
      printf '%s\n' "Wall-in-One must not launch the provider renderer" >&2
      exit 97
    '';
  };

  fakeMpvpaper = pkgs.writeShellApplication {
    name = "mpvpaper";
    text = ''
      printf '%s\n' "$*" >> /tmp/wall-in-one-vm-mpvpaper-invocations.log
      exit 97
    '';
  };

  fakeMpv = pkgs.writeShellApplication {
    name = "mpv";
    text = ''
      printf '%s\n' "$*" >> /tmp/wall-in-one-vm-mpv-invocations.log
      exit 97
    '';
  };

  rendererSentinel = pkgs.writeShellApplication {
    name = "wall-in-one-renderer-sentinel";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      exec sleep infinity
    '';
  };

  # Appended only to the guest's materialized service. It makes plugin-owned
  # state bus observable and drives persistence through the production command
  # handler without adding test APIs to the shipped plugin.
  vmProbe = pkgs.writeText "wall-in-one-vm-probe.luau" ''
    local vmProductionOnIpc = onIpc
    local vmCommandSequence = 900000

    function onIpc(event, payload)
        if event == "vm-probe" then
            noctalia.log(
                "WALL_IN_ONE_VM_PROBE "
                    .. tostring(payload or "")
                    .. " probe_ok="
                    .. tostring(providers.probe_ok)
                    .. " wallhaven="
                    .. tostring(providers.wallhaven.available)
                    .. " w_enabled="
                    .. tostring(providers.w_engine.plugin_enabled)
                    .. " w_command="
                    .. tostring(providers.w_engine.renderer_available)
                    .. " w_available="
                    .. tostring(providers.w_engine.available)
                    .. " adapter_capture="
                    .. tostring(providers.w_engine.adapter_capture)
                    .. " adapter_status="
                    .. tostring(providers.w_engine.adapter_status)
                    .. " current="
                    .. tostring(providers.w_engine.current["HEADLESS-1"] or "")
                    .. " mpvpaper="
                    .. tostring(providers.mpvpaper.available)
                    .. " mpv_command="
                    .. tostring(providers.mpvpaper.command_available)
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
    fakeMpvpaper
    fakeMpv
    pkgs.bash
    pkgs.coreutils
    pkgs.ffmpeg
  ];
  noctaliaRuntimePackages = pluginRuntimePackages ++ [ pkgs.git ];

  vmConfig = pkgs.writeText "noctalia-wall-in-one-vm-config.toml" ''
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

    [plugin_settings."${pluginId}"]
    capture_directory = "${captureRoot}"
    auto_capture = false
    pair_static = true
    sync_colors = true
    color_scheme = "m3-rainbow"
    palette_output = "HEADLESS-1"
    video_source = "${fixtureVideo}"
    manual_pair_file = "${fixtureStill}"
    video_frame_second = 0
    workshop_id = ""
    workshop_directory = ""
    scene_screenshot_delay = 3
    extra_provider_panel = ""

    [widget.wall-in-one-a]
    type = "${widgetId}"
    glyph = "library-photo"
    label = "Wall-in-One"
    show_label = true
    color = "on_surface"

    [widget.wall-in-one-b]
    type = "${widgetId}"
    glyph = "photo"
    label = "Scenes"
    show_label = false
    color = "primary"

    [bar.wall-in-one-test]
    start = ["wall-in-one-a"]
    center = []
    end = ["wall-in-one-b"]
    reserve_space = false
    hover_highlight = false
  '';

  runner = pkgs.writeShellApplication {
    name = "noctalia-wall-in-one-vm-run";
    runtimeInputs = noctaliaRuntimePackages;
    text = ''
      install -d -m 0755 \
        "${guestSourceRoot}" \
        "${stateRoot}/state/noctalia" \
        "${stateRoot}/data/noctalia" \
        "${cacheRoot}/noctalia" \
        /tmp/noctalia-wall-in-one-tools
      cp -R --no-preserve=ownership ${stagedSource}/. "${guestSourceRoot}/"
      chmod -R u+w "${guestSourceRoot}"
      cp ${fakeWallpaperEngine}/bin/linux-wallpaperengine \
        /tmp/noctalia-wall-in-one-tools/linux-wallpaperengine
      chmod u+w /tmp/noctalia-wall-in-one-tools/linux-wallpaperengine
      git -C "${guestSourceRoot}" init --initial-branch=main
      git -C "${guestSourceRoot}" config user.name "Noctalia VM Test"
      git -C "${guestSourceRoot}" config user.email "noctalia-vm@example.invalid"
      git -C "${guestSourceRoot}" add .
      git -C "${guestSourceRoot}" commit -m "Wall-in-One VM fixture"

      # This deep plugin test enables four entries from one source. Seed the
      # same blobless Git cache layout Noctalia owns so beta.7's asynchronous
      # enable workers exercise catalog resolution and export without racing
      # each other during the first clone. The single-plugin VM tests cover
      # Noctalia's clone-on-enable path itself.
      install -d -m 0755 "${sourceStorageRoot}"
      git clone --filter=blob:none --no-checkout \
        "${sourceUrl}" "${clonedRepoRoot}"

      : > /tmp/wall-in-one-vm-noctalia-calls.log
      : > /tmp/wall-in-one-vm-engine-invocations.log
      : > /tmp/wall-in-one-vm-mpvpaper-invocations.log
      : > /tmp/wall-in-one-vm-mpv-invocations.log
      printf '%s\n' all > /tmp/wall-in-one-vm-provider-mode
      touch "${stateRoot}/state/noctalia/.setup-complete"

      export PATH="${fakeNoctalia}/bin:/tmp/noctalia-wall-in-one-tools:$PATH"
      export NOCTALIA_CONFIG_HOME="/etc/noctalia-wall-in-one-vm"
      export NOCTALIA_STATE_HOME="${stateRoot}/state"
      export NOCTALIA_DATA_HOME="${stateRoot}/data"
      export XDG_CACHE_HOME="${cacheRoot}"
      export NOCTALIA_LOG_LEVEL=debug

      exec "${lib.getExe noctaliaPackage}"
    '';
  };

  swayConfig = pkgs.writeText "noctalia-wall-in-one-vm-sway.conf" ''
    xwayland disable
    output HEADLESS-1 mode 1280x720
    exec ${lib.getExe runner}
  '';

in
pkgs.testers.runNixOSTest (
  { ... }:
  {
    name = "noctalia-wall-in-one-vm";

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
          etc."noctalia-wall-in-one-vm/noctalia/config.toml".source = vmConfig;
          systemPackages = [
            noctaliaPackage
            pkgs.grim
            pkgs.jq
            pkgs.python3
          ];
        };

        systemd.services.wall-in-one-renderer-sentinel = {
          description = "Live-wallpaper lifecycle sentinel";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = lib.getExe rendererSentinel;
            Restart = "no";
          };
        };

        systemd.services.noctalia-wall-in-one-vm-session = {
          description = "Isolated Noctalia Wall-in-One test session";
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
            RuntimeDirectory = "noctalia-wall-in-one-vm";
            RuntimeDirectoryMode = "0700";
            StateDirectory = "noctalia-wall-in-one-vm";
            CacheDirectory = "noctalia-wall-in-one-vm";
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
      import json

      journal = "journalctl -u noctalia-wall-in-one-vm-session.service -b --no-pager"

      def wait_log(text: str):
          machine.wait_until_succeeds(
              f"{journal} | grep -F -- {shlex.quote(text)}"
          )

      def fixture_calls():
          result = []
          for line in machine.succeed("cat /tmp/wall-in-one-vm-noctalia-calls.log").splitlines():
              fields = shlex.split(line)
              # Bash %q uses $'...\\t...' for the adapter's tab-delimited
              # payload. Python shlex removes the quotes but intentionally
              # leaves ANSI-C escapes untouched, so normalize that one form
              # before asserting the IPC field contract.
              fields = [
                  field[1:].replace("\\t", "\t")
                  if field.startswith("$") and "\\t" in field
                  else field
                  for field in fields
              ]
              result.append(fields[1:])
          return result

      def set_provider_mode(mode: str):
          command = "printf '%s\\n' " + shlex.quote(mode) + " > /tmp/wall-in-one-vm-provider-mode"
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
          adapter_capture: bool | None = None,
          adapter_status: bool | None = None,
          current: str | None = None,
          mpvpaper: bool | None = None,
          mpv_command: bool | None = None,
          left: str | None = None,
          right: str | None = None,
          storage: bool = True,
      ):
          probe_number[0] += 1
          token = f"probe-{probe_number[0]}"
          fragments = [
              f"WALL_IN_ONE_VM_PROBE {token}",
              f"probe_ok={str(probe_ok).lower()}",
              f"wallhaven={str(wallhaven).lower()}",
              f"w_enabled={str(w_enabled).lower()}",
              f"w_command={str(w_command).lower()}",
              f"w_available={str(w_available).lower()}",
              f"storage={str(storage).lower()}",
          ]
          if adapter_capture is not None:
              fragments.append(f"adapter_capture={str(adapter_capture).lower()}")
          if adapter_status is not None:
              fragments.append(f"adapter_status={str(adapter_status).lower()}")
          if current is not None:
              fragments.append(f"current={current}")
          if mpvpaper is not None:
              fragments.append(f"mpvpaper={str(mpvpaper).lower()}")
          if mpv_command is not None:
              fragments.append(f"mpv_command={str(mpv_command).lower()}")
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
      machine.wait_for_unit("wall-in-one-renderer-sentinel.service")
      machine.wait_for_unit("noctalia-wall-in-one-vm-session.service")
      sentinel_pid = machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip()
      assert sentinel_pid not in ("", "0")
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
          "${guestSourceRoot}/wall-in-one"
      )
      machine.succeed(
          "python3 ${guestSourceRoot}/wall-in-one/tests/test_contract.py"
      )
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{clean_environment} "
          "${lib.getExe noctaliaPackage} config validate "
          "/etc/noctalia-wall-in-one-vm/noctalia/config.toml"
      )

      assert noctalia_msg(
          "plugins source add ${sourceName} git ${sourceUrl}"
      ).strip() == "ok"
      legacy_runtime = json.dumps({
          "schema_version": 1,
          "providers": {"legacy_fixture": {"enabled": True}},
          "pairs": {
              "LEGACY-OUTPUT": {
                  "provider": "legacy",
                  "dynamic_id": "legacy:fixture",
                  "still_path": "/tmp/legacy-wall-in-one.png",
                  "capture_method": "legacy-fixture",
                  "paired_at": "2026-07-31 00:00:00",
              }
          },
          "last_capture": {},
          "observed_at": "2026-07-31 00:00:00",
          "last_error": "",
      })
      machine.succeed(
          "install -d -o ${testUser} -g users ${pluginDataRoot}; "
          "printf '%s\\n' "
          + shlex.quote(legacy_runtime)
          + " > ${pluginDataRoot}/runtime.json; "
          "chown ${testUser}:users ${pluginDataRoot}/runtime.json"
      )
      for fixture_id, fixture_directory in (
          ("noctalia/wallhaven", "wallhaven"),
          ("tadomika_ari/w-engine", "w-engine"),
          ("noctalia/mpvpaper", "mpvpaper"),
      ):
          assert noctalia_msg(f"plugins enable {fixture_id}").strip().startswith("ok")
          wait_log(f"enabling plugin '{fixture_id}' (resolved + exported")
          machine.wait_until_succeeds(
              f"test -f ${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/"
              f"{fixture_directory}/plugin.toml"
          )
      assert noctalia_msg("plugins enable ${pluginId}").strip().startswith("ok")
      wait_log("started service '${serviceId}'")
      wait_log('creating #0 "wall-in-one-test"')

      # Pin the exact beta.7 output grammar before feeding equivalent controlled
      # snapshots to the service subprocess fixture.
      real_plugin_list = noctalia_msg("plugins list")
      assert "noctalia/wallhaven [${sourceName}] 1.0.10 enabled" in real_plugin_list
      assert "tadomika_ari/w-engine [${sourceName}] 1.1.0 enabled" in real_plugin_list
      assert "noctalia/mpvpaper [${sourceName}] 1.0.7 enabled" in real_plugin_list
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
          mpvpaper=True,
          mpv_command=True,
          left="native_open",
          right="w_engine_open",
      )
      wait_log("W_ENGINE_VM_SERVICE wall-in-one-probe-v1")
      noctalia_msg("plugin tadomika_ari/w-engine:start all announce")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          adapter_capture=True,
          adapter_status=True,
          current="431960001",
          mpvpaper=True,
          mpv_command=True,
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
          "'.schema_version == 2 and .providers.w_engine.enabled == true "
          "and .providers.mpvpaper.enabled == true "
          "and .pairs[\"LEGACY-OUTPUT\"].capture_method == \"legacy-fixture\"' "
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
          adapter_capture=False,
          adapter_status=False,
          current="",
          mpvpaper=False,
      )
      before_open = machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN")
      noctalia_msg("plugin ${serviceId} all open-provider wallhaven")
      machine.sleep(1)
      assert machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN") == before_open

      # The renderer executable is a diagnostic only. Provider actions remain
      # available through W Engine's documented plugin service.
      set_provider_mode("all")
      machine.succeed("rm /tmp/noctalia-wall-in-one-tools/linux-wallpaperengine")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=False,
          w_available=True,
          mpvpaper=True,
          mpv_command=True,
          right="w_engine_open",
      )
      machine.succeed(
          "cp ${fakeWallpaperEngine}/bin/linux-wallpaperengine "
          "/tmp/noctalia-wall-in-one-tools/linux-wallpaperengine"
      )
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpvpaper=True,
          mpv_command=True,
          right="w_engine_open",
      )
      noctalia_msg("plugin tadomika_ari/w-engine:start all announce")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          adapter_capture=True,
          adapter_status=True,
          current="431960001",
          mpvpaper=True,
          mpv_command=True,
      )

      # Available provider targets resolve to real VM-only panels.
      assert noctalia_msg(
          "plugin ${serviceId} all open-provider wallhaven"
      ).strip() == "ok: dispatched 1"
      wait_log("WALLHAVEN_VM_PANEL_OPEN")
      noctalia_msg("plugin ${serviceId} all open-provider w_engine")
      wait_log("W_ENGINE_VM_PANEL_OPEN")
      noctalia_msg("plugin ${serviceId} all open-provider mpvpaper")
      wait_log("MPVPAPER_VM_PANEL_OPEN")

      # Documented provider controls route to the provider-owned fixture
      # services. Wall-in-One never invokes either renderer executable.
      for event, provider_event in (
          ("w-engine-next", "next"),
          ("w-engine-cycle-stop", "cycle-stop"),
          ("w-engine-stop", "stop"),
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
          wait_log(f"W_ENGINE_VM_SERVICE {provider_event}")

      for event, provider_event in (
          ("mpvpaper-pause", "pause"),
          ("mpvpaper-resume", "resume"),
          ("mpvpaper-toggle", "toggle"),
          ("mpvpaper-clear", "clear"),
          ("mpvpaper-clear-all", "clear-all"),
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
          wait_log(f"MPVPAPER_VM_SERVICE {provider_event}")

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
              "/tmp/wall-in-one-vm-noctalia-calls.log"
          )

      native_calls = [
          call for call in fixture_calls()
          if len(call) >= 2 and call[0] == "msg" and call[1].startswith("wallpaper-")
      ]
      assert all(len(call) in (2, 3) for call in native_calls), native_calls
      assert all(len(call) == 2 or call[2] == "HEADLESS-1" for call in native_calls), native_calls

      # The immutable VM config opts into an absolute export directory from
      # boot. The private pluginDataDir()/captures default is pinned by the
      # static contract test without mutating a user's live configuration.
      noctalia_msg("plugin tadomika_ari/w-engine:start all announce")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          adapter_capture=True,
          adapter_status=True,
          current="431960001",
          mpvpaper=True,
          mpv_command=True,
      )

      # A configured video is decoded by the bounded helper, exported into the
      # selected absolute directory, persisted as Noctalia's static pair, and
      # used as the explicit wallpaper palette source.
      noctalia_msg("plugin ${serviceId} all capture-video-pair")
      machine.wait_until_succeeds(
          "find ${captureRoot} -maxdepth 1 -type f "
          "-name 'wall-in-one-video-*-HEADLESS-1.png' -size +0c | grep -q ."
      )
      video_still = machine.succeed(
          "find ${captureRoot} -maxdepth 1 -type f "
          "-name 'wall-in-one-video-*-HEADLESS-1.png' -print -quit"
      ).strip()
      machine.succeed(
          "${lib.getExe pkgs.ffmpeg} -v error -i "
          + shlex.quote(video_still)
          + " -f null -"
      )
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- "
          + shlex.quote(video_still)
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --arg path "
          + shlex.quote(video_still)
          + " '.schema_version == 2 "
          + "and .last_capture.provider == \"video\" "
          + "and .last_capture.path == $path "
          + "and .pairs[\"HEADLESS-1\"].still_path == $path "
          + "and .pairs[\"HEADLESS-1\"].color_scheme == \"m3-rainbow\"' "
          + "${pluginDataRoot}/runtime.json"
      )
      machine.wait_until_succeeds(
          noctalia_command("color-scheme-get")
          + " | grep -Fx -- 'wallpaper m3-rainbow'"
      )
      assert ["msg", "color-scheme-set", "wallpaper", "m3-rainbow"] in fixture_calls()

      # The cooperative adapter supplies the current W Engine project and the
      # rendered still. Wall-in-One copies/persists the result but does not
      # inspect provider state or own a renderer process.
      noctalia_msg("plugin ${serviceId} all capture-pair")
      wait_log("W_ENGINE_VM_SERVICE capture-v1")
      wait_log("W_ENGINE_VM_CAPTURE_RETURNED")
      engine_still = "${captureRoot}/wall-in-one-w-engine-431960001-HEADLESS-1.png"
      machine.wait_until_succeeds("test -s " + shlex.quote(engine_still))
      machine.succeed(
          "${lib.getExe pkgs.ffmpeg} -v error -i "
          + shlex.quote(engine_still)
          + " -f null -"
      )
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- "
          + shlex.quote(engine_still)
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --arg path "
          + shlex.quote(engine_still)
          + " '.schema_version == 2 "
          + "and .last_capture.provider == \"w_engine\" "
          + "and .last_capture.dynamic_id == \"431960001\" "
          + "and .last_capture.method == \"w-engine-adapter-v1\" "
          + "and .last_capture.path == $path "
          + "and .pairs[\"HEADLESS-1\"].still_path == $path' "
          + "${pluginDataRoot}/runtime.json"
      )
      adapter_calls = [
          call for call in fixture_calls()
          if len(call) == 6
          and call[:5] == [
              "msg",
              "plugin",
              "tadomika_ari/w-engine:start",
              "all",
              "capture-v1",
          ]
      ]
      assert adapter_calls, fixture_calls()
      first_adapter_fields = adapter_calls[-1][5].split("\t")
      assert len(first_adapter_fields) == 5, first_adapter_fields
      first_staging = first_adapter_fields[3]
      assert first_staging.startswith("${pluginDataRoot}/staging/"), first_staging
      assert first_staging.endswith(".png"), first_staging
      assert first_staging != engine_still
      assert first_adapter_fields[4] == "3"
      machine.wait_until_fails("test -e " + shlex.quote(first_staging))

      # Every request receives a fresh staging path even though the stable
      # exported destination is reused.
      before_returns = machine.succeed(journal).count("W_ENGINE_VM_CAPTURE_RETURNED")
      noctalia_msg("plugin ${serviceId} all capture")
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- W_ENGINE_VM_CAPTURE_RETURNED) "
          f"-gt {before_returns}"
      )
      adapter_calls = [
          call for call in fixture_calls()
          if len(call) == 6 and call[2:5] == [
              "tadomika_ari/w-engine:start",
              "all",
              "capture-v1",
          ]
      ]
      assert len(adapter_calls) >= 2, adapter_calls
      second_staging = adapter_calls[-1][5].split("\t")[3]
      assert second_staging.startswith("${pluginDataRoot}/staging/"), second_staging
      assert second_staging.endswith(".png"), second_staging
      assert second_staging != first_staging
      machine.wait_until_fails("test -e " + shlex.quote(second_staging))

      # Manual pairing is accepted only after the shared helper validates the
      # selected static image; the durable source path remains the persisted
      # Noctalia wallpaper.
      noctalia_msg("plugin ${serviceId} all pair-manual")
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- ${fixtureStill}"
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.pairs[\"HEADLESS-1\"].provider == \"manual\" "
          "and .pairs[\"HEADLESS-1\"].still_path == \"${fixtureStill}\"' "
          "${pluginDataRoot}/runtime.json"
      )

      # Adapter readiness is a lease, not a permanent inference. A successful
      # provider discovery probes W Engine; silence expires stale capability
      # and current-source flags after the ten-second grace period.
      noctalia_msg("plugin tadomika_ari/w-engine:start all silence")
      noctalia_msg("plugin ${serviceId} all probe")
      stale_token = "stale-adapter-expired"
      stale_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_PROBE {stale_token}",
          "w_enabled=true",
          "w_available=true",
          "adapter_capture=false",
          "adapter_status=false",
          "current=",
      ):
          stale_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(f"plugin ${serviceId} all vm-probe {stale_token}")
          + " >/dev/null && "
          + stale_filters
      )
      noctalia_msg("plugin tadomika_ari/w-engine:start all resume")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          adapter_capture=True,
          adapter_status=True,
          current="431960001",
          mpvpaper=True,
          mpv_command=True,
      )
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

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
          "/tmp/wall-in-one-vm-noctalia-calls.log) -ge 2"
      )

      # Render the Wall-in-One hub after the provider, capture, and persistence
      # matrix.
      assert noctalia_msg("panel-toggle ${pluginId}:hub").strip().startswith("ok")
      wait_log("panel.luau")
      machine.sleep(1)
      screenshot = "/tmp/noctalia-wall-in-one-vm.png"
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

      # Ownership boundaries are enforced statically and dynamically. Pairing
      # intentionally uses setWallpaper, but never disables Noctalia's surface,
      # scrapes process/private state, or launches/signals a provider renderer.
      for forbidden in (
          "setWallpaperEnabled(",
          "pgrep",
          "/proc/",
          "/tmp/w-engine",
          "w_engine_status",
          "w_engine_request",
          "saved_wallpaper",
          "setsid",
          "pkill",
      ):
          machine.fail(
              "grep -R --include='*.luau' --include='capture-still' -F -- "
              + shlex.quote(forbidden)
              + " ${materializedRoot}"
          )
      machine.succeed(
          "grep -F 'noctalia.setWallpaper(' ${materializedRoot}/service.luau"
      )
      machine.succeed(
          "grep -F 'capture-v1' ${materializedRoot}/service.luau"
      )
      machine.fail(
          "grep -F 'linux-wallpaperengine' ${materializedRoot}/scripts/capture-still"
      )
      machine.fail(
          "grep -n -F 'linux-wallpaperengine' ${materializedRoot}/service.luau "
          "| grep -Fv 'commandExists(\"linux-wallpaperengine\")'"
      )
      machine.fail(
          "grep -R -E --include='*.luau' --include='capture-still' "
          "'(^|[^[:alnum:]_])(kill|killall|pkill)([^[:alnum:]_]|$)' "
          "${materializedRoot}"
      )
      machine.succeed("test ! -s /tmp/wall-in-one-vm-engine-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpvpaper-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpv-invocations.log")
      machine.fail(
          "find ${pluginDataRoot}/captures ${captureRoot} -type f "
          "\\( -name '*.part' -o -name '*.part.*' \\) | grep -q ."
      )
      machine.fail("find ${pluginDataRoot}/staging -type f | grep -q .")
      machine.succeed("systemctl is-active --quiet wall-in-one-renderer-sentinel.service")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

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
      machine.succeed("systemctl is-active --quiet wall-in-one-renderer-sentinel.service")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid
      machine.succeed("systemctl stop noctalia-wall-in-one-vm-session.service")
      machine.wait_until_fails("pgrep -x noctalia")
    '';
  }
)
