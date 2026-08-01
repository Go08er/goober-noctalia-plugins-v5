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
  configRoot = "${stateRoot}/config";
  guestSourceRoot = "${stateRoot}/plugin-source";
  sourceName = "wall-in-one-vm";
  sourceUrl = "file://${guestSourceRoot}";
  sourceStorageRoot =
    "${stateRoot}/state/noctalia/plugins/sources/${sourceName}";
  clonedRepoRoot = "${sourceStorageRoot}/repo";
  pluginId = "goober/wall-in-one";
  serviceId = "${pluginId}:coordinator";
  rendererServiceId = "${pluginId}:renderer";
  motionServiceId = "${pluginId}:motionbgs";
  widgetId = "${pluginId}:wall-in-one";
  materializedRoot =
    "${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/wall-in-one";
  pluginDataRoot =
    "${stateRoot}/state/noctalia/plugins/data/goober/wall-in-one";
  captureRoot = "/home/${testUser}/Pictures/Wall-in-One";
  videoRoot = "/home/${testUser}/Videos/Wall-in-One";

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

  fixtureVideoStill = pkgs.runCommand "wall-in-one-vm-video-still.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 96x64 'xc:#208060' "png:$out"
  '';

  fixtureWorkshopStill = pkgs.runCommand "wall-in-one-vm-workshop-still.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 96x64 'xc:#802060' "png:$out"
  '';

  fixtureGif = pkgs.runCommand "wall-in-one-vm-animated.gif" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 96x64 -delay 10 'xc:#d08020' -delay 10 'xc:#20a0d0' \
      -loop 0 "gif:$out"
  '';

  fixtureVideo = pkgs.runCommand "wall-in-one-vm-video.mp4" {
    nativeBuildInputs = [ pkgs.ffmpeg ];
  } ''
    ffmpeg -nostdin -y -loglevel error \
      -f lavfi -i 'color=c=#804060:s=96x64:d=2' \
      -c:v mpeg4 -pix_fmt yuv420p -f mp4 "$out"
  '';

  fixtureWorkshop = pkgs.runCommand "wall-in-one-vm-workshop" { } ''
    mkdir -p "$out/431960001"
    cp ${fixtureStill} "$out/431960001/preview.png"
    cp ${fixtureVideo} "$out/431960001/wallpaper.mp4"
    printf '%s\n' '{"title":"VM Night City","type":"video","file":"wallpaper.mp4","preview":"preview.png"}' \
      > "$out/431960001/project.json"
  '';

  motionSearchHtml = pkgs.writeText "motionbgs-search.html" ''
    <!doctype html><html><body>
      <a href="/night-city" title="Night City Live Wallpaper">
        <span class="ttl">Night City</span>
        <span class="frm">4K</span>
        <img src="/media/4242/thumb.jpg">
      </a>
      <a href="https://evil.example/not-a-card" title="Ignore Live Wallpaper">
        <span class="ttl">Cross origin</span>
      </a>
    </body></html>
  '';
  motionDetailHtml = pkgs.writeText "motionbgs-detail.html" ''
    <!doctype html><html><head>
      <meta property="og:title" content="Night City Live Wallpaper">
      <meta property="og:image" content="/media/4242/poster.jpg">
      <meta property="og:video" content="/media/4242/preview.mp4">
    </head><body>
      <a href="/dl/hd/4242/">1920x1080 (3.5 MB)</a>
      <a href="/dl/4k/4242/">3840x2160 (9.0 MB)</a>
    </body></html>
  '';
  motionChallengeHtml = pkgs.writeText "motionbgs-challenge.html" ''
    <!doctype html><html><head><title>Just a moment...</title></head>
    <body><p>Checking your browser</p></body></html>
  '';
  motionMarkupHtml = pkgs.writeText "motionbgs-markup.html" ''
    <!doctype html><html><body><main>Fixture layout changed</main></body></html>
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
          wallpaper-get)
            [[ "$#" -eq 3 && "$3" == "HEADLESS-1" ]] || exit 65
            printf '%s\n' "${fixtureStill}"
            exit 0
            ;;
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

  fakeMotionBgsHelper = pkgs.writeText "wall-in-one-motionbgs-provider-fixture" ''
    #!/usr/bin/env bash
    set -uo pipefail

    {
      printf '%q' "$1"
      for argument in "''${@:2}"; do
        printf '\t%q' "$argument"
      done
      printf '\n'
    } >> /tmp/wall-in-one-vm-motion-calls.log

    mode=$(cat /tmp/wall-in-one-vm-motion-mode 2>/dev/null || printf good)
    case ''${1:-} in
      self-test)
        [[ $# -eq 1 ]] || exit 64
        printf 'WIO-MBG1\tok\tself-test\n'
        ;;
      fetch-html)
        [[ $# -eq 3 ]] || exit 64
        url=$2
        destination=$3
        case $mode in
          good)
            case $url in
              https://motionbgs.com/night-city) source=${motionDetailHtml} ;;
              *) source=${motionSearchHtml} ;;
            esac
            effective=$url
            ;;
          challenge)
            source=${motionChallengeHtml}
            effective=$url
            ;;
          markup)
            source=${motionMarkupHtml}
            effective=$url
            ;;
          cross-origin)
            source=${motionSearchHtml}
            effective=https://evil.example/search
            ;;
          deny)
            printf 'WIO-MBG1\terror\tfixture-deny\tcache miss unexpectedly reached helper\n'
            exit 69
            ;;
          *) exit 64 ;;
        esac
        temporary="$destination.part"
        cp -- "$source" "$temporary"
        mv -f -- "$temporary" "$destination"
        bytes=$(stat -c %s -- "$destination")
        printf 'WIO-MBG1\tok\t200\t%s\ttext/html\t%s\t%s\n' \
          "$effective" "$bytes" "$destination"
        ;;
      download)
        [[ $# -eq 8 ]] || exit 64
        slug=$3
        quality=$4
        directory=$5
        destination="$directory/$slug.$quality.mp4"
        temporary="$destination.part"
        cp -- ${fixtureVideo} "$temporary"
        mv -f -- "$temporary" "$destination"
        bytes=$(stat -c %s -- "$destination")
        effective="https://motionbgs.com/dl/$quality/4242/"
        printf \
          '{"schema":1,"provider":"MotionBGS","title":"Night City","source_page":"https://motionbgs.com/night-city","download_url":"%s","quality":"%s","bytes":%s}\n' \
          "$effective" "$quality" "$bytes" \
          > "$destination.motionbgs.json.part"
        mv -f -- "$destination.motionbgs.json.part" "$destination.motionbgs.json"
        printf 'WIO-MBG1\tok\t200\t%s\tvideo/mp4\t%s\t%s\n' \
          "$effective" "$bytes" "$destination"
        ;;
      *)
        printf 'WIO-MBG1\terror\tusage\tfixture expected fetch-html, download, or self-test\n'
        exit 64
        ;;
    esac
  '';

  fakeWallpaperEngine = pkgs.writeShellApplication {
    name = "linux-wallpaperengine";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      pid=$$
      printf '%s\n' "$pid" > /tmp/wall-in-one-vm-engine-current.pid
      {
        printf '%s\0' "$pid"
        printf '%s\0' "$@"
      } > "/tmp/wall-in-one-vm-engine-$pid.args"
      printf '%s\n' "$pid" >> /tmp/wall-in-one-vm-engine-invocations.log
      trap 'exit 0' TERM INT HUP
      while :; do sleep 1; done
    '';
  };

  fakeMpvpaper = pkgs.writeShellApplication {
    name = "mpvpaper";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      pid=$$
      printf '%s\n' "$pid" > /tmp/wall-in-one-vm-mpvpaper-current.pid
      {
        printf '%s\0' "$pid"
        printf '%s\0' "$@"
      } > "/tmp/wall-in-one-vm-mpvpaper-$pid.args"
      printf '%s\n' "$pid" >> /tmp/wall-in-one-vm-mpvpaper-invocations.log
      trap 'exit 0' TERM INT HUP
      while :; do sleep 1; done
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
    local vmPreviousAck = noctalia.state.get(COMMAND_ACK_KEY)
    if type(vmPreviousAck) == "table" then
        vmCommandSequence = math.max(vmCommandSequence, tonumber(vmPreviousAck.sequence) or 0)
    end

    local function vmHandle(request)
        vmCommandSequence += 1
        request.sequence = vmCommandSequence
        handleCommand(request)
    end

    function onIpc(event, payload)
        if event == "vm-probe" then
            noctalia.log(
                "WALL_IN_ONE_VM_PROBE "
                    .. tostring(payload or "")
                    .. " probe_ok="
                    .. tostring(providers.probe_ok)
                    .. " wallhaven_allowed="
                    .. tostring(providers.wallhaven.allowed)
                    .. " wallhaven="
                    .. tostring(providers.wallhaven.available)
                    .. " w_allowed="
                    .. tostring(providers.w_engine.allowed)
                    .. " w_enabled="
                    .. tostring(providers.w_engine.plugin_enabled)
                    .. " w_command="
                    .. tostring(providers.w_engine.renderer_available)
                    .. " w_available="
                    .. tostring(providers.w_engine.available)
                    .. " w_backend="
                    .. tostring(providers.w_engine.effective_backend)
                    .. " w_apply="
                    .. tostring(providers.w_engine.apply_available)
                    .. " w_conflict="
                    .. tostring(providers.w_engine.conflict)
                    .. " adapter_capture="
                    .. tostring(providers.w_engine.adapter_capture)
                    .. " adapter_status="
                    .. tostring(providers.w_engine.adapter_status)
                    .. " current="
                    .. tostring(providers.w_engine.current["HEADLESS-1"] or "")
                    .. " mpv_allowed="
                    .. tostring(providers.mpvpaper.allowed)
                    .. " mpvpaper="
                    .. tostring(providers.mpvpaper.available)
                    .. " mpv_command="
                    .. tostring(providers.mpvpaper.command_available)
                    .. " mpv_backend="
                    .. tostring(providers.mpvpaper.effective_backend)
                    .. " mpv_apply="
                    .. tostring(providers.mpvpaper.apply_available)
                    .. " mpv_conflict="
                    .. tostring(providers.mpvpaper.conflict)
                    .. " renderer_ready="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.ready == true)
                    .. " renderer_owned="
                    .. tostring(
                        type(rendererStatus) == "table"
                            and type(rendererStatus.outputs) == "table"
                            and type(rendererStatus.outputs["HEADLESS-1"]) == "table"
                    )
                    .. " extra_allowed="
                    .. tostring(providers.extra.allowed)
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
            vmHandle({
                kind = "set_mapping",
                button = "right",
                action = "native_random",
            })
        elseif event == "vm-map-left-previous" then
            vmHandle({
                kind = "set_mapping",
                button = "left",
                action = "native_previous",
            })
        elseif event == "vm-apply-video" then
            vmHandle({
                kind = "apply_entry",
                output = "HEADLESS-1",
                entry = { kind = "video", source = "${fixtureVideo}", label = "VM video" },
            })
        elseif event == "vm-apply-workshop" then
            vmHandle({
                kind = "apply_entry",
                output = "HEADLESS-1",
                entry = { kind = "workshop", source = "431960001", label = "VM Workshop" },
            })
        elseif event == "vm-cycle-seed" then
            vmHandle({
                kind = "cycle_add_entry",
                output = "HEADLESS-1",
                entry = { kind = "static", source = "${fixtureStill}", label = "VM still" },
            })
            vmHandle({
                kind = "cycle_add_entry",
                output = "HEADLESS-1",
                entry = {
                    kind = "video",
                    source = "${fixtureVideo}",
                    still_path = "${fixtureVideoStill}",
                    label = "VM video",
                },
            })
            vmHandle({
                kind = "cycle_add_entry",
                output = "HEADLESS-1",
                entry = {
                    kind = "workshop",
                    source = "431960001",
                    still_path = "${fixtureWorkshopStill}",
                    label = "VM Workshop",
                },
            })
            vmHandle({
                kind = "cycle_options",
                output = "HEADLESS-1",
                interval_seconds = 60,
                order = "sequential",
            })
        elseif event == "vm-cycle-action" then
            vmHandle({
                kind = "action",
                output = "HEADLESS-1",
                action = "cycle_" .. tostring(payload or ""),
            })
        elseif event == "vm-cycle-probe" then
            local state = type(runtime.cycles["HEADLESS-1"]) == "table" and runtime.cycles["HEADLESS-1"] or {}
            local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs["HEADLESS-1"] or {}
            noctalia.log(
                "WALL_IN_ONE_VM_CYCLE "
                    .. tostring(payload or "")
                    .. " running=" .. tostring(state.running == true)
                    .. " paused=" .. tostring(state.paused == true)
                    .. " cursor=" .. tostring(tonumber(state.cursor) or 0)
                    .. " history=" .. tostring(type(state.history) == "table" and #state.history or 0)
                    .. " applying=" .. tostring(cycleApplying["HEADLESS-1"] ~= nil)
                    .. " backend=" .. tostring((type(owned) == "table" and owned.backend) or "none")
            )
        elseif event == "vm-library-refresh" then
            refreshLibrary()
            local completed = stepLibraryScan()
            local scan = type(libraryScan) == "table" and libraryScan or {}
            noctalia.log(
                "WALL_IN_ONE_VM_LIBRARY_REFRESH "
                    .. tostring(payload or "")
                    .. " completed=" .. tostring(completed == true)
                    .. " scanning=" .. tostring(library.scanning == true)
                    .. " queued_videos=" .. tostring(type(scan.video_entries) == "table" and #scan.video_entries or 0)
                    .. " processed_videos=" .. tostring(type(scan.videos) == "table" and #scan.videos or 0)
                    .. " phase=" .. tostring(scan.phase or "")
            )
        elseif event == "vm-library-probe" then
            noctalia.log(
                "WALL_IN_ONE_VM_LIBRARY "
                    .. tostring(payload or "")
                    .. " scanning=" .. tostring(library.scanning == true)
                    .. " videos=" .. tostring(type(library.videos) == "table" and #library.videos or 0)
                    .. " workshops=" .. tostring(type(library.workshops) == "table" and #library.workshops or 0)
            )
        elseif event == "vm-motion-search" or event == "vm-motion-search-force" then
            vmHandle({
                kind = "motionbgs_search",
                query = tostring(payload or "night city"),
                force = event == "vm-motion-search-force",
            })
        elseif event == "vm-motion-details" then
            vmHandle({ kind = "motionbgs_details", slug = tostring(payload or "night-city"), force = true })
        elseif event == "vm-motion-download" then
            vmHandle({ kind = "motionbgs_download", slug = tostring(payload or "night-city"), quality = "hd" })
        elseif event == "vm-motion-clear" then
            vmHandle({ kind = "motionbgs_clear" })
        elseif event == "vm-motion-probe" then
            local items = type(motionBgsResults) == "table" and motionBgsResults.items or {}
            local selected = type(motionBgsResults) == "table" and motionBgsResults.selected or {}
            local downloaded = type(motionBgsStatus) == "table" and motionBgsStatus.last_download or {}
            noctalia.log(
                "WALL_IN_ONE_VM_MOTION "
                    .. tostring(payload or "")
                    .. " available=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.available == true)
                    .. " busy=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.busy == true)
                    .. " action=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.last_action or "")
                    .. " error_kind=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.last_error_kind or "")
                    .. " cached=" .. tostring(type(motionBgsResults) == "table" and motionBgsResults.cached == true)
                    .. " items=" .. tostring(type(items) == "table" and #items or 0)
                    .. " first=" .. tostring(type(items[1]) == "table" and items[1].slug or "")
                    .. " selected=" .. tostring(type(selected) == "table" and selected.slug or "")
                    .. " download=" .. tostring(type(downloaded) == "table" and downloaded.path or "")
            )
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
    pkgs.curl
    pkgs.ffmpeg
    pkgs.xdg-utils
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
    use_wallhaven = true
    use_w_engine = true
    use_mpvpaper = true
    use_motionbgs = true
    use_extra_provider = true
    w_engine_backend = "auto"
    mpvpaper_backend = "auto"
    capture_directory = "${captureRoot}"
    video_directory = "${videoRoot}"
    motionbgs_download_directory = "${videoRoot}"
    motionbgs_quality = "hd"
    motionbgs_result_limit = 24
    motionbgs_cache_minutes = 30
    motionbgs_max_download_mb = 16
    auto_capture = false
    pair_static = true
    sync_colors = true
    color_scheme = "m3-rainbow"
    palette_output = "HEADLESS-1"
    video_source = "${fixtureVideo}"
    manual_pair_file = "${fixtureStill}"
    video_frame_second = 0
    workshop_id = "431960001"
    workshop_directory = "${fixtureWorkshop}"
    scene_screenshot_delay = 3
    w_engine_scaling = "fill"
    w_engine_clamp = "border"
    w_engine_fps = 60
    w_engine_volume = 15
    w_engine_silent = false
    w_engine_noautomute = true
    w_engine_no_audio_processing = true
    w_engine_disable_particles = true
    w_engine_disable_mouse = true
    w_engine_disable_parallax = true
    w_engine_no_fullscreen_pause = false
    w_engine_fullscreen_pause_only_active = true
    mpv_mute = true
    mpv_hardware_decode = true
    mpv_auto_pause = true
    mpv_auto_pause_mode = "FULL"
    mpv_options = "keep-open=yes"
    cycle_interval_minutes = 15
    cycle_order = "sequential"
    cycle_start_on_load = false
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
        "${configRoot}/noctalia" \
        "${stateRoot}/state/noctalia" \
        "${stateRoot}/data/noctalia" \
        "${cacheRoot}/noctalia" \
        /tmp/noctalia-wall-in-one-tools \
        "${captureRoot}" \
        "${videoRoot}"
      for index in 1 2 3 4 5 6; do
        cp ${fixtureVideo} "${videoRoot}/library-$index.mp4"
      done
      cp -R --no-preserve=ownership ${stagedSource}/. "${guestSourceRoot}/"
      cp ${vmConfig} "${configRoot}/noctalia/config.toml"
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
      : > /tmp/wall-in-one-vm-motion-calls.log
      printf '%s\n' all > /tmp/wall-in-one-vm-provider-mode
      printf '%s\n' good > /tmp/wall-in-one-vm-motion-mode
      touch "${stateRoot}/state/noctalia/.setup-complete"

      export PATH="${fakeNoctalia}/bin:/tmp/noctalia-wall-in-one-tools:$PATH"
      export NOCTALIA_CONFIG_HOME="${configRoot}"
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

      def set_integrations(enabled: bool):
          value = str(enabled).lower()
          expression = (
              r"s/^([[:space:]]*use_(wallhaven|w_engine|mpvpaper|extra_provider)"
              r"[[:space:]]*=[[:space:]]*)(true|false)$/\1" + value + "/"
          )
          machine.succeed(
              "sed -i -E "
              + shlex.quote(expression)
              + " ${configRoot}/noctalia/config.toml"
          )

      def set_integration(name: str, enabled: bool):
          assert name in ("wallhaven", "w_engine", "mpvpaper", "extra_provider")
          value = str(enabled).lower()
          expression = (
              r"s/^([[:space:]]*use_"
              + name
              + r"[[:space:]]*=[[:space:]]*)(true|false)$/\1"
              + value
              + "/"
          )
          machine.succeed(
              "sed -i -E "
              + shlex.quote(expression)
              + " ${configRoot}/noctalia/config.toml"
          )

      def set_backend(name: str, backend: str):
          assert name in ("w_engine", "mpvpaper")
          assert backend in ("auto", "external", "internal")
          expression = (
              r's/^([[:space:]]*'
              + name
              + r'_backend[[:space:]]*=[[:space:]]*)"[^"]*"$/\1"'
              + backend
              + r'"/'
          )
          machine.succeed(
              "sed -i -E "
              + shlex.quote(expression)
              + " ${configRoot}/noctalia/config.toml"
          )

      def set_manual_pair(path: str):
          assert "|" not in path
          expression = (
              r's|^([[:space:]]*manual_pair_file[[:space:]]*=[[:space:]]*)"[^"]*"$|\1"'
              + path
              + r'"|'
          )
          machine.succeed(
              "sed -i -E "
              + shlex.quote(expression)
              + " ${configRoot}/noctalia/config.toml"
          )

      def set_motion_mode(mode: str):
          command = "printf '%s\\n' " + shlex.quote(mode) + " > /tmp/wall-in-one-vm-motion-mode"
          machine.succeed("runuser -u ${testUser} -- sh -c " + shlex.quote(command))

      probe_number = [0]
      def wait_provider(
          *,
          probe_ok: bool,
          wallhaven: bool,
          w_enabled: bool,
          w_command: bool,
          w_available: bool,
          w_backend: str | None = None,
          w_apply: bool | None = None,
          w_conflict: bool | None = None,
          wallhaven_allowed: bool | None = None,
          w_allowed: bool | None = None,
          adapter_capture: bool | None = None,
          adapter_status: bool | None = None,
          current: str | None = None,
          mpv_allowed: bool | None = None,
          mpvpaper: bool | None = None,
          mpv_command: bool | None = None,
          mpv_backend: str | None = None,
          mpv_apply: bool | None = None,
          mpv_conflict: bool | None = None,
          renderer_ready: bool | None = None,
          renderer_owned: bool | None = None,
          extra_allowed: bool | None = None,
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
          if wallhaven_allowed is not None:
              fragments.append(f"wallhaven_allowed={str(wallhaven_allowed).lower()}")
          if w_allowed is not None:
              fragments.append(f"w_allowed={str(w_allowed).lower()}")
          if w_backend is not None:
              fragments.append(f"w_backend={w_backend}")
          if w_apply is not None:
              fragments.append(f"w_apply={str(w_apply).lower()}")
          if w_conflict is not None:
              fragments.append(f"w_conflict={str(w_conflict).lower()}")
          if adapter_capture is not None:
              fragments.append(f"adapter_capture={str(adapter_capture).lower()}")
          if adapter_status is not None:
              fragments.append(f"adapter_status={str(adapter_status).lower()}")
          if current is not None:
              fragments.append(f"current={current}")
          if mpv_allowed is not None:
              fragments.append(f"mpv_allowed={str(mpv_allowed).lower()}")
          if mpvpaper is not None:
              fragments.append(f"mpvpaper={str(mpvpaper).lower()}")
          if mpv_command is not None:
              fragments.append(f"mpv_command={str(mpv_command).lower()}")
          if mpv_backend is not None:
              fragments.append(f"mpv_backend={mpv_backend}")
          if mpv_apply is not None:
              fragments.append(f"mpv_apply={str(mpv_apply).lower()}")
          if mpv_conflict is not None:
              fragments.append(f"mpv_conflict={str(mpv_conflict).lower()}")
          if renderer_ready is not None:
              fragments.append(f"renderer_ready={str(renderer_ready).lower()}")
          if renderer_owned is not None:
              fragments.append(f"renderer_owned={str(renderer_owned).lower()}")
          if extra_allowed is not None:
              fragments.append(f"extra_allowed={str(extra_allowed).lower()}")
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

      cycle_probe_number = [0]
      def wait_cycle(*, running: bool, paused: bool, cursor: int, history: int, applying: bool, backend: str):
          cycle_probe_number[0] += 1
          token = f"cycle-{cycle_probe_number[0]}"
          fragments = (
              f"WALL_IN_ONE_VM_CYCLE {token}",
              f"running={str(running).lower()}",
              f"paused={str(paused).lower()}",
              f"cursor={cursor}",
              f"history={history}",
              f"applying={str(applying).lower()}",
              f"backend={backend}",
          )
          filters = journal
          for fragment in fragments:
              filters += f" | grep -F -- {shlex.quote(fragment)}"
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-cycle-probe {token}")
              + " >/dev/null && "
              + filters
          )

      def drive_cycle(action: str, condition: str):
          # Check first so a completed asynchronous action cannot be repeated
          # and overshoot its target between polling iterations.
          machine.wait_until_succeeds(
              "(" + condition + ") || ("
              + noctalia_command(f"plugin ${serviceId} all vm-cycle-action {action}")
              + " >/dev/null && "
              + condition
              + ")"
          )

      motion_probe_number = [0]
      def wait_motion(**expected):
          motion_probe_number[0] += 1
          token = f"motion-{motion_probe_number[0]}"
          filters = journal + " | grep -F -- " + shlex.quote(
              f"WALL_IN_ONE_VM_MOTION {token}"
          )
          for key, value in expected.items():
              if isinstance(value, bool):
                  value = str(value).lower()
              filters += " | grep -F -- " + shlex.quote(f"{key}={value}")
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-motion-probe {token}")
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
      machine.succeed(
          "install -d -o ${testUser} -g users ${pluginDataRoot}/staging; "
          "printf owned > ${pluginDataRoot}/staging/capture-owned-startup.png; "
          "printf unrelated > ${pluginDataRoot}/staging/unrelated-sentinel.png; "
          "printf unrelated > ${pluginDataRoot}/staging/capture-unrelated.txt; "
          "chown -R ${testUser}:users ${pluginDataRoot}/staging"
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
      wait_log("started service '${rendererServiceId}'")
      wait_log("started service '${motionServiceId}'")
      wait_log('creating #0 "wall-in-one-test"')
      machine.wait_until_fails(
          "test -e ${pluginDataRoot}/staging/capture-owned-startup.png"
      )
      machine.succeed(
          "test -f ${pluginDataRoot}/staging/unrelated-sentinel.png; "
          "test -f ${pluginDataRoot}/staging/capture-unrelated.txt; "
          "rm ${pluginDataRoot}/staging/unrelated-sentinel.png "
          "${pluginDataRoot}/staging/capture-unrelated.txt"
      )

      machine.succeed(
          "runuser -u ${testUser} -- bash "
          "${materializedRoot}/scripts/motionbgs-provider self-test "
          "| grep -Fx $'WIO-MBG1\\tok\\tself-test'"
      )
      machine.succeed(
          "cp ${fakeMotionBgsHelper} ${materializedRoot}/scripts/motionbgs-provider; "
          "chmod 0755 ${materializedRoot}/scripts/motionbgs-provider"
      )

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
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          w_backend="external",
          w_apply=False,
          w_conflict=False,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          mpv_backend="external",
          mpv_apply=False,
          mpv_conflict=False,
          renderer_ready=True,
          extra_allowed=True,
          left="native_open",
          right="w_engine_open",
      )

      # Refresh performs only bounded candidate collection synchronously. One
      # explicit production scan step consumes exactly the four-item budget;
      # normal update ticks finish the remaining videos and Workshop metadata.
      library_refresh_token = "bounded-library-refresh"
      noctalia_msg(
          f"plugin ${serviceId} all vm-library-refresh {library_refresh_token}"
      )
      for fragment in (
          f"WALL_IN_ONE_VM_LIBRARY_REFRESH {library_refresh_token}",
          "completed=false",
          "scanning=true",
          "queued_videos=6",
          "processed_videos=4",
          "phase=videos",
      ):
          wait_log(fragment)
      library_done_token = "bounded-library-done"
      library_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_LIBRARY {library_done_token}",
          "scanning=false",
          "videos=6",
          "workshops=1",
      ):
          library_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-library-probe {library_done_token}"
          )
          + " >/dev/null && "
          + library_filters
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

      # Legacy runtime is migrated without losing observations or pairs. The
      # current documents include the persistent reel and dynamic-pair stores.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 2 and .gestures.left == \"native_open\" "
          "and .gestures.middle == \"wallhaven_open\" "
          "and .gestures.right == \"w_engine_open\" and (.reels | type) == \"object\"' "
          "${pluginDataRoot}/config.json"
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 3 and .providers.w_engine.enabled == true "
          "and .providers.wallhaven.allowed == true "
          "and .providers.wallhaven.available == true "
          "and .providers.w_engine.allowed == true "
          "and .providers.w_engine.available == true "
          "and .providers.mpvpaper.allowed == true "
          "and .providers.mpvpaper.available == true "
          "and .providers.mpvpaper.enabled == true "
          "and (.pair_registry | type) == \"object\" "
          "and (.cycles | type) == \"object\" "
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

      # Auto mode routes documented controls to the provider-owned services and
      # does not launch an internal duplicate.
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

      machine.succeed("test ! -s /tmp/wall-in-one-vm-engine-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpvpaper-invocations.log")

      # Explicit internal selection while the external plugins are enabled is
      # a hard conflict. Both apply paths fail closed without a second child.
      set_backend("w_engine", "internal")
      set_backend("mpvpaper", "internal")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          w_backend="none",
          w_apply=False,
          w_conflict=True,
          mpvpaper=True,
          mpv_command=True,
          mpv_backend="none",
          mpv_apply=False,
          mpv_conflict=True,
          renderer_ready=True,
      )
      noctalia_msg("plugin ${serviceId} all vm-apply-video")
      noctalia_msg("plugin ${serviceId} all vm-apply-workshop")
      machine.sleep(1)
      machine.succeed("test ! -s /tmp/wall-in-one-vm-engine-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpvpaper-invocations.log")

      # With no external plugin detected, the same explicit settings activate
      # the internal owners. The fakes stay alive so exact argv/replacement and
      # teardown can be checked without a real live-wallpaper compositor.
      set_provider_mode("none")
      wait_provider(
          probe_ok=True,
          wallhaven=False,
          w_enabled=False,
          w_command=True,
          w_available=False,
          w_backend="internal",
          w_apply=True,
          w_conflict=False,
          mpvpaper=False,
          mpv_command=True,
          mpv_backend="internal",
          mpv_apply=True,
          mpv_conflict=False,
          renderer_ready=True,
      )
      noctalia_msg("plugin ${serviceId} all vm-apply-video")
      machine.wait_until_succeeds("test -s /tmp/wall-in-one-vm-mpvpaper-current.pid")
      mpv_pid = machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-current.pid").strip()
      machine.succeed(f"kill -0 {mpv_pid}")
      mpv_args = machine.succeed(
          f"tr '\\0' '\\n' < /tmp/wall-in-one-vm-mpvpaper-{mpv_pid}.args"
      ).splitlines()
      assert mpv_args[1:6] == ["--layer", "bottom", "--auto-pause", "FULL", "--auto-mode"], mpv_args
      assert mpv_args[-2:] == ["HEADLESS-1", "${fixtureVideo}"], mpv_args
      mpv_options = mpv_args[mpv_args.index("-o") + 1]
      for token in (
          "loop-file=inf",
          "panscan=1.0",
          "terminal=no",
          "no-audio",
          "hwdec=auto",
          "keep-open=yes",
      ):
          assert token in mpv_options, (token, mpv_options)

      noctalia_msg("plugin ${serviceId} all vm-apply-workshop")
      machine.wait_until_succeeds("test -s /tmp/wall-in-one-vm-engine-current.pid")
      engine_pid = machine.succeed("cat /tmp/wall-in-one-vm-engine-current.pid").strip()
      machine.succeed(f"kill -0 {engine_pid}")
      machine.wait_until_fails(f"kill -0 {mpv_pid}")
      engine_args = machine.succeed(
          f"tr '\\0' '\\n' < /tmp/wall-in-one-vm-engine-{engine_pid}.args"
      ).splitlines()
      assert engine_args[1:] == [
          "--screen-root", "HEADLESS-1", "--bg", "431960001",
          "--scaling", "fill", "--clamp", "border", "--layer", "bottom",
          "--fps", "60", "--volume", "15", "--noautomute",
          "--no-audio-processing", "--disable-particles", "--disable-mouse",
          "--disable-parallax", "--fullscreen-pause-only-active",
      ], engine_args
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # Seed and drive one persistent mixed reel while both internal backends
      # are active. The first static entry replaces the existing live child;
      # later entries exercise owned pause/resume/replacement.
      noctalia_msg("plugin ${serviceId} all vm-cycle-seed")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 2 "
          "and .reels[\"HEADLESS-1\"].interval_seconds == 60 "
          "and .reels[\"HEADLESS-1\"].order == \"sequential\" "
          "and (.reels[\"HEADLESS-1\"].entries | length) == 3 "
          "and .reels[\"HEADLESS-1\"].entries[0].kind == \"static\" "
          "and .reels[\"HEADLESS-1\"].entries[1].kind == \"video\" "
          "and .reels[\"HEADLESS-1\"].entries[1].still_path == \"${fixtureVideoStill}\" "
          "and .reels[\"HEADLESS-1\"].entries[2].kind == \"workshop\" "
          "and .reels[\"HEADLESS-1\"].entries[2].still_path == \"${fixtureWorkshopStill}\"' "
          "${pluginDataRoot}/config.json"
      )
      drive_cycle(
          "start",
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 3 and .cycles[\"HEADLESS-1\"].running == true "
          "and .cycles[\"HEADLESS-1\"].paused == false "
          "and .cycles[\"HEADLESS-1\"].cursor == 1 "
          "and .cycles[\"HEADLESS-1\"].next_due > now "
          "and (.cycles[\"HEADLESS-1\"].history | length) == 1' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_fails(f"kill -0 {engine_pid}")
      wait_cycle(running=True, paused=False, cursor=1, history=1, applying=False, backend="none")

      drive_cycle(
          "next",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].cursor == 2 "
          "and (.cycles[\"HEADLESS-1\"].history | length) == 2' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          "test -s /tmp/wall-in-one-vm-mpvpaper-current.pid; "
          "test \"$(cat /tmp/wall-in-one-vm-mpvpaper-current.pid)\" != " + mpv_pid
      )
      cycle_mpv_pid = machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-current.pid").strip()
      machine.succeed(f"kill -0 {cycle_mpv_pid}")
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- ${fixtureVideoStill}"
      )
      wait_cycle(running=True, paused=False, cursor=2, history=2, applying=False, backend="mpvpaper")
      drive_cycle(
          "pause",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].paused == true' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" = T"
      )
      wait_cycle(running=True, paused=True, cursor=2, history=2, applying=False, backend="mpvpaper")
      noctalia_msg("plugin ${serviceId} all vm-cycle-action next")
      machine.sleep(1)
      machine.succeed(
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].paused == true "
          "and .cycles[\"HEADLESS-1\"].cursor == 2 "
          "and (.cycles[\"HEADLESS-1\"].history | length) == 2' "
          "${pluginDataRoot}/runtime.json"
      )
      machine.succeed(
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" = T"
      )
      drive_cycle(
          "resume",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].running == true "
          "and .cycles[\"HEADLESS-1\"].paused == false' ${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" != T"
      )
      wait_cycle(running=True, paused=False, cursor=2, history=2, applying=False, backend="mpvpaper")

      drive_cycle(
          "next",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].cursor == 3 "
          "and (.cycles[\"HEADLESS-1\"].history | length) == 3' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          "test \"$(cat /tmp/wall-in-one-vm-engine-current.pid)\" != " + engine_pid
      )
      cycle_engine_pid = machine.succeed("cat /tmp/wall-in-one-vm-engine-current.pid").strip()
      machine.succeed(f"kill -0 {cycle_engine_pid}")
      machine.wait_until_fails(f"kill -0 {cycle_mpv_pid}")
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- ${fixtureWorkshopStill}"
      )
      wait_cycle(running=True, paused=False, cursor=3, history=3, applying=False, backend="w-engine")

      drive_cycle(
          "previous",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].cursor == 2 "
          "and (.cycles[\"HEADLESS-1\"].history | length) == 2' "
          "${pluginDataRoot}/runtime.json",
      )
      wait_cycle(running=True, paused=False, cursor=2, history=2, applying=False, backend="mpvpaper")
      history_before_random = int(machine.succeed(
          "${lib.getExe pkgs.jq} '.cycles[\"HEADLESS-1\"].history | length' "
          "${pluginDataRoot}/runtime.json"
      ))
      # `previous` persists its cursor before the renderer acknowledges the
      # replacement. Retrying the command+observation pair proves the
      # coordinator rejects overlap and accepts the next action once idle.
      machine.wait_until_succeeds(
          noctalia_command("plugin ${serviceId} all vm-cycle-action random")
          + " >/dev/null && test $(${lib.getExe pkgs.jq} "
          "'.cycles[\"HEADLESS-1\"].history | length' "
          "${pluginDataRoot}/runtime.json) -gt " + str(history_before_random)
      )
      drive_cycle(
          "stop",
          "${lib.getExe pkgs.jq} -e '.cycles[\"HEADLESS-1\"].running == false "
          "and .cycles[\"HEADLESS-1\"].paused == false "
          "and .cycles[\"HEADLESS-1\"].next_due == 0' "
          "${pluginDataRoot}/runtime.json",
      )
      wait_provider(
          probe_ok=True,
          wallhaven=False,
          w_enabled=False,
          w_command=True,
          w_available=False,
          w_backend="internal",
          w_apply=True,
          w_conflict=False,
          mpvpaper=False,
          mpv_command=True,
          mpv_backend="internal",
          mpv_apply=True,
          mpv_conflict=False,
          renderer_ready=True,
          renderer_owned=False,
      )
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # Losing the external-ownership observation is not evidence that no
      # external owner exists. Force a provider probe failure while an internal
      # child is live: both backends must fail closed and the exact owned child
      # must stop, without touching the unrelated sentinel. A successful probe
      # is required before internal apply becomes available again.
      previous_mpv_invocations = len(
          machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-invocations.log").splitlines()
      )
      noctalia_msg("plugin ${serviceId} all vm-apply-video")
      machine.wait_until_succeeds(
          "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -gt "
          + str(previous_mpv_invocations)
      )
      probe_failure_pid = machine.succeed(
          "cat /tmp/wall-in-one-vm-mpvpaper-current.pid"
      ).strip()
      machine.succeed(f"kill -0 {probe_failure_pid}")
      set_provider_mode("fail")
      wait_provider(
          probe_ok=False,
          wallhaven=False,
          w_enabled=False,
          w_command=True,
          w_available=False,
          w_backend="none",
          w_apply=False,
          w_conflict=False,
          mpvpaper=False,
          mpv_command=True,
          mpv_backend="none",
          mpv_apply=False,
          mpv_conflict=False,
          renderer_ready=True,
          renderer_owned=False,
      )
      machine.wait_until_fails(f"kill -0 {probe_failure_pid}")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      set_provider_mode("none")
      wait_provider(
          probe_ok=True,
          wallhaven=False,
          w_enabled=False,
          w_command=True,
          w_available=False,
          w_backend="internal",
          w_apply=True,
          w_conflict=False,
          mpvpaper=False,
          mpv_command=True,
          mpv_backend="internal",
          mpv_apply=True,
          mpv_conflict=False,
          renderer_ready=True,
          renderer_owned=False,
      )

      set_backend("w_engine", "auto")
      set_backend("mpvpaper", "auto")
      set_provider_mode("all")
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          w_backend="external",
          w_apply=False,
          w_conflict=False,
          mpvpaper=True,
          mpv_command=True,
          mpv_backend="external",
          mpv_apply=False,
          mpv_conflict=False,
      )
      machine.wait_until_fails(f"kill -0 {engine_pid}")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # MotionBGS runs entirely against pinned local HTML/MP4 fixtures. The
      # shipped helper's self-test ran before replacement above.
      wait_motion(available=True, busy=False)
      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(action="search", cached=False, items=1, first="night-city")
      motion_calls_after_search = len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      )

      # A fresh cache hit must not invoke even a deliberately failing helper.
      set_motion_mode("deny")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(action="search", cached=True, items=1, first="night-city")
      assert len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      ) == motion_calls_after_search

      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-details night-city")
      wait_motion(action="details", selected="night-city")

      set_motion_mode("challenge")
      noctalia_msg("plugin ${serviceId} all vm-motion-search-force challenge")
      wait_motion(action="search", error_kind="challenge", busy=False)
      set_motion_mode("markup")
      noctalia_msg("plugin ${serviceId} all vm-motion-search-force changed-layout")
      wait_motion(action="search", error_kind="site-markup", busy=False)
      set_motion_mode("cross-origin")
      noctalia_msg("plugin ${serviceId} all vm-motion-search-force wrong-origin")
      wait_motion(action="search", error_kind="protocol", busy=False)

      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-download night-city")
      motion_download = "${videoRoot}/night-city.hd.mp4"
      wait_motion(action="download", download=motion_download, busy=False)
      machine.succeed("${lib.getExe pkgs.ffmpeg} -v error -i " + motion_download + " -f null -")
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.schema == 1 and .provider == \"MotionBGS\" and .quality == \"hd\"' "
          + motion_download
          + ".motionbgs.json"
      )
      machine.fail("test -e " + motion_download + ".part")
      machine.fail("test -e " + motion_download + ".motionbgs.json.part")
      noctalia_msg("plugin ${serviceId} all vm-motion-clear")
      wait_motion(action="clear", items=0, selected="")

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

      # All detected integrations start allowed. Each setting can then hard
      # force-off Wall-in-One's panel, IPC, status-adapter, and W Engine
      # capture routes without disabling or stopping the provider plugins.
      before_wallhaven_open = machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN")
      before_w_engine_next = machine.succeed(journal).count("W_ENGINE_VM_SERVICE next")
      before_w_engine_capture = machine.succeed(journal).count("W_ENGINE_VM_SERVICE capture-v1")
      before_mpvpaper_pause = machine.succeed(journal).count("MPVPAPER_VM_SERVICE pause")

      set_integration("w_engine", False)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=False,
          w_enabled=True,
          w_command=True,
          w_available=False,
          adapter_capture=False,
          adapter_status=False,
          current="",
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )
      noctalia_msg("plugin ${serviceId} all w-engine-next")
      noctalia_msg("plugin ${serviceId} all capture")
      noctalia_msg("plugin tadomika_ari/w-engine:start all announce")
      machine.sleep(1)
      assert machine.succeed(journal).count("W_ENGINE_VM_SERVICE next") == before_w_engine_next
      assert machine.succeed(journal).count("W_ENGINE_VM_SERVICE capture-v1") == before_w_engine_capture
      set_integration("w_engine", True)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )

      set_integration("wallhaven", False)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=False,
          wallhaven=False,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )
      noctalia_msg("plugin ${serviceId} all open-provider wallhaven")
      machine.sleep(1)
      assert machine.succeed(journal).count("WALLHAVEN_VM_PANEL_OPEN") == before_wallhaven_open
      set_integration("wallhaven", True)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )

      set_integration("mpvpaper", False)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=False,
          mpvpaper=False,
          mpv_command=True,
          extra_allowed=True,
      )
      noctalia_msg("plugin ${serviceId} all mpvpaper-pause")
      machine.sleep(1)
      assert machine.succeed(journal).count("MPVPAPER_VM_SERVICE pause") == before_mpvpaper_pause
      set_integration("mpvpaper", True)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )

      set_integration("extra_provider", False)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=False,
      )
      set_integration("extra_provider", True)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
      )

      # All four gates can also be disabled together while public Noctalia
      # wallpaper inspection remains available.
      set_integrations(False)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=False,
          wallhaven=False,
          w_allowed=False,
          w_enabled=True,
          w_command=True,
          w_available=False,
          adapter_capture=False,
          adapter_status=False,
          current="",
          mpv_allowed=False,
          mpvpaper=False,
          mpv_command=True,
          extra_allowed=False,
      )
      noctalia_msg("plugin tadomika_ari/w-engine:start all announce")
      machine.sleep(1)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=False,
          wallhaven=False,
          w_allowed=False,
          w_enabled=True,
          w_command=True,
          w_available=False,
          adapter_capture=False,
          adapter_status=False,
          current="",
          mpv_allowed=False,
          mpvpaper=False,
          mpv_command=True,
          extra_allowed=False,
      )

      # Reading Noctalia's public wallpaper-get path remains independent of
      # every live-provider integration. The copy is an export only and does
      # not re-pair or mutate the current wallpaper.
      noctalia_msg("plugin ${serviceId} all capture-backing")
      machine.wait_until_succeeds(
          "find ${captureRoot} -maxdepth 1 -type f "
          "-name 'wall-in-one-backing-*-HEADLESS-1.png' -size +0c | grep -q ."
      )
      backing_still = machine.succeed(
          "find ${captureRoot} -maxdepth 1 -type f "
          "-name 'wall-in-one-backing-*-HEADLESS-1.png' -print -quit"
      ).strip()
      machine.succeed(
          "${lib.getExe pkgs.ffmpeg} -v error -i "
          + shlex.quote(backing_still)
          + " -f null -"
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --arg path "
          + shlex.quote(backing_still)
          + " '.last_capture.provider == \"noctalia\" "
          + "and .last_capture.method == \"noctalia-current-backing\" "
          + "and .last_capture.dynamic_id == \"backing:${fixtureStill}\" "
          + "and .last_capture.path == $path' "
          + "${pluginDataRoot}/runtime.json"
      )
      machine.wait_until_succeeds(
          "grep -F $'\\tmsg\\twallpaper-get\\tHEADLESS-1' "
          "/tmp/wall-in-one-vm-noctalia-calls.log"
      )

      set_integrations(True)
      wait_provider(
          probe_ok=True,
          wallhaven_allowed=True,
          wallhaven=True,
          w_allowed=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          mpv_allowed=True,
          mpvpaper=True,
          mpv_command=True,
          extra_allowed=True,
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

      # The staged VM config opts into an absolute export directory from boot.
      # The private pluginDataDir()/captures default is pinned by the
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
      previous_capture = machine.succeed(
          "${lib.getExe pkgs.jq} -r '.last_capture.path // \"\"' "
          "${pluginDataRoot}/runtime.json"
      ).strip()
      noctalia_msg("plugin ${serviceId} all capture-video-pair")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --arg previous "
          + shlex.quote(previous_capture)
          + " '.last_capture.provider == \"video\" "
          + "and .last_capture.path != $previous "
          + "and (.last_capture.path | length) > 0' "
          + "${pluginDataRoot}/runtime.json"
      )
      video_still = machine.succeed(
          "${lib.getExe pkgs.jq} -r '.last_capture.path' "
          "${pluginDataRoot}/runtime.json"
      ).strip()
      assert video_still.startswith("${captureRoot}/wall-in-one-video-")
      assert video_still.endswith("-HEADLESS-1.png")
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
          + " '.schema_version == 3 "
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
          + " '.schema_version == 3 "
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

      # Animated manual selections are decoded into a durable PNG rather than
      # persisting a transient validation staging path or the animated source.
      set_manual_pair("${fixtureGif}")
      machine.wait_until_succeeds(
          noctalia_command("plugin ${serviceId} all pair-manual")
          + " >/dev/null && ${lib.getExe pkgs.jq} -e "
          + shlex.quote(
              '.pairs["HEADLESS-1"].provider == "manual" '
              'and .pairs["HEADLESS-1"].dynamic_id == "manual:${fixtureGif}" '
              'and .pairs["HEADLESS-1"].still_path != "${fixtureGif}" '
              'and (.pairs["HEADLESS-1"].still_path | endswith(".png"))'
          )
          + " ${pluginDataRoot}/runtime.json"
      )
      gif_still = machine.succeed(
          "${lib.getExe pkgs.jq} -r '.pairs[\"HEADLESS-1\"].still_path' "
          "${pluginDataRoot}/runtime.json"
      ).strip()
      assert gif_still.startswith("${captureRoot}/wall-in-one-manual-"), gif_still
      assert gif_still.endswith("-HEADLESS-1.png"), gif_still
      machine.succeed(
          "${lib.getExe pkgs.ffmpeg} -v error -i "
          + shlex.quote(gif_still)
          + " -f null -"
      )
      service_reload_marker = "hot reload: reloaded service '${serviceId}'"
      gif_reloads_before = machine.succeed(journal).count(service_reload_marker)
      machine.succeed(
          "printf '\\n-- VM GIF persistence reload probe\\n' >> ${materializedRoot}/service.luau"
      )
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- {shlex.quote(service_reload_marker)}) "
          f"-gt {gif_reloads_before}"
      )
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- "
          + shlex.quote(gif_still)
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e --arg path "
          + shlex.quote(gif_still)
          + " '.pairs[\"HEADLESS-1\"].still_path == $path' "
          + "${pluginDataRoot}/runtime.json"
      )
      set_manual_pair("${fixtureStill}")

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

      persistence_reloads_before = machine.succeed(journal).count(service_reload_marker)
      machine.succeed("printf '\\n-- VM persistence reload probe\\n' >> ${materializedRoot}/service.luau")
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- {shlex.quote(service_reload_marker)}) "
          f"-gt {persistence_reloads_before}"
      )
      wait_provider(
          probe_ok=True,
          wallhaven=True,
          w_enabled=True,
          w_command=True,
          w_available=True,
          left="native_previous",
          right="native_random",
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 2 and (.reels[\"HEADLESS-1\"].entries | length) == 3' "
          "${pluginDataRoot}/config.json"
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 3 and .cycles[\"HEADLESS-1\"].running == false "
          "and (.cycles[\"HEADLESS-1\"].history | type) == \"array\" "
          "and (.pair_registry[\"video:${fixtureVideo}\"].still_path | type) == \"string\" "
          "and (.pair_registry[\"431960001\"].still_path | type) == \"string\"' "
          "${pluginDataRoot}/runtime.json"
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
      service_start_marker = "started service '${serviceId}'"
      service_starts_before = machine.succeed(journal).count(service_start_marker)
      assert noctalia_msg("plugins enable ${pluginId}").strip().startswith("ok")
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- {shlex.quote(service_start_marker)}) "
          f"-gt {service_starts_before}"
      )
      machine.sleep(1)
      assert machine.succeed("cat ${pluginDataRoot}/config.json").strip() == "{broken-json"
      noctalia_msg("plugin ${serviceId} all next")
      machine.sleep(1)
      after_native = len([
          call for call in fixture_calls()
          if len(call) >= 2 and call[:2] == ["msg", "wallpaper-next"]
      ])
      assert after_native == before_native

      # Ownership boundaries are enforced statically and dynamically. The
      # coordinator/capture helper never signal processes; only the dedicated
      # supervisor may signal its exact child-PID map.
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
              "grep -F -- "
              + shlex.quote(forbidden)
              + " ${materializedRoot}/service.luau ${materializedRoot}/scripts/capture-still"
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
          "grep -E "
          "'(^|[^[:alnum:]_])(kill|killall|pkill)([^[:alnum:]_]|$)' "
          "${materializedRoot}/service.luau ${materializedRoot}/scripts/capture-still"
      )
      machine.succeed(
          "grep -F 'declare -A child_pid=()' ${materializedRoot}/scripts/renderer-supervisor"
      )
      machine.succeed(
          "grep -F 'kill -TERM \"$pid\"' ${materializedRoot}/scripts/renderer-supervisor"
      )
      machine.fail(
          "grep -v '^[[:space:]]*#' ${materializedRoot}/scripts/renderer-supervisor "
          "| grep -E 'pgrep|pkill|killall|setsid|systemd-run'"
      )
      machine.succeed("test -s /tmp/wall-in-one-vm-engine-invocations.log")
      machine.succeed("test -s /tmp/wall-in-one-vm-mpvpaper-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpv-invocations.log")
      machine.succeed(
          "for log in /tmp/wall-in-one-vm-engine-invocations.log "
          "/tmp/wall-in-one-vm-mpvpaper-invocations.log; do "
          "while read -r pid; do ! kill -0 \"$pid\" 2>/dev/null; done < \"$log\"; done"
      )
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
      machine.wait_until_fails(
          "find ${runtimeRoot}/noctalia-wall-in-one -maxdepth 1 -type p "
          "-name 'renderer-*.fifo' | grep -q ."
      )
      machine.succeed(
          "for log in /tmp/wall-in-one-vm-engine-invocations.log "
          "/tmp/wall-in-one-vm-mpvpaper-invocations.log; do "
          "while read -r pid; do ! kill -0 \"$pid\" 2>/dev/null; done < \"$log\"; done"
      )
      machine.succeed("systemctl is-active --quiet wall-in-one-renderer-sentinel.service")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid
      machine.succeed("systemctl stop noctalia-wall-in-one-vm-session.service")
      machine.wait_until_fails("pgrep -x noctalia")
    '';
  }
)
