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
  palettesServiceId = "${pluginId}:palettes";
  wallhavenServiceId = "${pluginId}:wallhaven";
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

      if [[ "$#" -eq 7 \
        && "$1" == "theme" \
        && "$2" == "${fixtureStill}" \
        && "$3" == "--scheme" \
        && "$4" == "m3-rainbow" \
        && "$5" == "--both" \
        && "$6" == "-o" ]]; then
        case "$7" in
          ${pluginDataRoot}/palette-preview/preview-*.json) ;;
          *) printf 'unexpected adaptive-preview output path\n' >&2; exit 65 ;;
        esac
        printf '%s\n' \
          '{"dark":{"surface":"#101820","primary":"#11AA22","secondary":"#22BB33","tertiary":"#33CC44","error":"#DD3344"},"light":{"surface":"#F4F5F6","primary":"#2255AA","secondary":"#3366BB","tertiary":"#4477CC","error":"#CC2233"}}' \
          > "$7"
        exit 0
      fi

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

      if [[ "$#" -ge 2 && "$1" == "msg" ]]; then
        case "$2" in
          color-scheme-*|theme-mode-*|wallpaper-set)
            exec ${lib.getExe noctaliaPackage} "$@"
            ;;
        esac
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
          '{"schema":1,"plugin":"goober/wall-in-one","provider":"MotionBGS","path":"%s","title":"Night City","source_page":"https://motionbgs.com/night-city","download_url":"%s","quality":"%s","bytes":%s}\n' \
          "$destination" "$effective" "$quality" "$bytes" \
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
      if [[ ''${1:-} == --help ]]; then
        printf '%s\n' 'linux-wallpaperengine VM fixture: --layer --screenshot --screen-root --bg'
        exit 0
      fi
      pid=$$
      {
        printf '%s\0' "$pid"
        printf '%s\0' "$@"
      } > "/tmp/wall-in-one-vm-engine-$pid.args"

      screenshot=""
      previous=""
      for argument in "$@"; do
        if [[ $previous == --screenshot ]]; then
          screenshot=$argument
          break
        fi
        previous=$argument
      done

      if [[ -n $screenshot ]]; then
        printf '%s\n' "$pid" > /tmp/wall-in-one-vm-engine-capture-current.pid
        printf '%s\n' "$pid" >> /tmp/wall-in-one-vm-engine-capture-invocations.log
        mode=$(cat /tmp/wall-in-one-vm-engine-capture-mode 2>/dev/null || printf success)
        if [[ $mode == block ]]; then
          printf partial > "$screenshot"
        else
          # Match upstream's asynchronous write closely enough that the VM can
          # prove no live renderer starts before validation and promotion.
          sleep 1
          cp ${fixtureWorkshopStill} "$screenshot"
        fi
      else
        printf '%s\n' "$pid" > /tmp/wall-in-one-vm-engine-current.pid
        printf '%s\n' "$pid" >> /tmp/wall-in-one-vm-engine-invocations.log
      fi
      trap 'exit 0' TERM INT HUP
      while :; do sleep 1; done
    '';
  };

  fakeMpvpaper = pkgs.writeShellApplication {
    name = "mpvpaper";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [[ ''${1:-} == --help ]]; then
        printf '%s\n' 'mpvpaper VM fixture: --layer --auto-pause --auto-mode'
        exit 0
      fi
      pid=$$
      printf '%s\n' "$pid" > /tmp/wall-in-one-vm-mpvpaper-current.pid
      {
        printf '%s\0' "$pid"
        printf '%s\0' "$@"
      } > "/tmp/wall-in-one-vm-mpvpaper-$pid.args"
      printf '%s\n' "$pid" >> /tmp/wall-in-one-vm-mpvpaper-invocations.log
      trap 'exit 0' TERM INT HUP
      mode=hold
      if [[ -r /tmp/wall-in-one-vm-mpvpaper-mode ]]; then
        IFS= read -r mode < /tmp/wall-in-one-vm-mpvpaper-mode || true
      fi
      if [[ $mode == delayed-exit ]]; then
        sleep 2
        exit 42
      fi
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
    local vmPlaylistId = ""
    local vmPairingPlaylistId = ""
    local vmScheduleMonth = 1
    local vmPreviousAck = noctalia.state.get(COMMAND_ACK_KEY)
    if type(vmPreviousAck) == "table" then
        vmCommandSequence = math.max(vmCommandSequence, tonumber(vmPreviousAck.sequence) or 0)
    end

    local function vmHandle(request)
        vmCommandSequence += 1
        request.sequence = vmCommandSequence
        wallInOne.handleCommand(request)
    end

    function onIpc(event, payload)
        if event == "vm-probe" then
            local vmOwned = type(rendererStatus) == "table"
                    and type(rendererStatus.outputs) == "table"
                    and rendererStatus.outputs["HEADLESS-1"]
                or nil
            local vmRendererCommand = noctalia.state.get(RENDERER_COMMAND_KEY)
            local vmRendererBusStatus = noctalia.state.get(RENDERER_STATUS_KEY)
            local vmRendererPending = 0
            for _ in pairs(rendererPending) do
                vmRendererPending += 1
            end
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
                    .. " internal_current="
                    .. tostring(providers.w_engine.internal_current["HEADLESS-1"] or "")
                    .. " persisted_workshop="
                    .. tostring(runtime.current_workshops["HEADLESS-1"] or "")
                    .. " renderer_workshop="
                    .. tostring(type(vmOwned) == "table" and vmOwned.workshop_id or "")
                    .. " renderer_layer="
                    .. tostring(type(vmOwned) == "table" and vmOwned.layer or "")
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
                        type(vmOwned) == "table"
                    )
                    .. " renderer_event="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.last_event or "")
                    .. " renderer_event_nonce="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.last_event_nonce or "")
                    .. " renderer_last_nonce="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.last_nonce or "")
                    .. " renderer_pending="
                    .. tostring(vmRendererPending)
                    .. " renderer_queue_depth="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.queue_depth or "")
                    .. " renderer_write_in_flight="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.write_in_flight or false)
                    .. " renderer_write_nonce="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.write_nonce or "")
                    .. " renderer_command="
                    .. tostring(type(vmRendererCommand) == "table" and vmRendererCommand.action or "")
                    .. " renderer_command_nonce="
                    .. tostring(type(vmRendererCommand) == "table" and vmRendererCommand.nonce or "")
                    .. " renderer_error="
                    .. tostring(type(rendererStatus) == "table" and rendererStatus.last_error or "")
                    .. " renderer_bus_instance="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.instance_id or "")
                    .. " renderer_bus_revision="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.status_revision or "")
                    .. " renderer_bus_event="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.last_event or "")
                    .. " renderer_bus_event_nonce="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.last_event_nonce or "")
                    .. " renderer_bus_last_nonce="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.last_nonce or "")
                    .. " renderer_bus_queue_depth="
                    .. tostring(type(vmRendererBusStatus) == "table" and vmRendererBusStatus.queue_depth or "")
                    .. " renderer_bus_write_in_flight="
                    .. tostring(
                        type(vmRendererBusStatus) == "table" and vmRendererBusStatus.write_in_flight or false
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
        elseif event == "vm-standalone-command" then
            local paletteStatus = noctalia.state.get(PALETTES_STATUS_KEY)
            local paletteCommand = noctalia.state.get(PALETTES_COMMAND_KEY)
            local paletteNonce = math.max(
                tonumber(type(paletteStatus) == "table" and paletteStatus.last_nonce) or 0,
                tonumber(type(paletteCommand) == "table" and paletteCommand.nonce) or 0
            ) + 1
            noctalia.state.set(PALETTES_COMMAND_KEY, {
                schema = 0,
                nonce = paletteNonce,
                action = "refresh",
            })

            local wallhavenStatus = noctalia.state.get(WALLHAVEN_STATUS_KEY)
            local wallhavenCommand = noctalia.state.get(WALLHAVEN_COMMAND_KEY)
            local wallhavenNonce = math.max(
                tonumber(type(wallhavenStatus) == "table" and wallhavenStatus.last_nonce) or 0,
                tonumber(type(wallhavenCommand) == "table" and wallhavenCommand.nonce) or 0
            ) + 1
            noctalia.state.set(WALLHAVEN_COMMAND_KEY, {
                schema = 1,
                nonce = wallhavenNonce,
                action = "clear",
            })
        elseif event == "vm-standalone-probe" then
            local coordinatorStatus = wallInOne.statusSnapshot()
            local configState = noctalia.state.get(CONFIG_STATE_KEY)
            local runtimeState = noctalia.state.get(RUNTIME_STATE_KEY)
            local libraryState = noctalia.state.get(LIBRARY_STATE_KEY)
            local domainConfig = type(configState) == "table" and type(configState.config) == "table"
                    and configState.config
                or {}
            local domainRuntime = type(runtimeState) == "table" and type(runtimeState.runtime) == "table"
                    and runtimeState.runtime
                or {}
            local paletteStatus = noctalia.state.get(PALETTES_STATUS_KEY)
            local wallhavenStatus = noctalia.state.get(WALLHAVEN_STATUS_KEY)
            local wallhavenResults = noctalia.state.get(WALLHAVEN_RESULTS_KEY)
            noctalia.log(
                "WALL_IN_ONE_VM_STANDALONE "
                    .. tostring(payload or "")
                    .. " coordinator_protocol=" .. tostring(coordinatorStatus.protocol or 0)
                    .. " config_domain_protocol=" .. tostring(type(configState) == "table" and configState.protocol or 0)
                    .. " config_domain_revision=" .. tostring(type(configState) == "table" and configState.revision or 0)
                    .. " config_domain_revisioned=" .. tostring(
                        type(configState) == "table" and (tonumber(configState.revision) or 0) >= 1
                    )
                    .. " config_schema=" .. tostring(domainConfig.schema_version or 0)
                    .. " runtime_domain_protocol=" .. tostring(type(runtimeState) == "table" and runtimeState.protocol or 0)
                    .. " runtime_domain_revision=" .. tostring(type(runtimeState) == "table" and runtimeState.revision or 0)
                    .. " runtime_domain_revisioned=" .. tostring(
                        type(runtimeState) == "table" and (tonumber(runtimeState.revision) or 0) >= 1
                    )
                    .. " runtime_schema=" .. tostring(type(runtimeState) == "table" and runtimeState.schema_version or 0)
                    .. " library_domain_protocol=" .. tostring(type(libraryState) == "table" and libraryState.protocol or 0)
                    .. " library_domain_revision=" .. tostring(type(libraryState) == "table" and libraryState.revision or 0)
                    .. " library_domain_revisioned=" .. tostring(
                        type(libraryState) == "table" and (tonumber(libraryState.revision) or 0) >= 1
                    )
                    .. " lightweight_playlists=" .. tostring(
                        type(coordinatorStatus.config) == "table" and coordinatorStatus.config.playlists ~= nil
                    )
                    .. " embedded_renderer=" .. tostring(coordinatorStatus.renderer ~= nil)
                    .. " embedded_provider_catalogs=" .. tostring(
                        coordinatorStatus.motionbgs ~= nil
                            or coordinatorStatus.palettes ~= nil
                            or coordinatorStatus.wallhaven ~= nil
                    )
                    .. " retired_reels=" .. tostring(
                        domainConfig.reels ~= nil
                    )
                    .. " retired_cycles=" .. tostring(domainRuntime.cycles ~= nil)
                    .. " public_pair_registry=" .. tostring(domainRuntime.pair_registry ~= nil)
                    .. " palettes_protocol=" .. tostring(type(paletteStatus) == "table" and paletteStatus.protocol or 0)
                    .. " palettes_ready=" .. tostring(type(paletteStatus) == "table" and paletteStatus.ready == true)
                    .. " palettes_nonce=" .. tostring(type(paletteStatus) == "table" and paletteStatus.last_nonce or 0)
                    .. " palettes_degraded=" .. tostring(
                        type(paletteStatus) == "table" and paletteStatus.degraded == true
                    )
                    .. " palette_builtin=" .. tostring(
                        type(paletteStatus) == "table"
                            and type(paletteStatus.counts) == "table"
                            and paletteStatus.counts.builtin
                            or 0
                    )
                    .. " wallhaven_schema=" .. tostring(
                        type(wallhavenStatus) == "table" and wallhavenStatus.schema or 0
                    )
                    .. " wallhaven_ready=" .. tostring(
                        type(wallhavenStatus) == "table" and wallhavenStatus.ready == true
                    )
                    .. " wallhaven_action=" .. tostring(
                        type(wallhavenStatus) == "table" and wallhavenStatus.last_action or ""
                    )
                    .. " wallhaven_completed=" .. tostring(
                        type(wallhavenStatus) == "table" and wallhavenStatus.last_completed_nonce or 0
                    )
                    .. " wallhaven_results_schema=" .. tostring(
                        type(wallhavenResults) == "table" and wallhavenResults.schema or 0
                    )
                    .. " wallhaven_results_kind=" .. tostring(
                        type(wallhavenResults) == "table" and wallhavenResults.kind or ""
                    )
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
        elseif event == "vm-renderer-stop" then
            wallInOne.queueRendererStop("HEADLESS-1")
        elseif event == "vm-cycle-create" then
            local playlistId = wallInOne.createPlaylist("VM mixed playlist", "HEADLESS-1", false)
            if playlistId == nil then
                return
            end
            vmPlaylistId = playlistId
        elseif event == "vm-cycle-add-static" then
            vmHandle({
                kind = "playlist_add_entry",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
                entry = { kind = "static", source = "${fixtureStill}", label = "VM still" },
            })
        elseif event == "vm-cycle-add-video" then
            vmHandle({
                kind = "playlist_add_entry",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
                entry = {
                    kind = "video",
                    source = "${fixtureVideo}",
                    still_path = "${fixtureVideoStill}",
                    label = "VM video",
                },
            })
        elseif event == "vm-cycle-add-workshop" then
            vmHandle({
                kind = "playlist_add_entry",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
                entry = {
                    kind = "workshop",
                    source = "431960001",
                    still_path = "${fixtureWorkshopStill}",
                    label = "VM Workshop",
                },
            })
        elseif event == "vm-cycle-options" then
            vmHandle({
                kind = "playlist_options",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
                interval_seconds = 60,
                order = "rotate",
            })
        elseif event == "vm-cycle-assign" then
            vmHandle({
                kind = "playlist_assign",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
            })
        elseif event == "vm-cycle-schedule-upper" then
            local currentMonth = math.max(1, math.min(12, tonumber(noctalia.formatTime("%m")) or 1))
            vmScheduleMonth = (currentMonth % 12) + 1
            vmHandle({
                kind = "schedule_save",
                output = "HEADLESS-1",
                schedule = {
                    id = "vm-schedule-upper",
                    name = "VM overnight upper",
                    playlist = vmPlaylistId,
                    enabled = true,
                    weekdays = { 0, 1, 2, 3, 4, 5, 6 },
                    months = { vmScheduleMonth },
                    start_minute = 1080,
                    end_minute = 360,
                    all_day = false,
                },
            })
        elseif event == "vm-cycle-schedule-lower" then
            vmHandle({
                kind = "schedule_save",
                output = "HEADLESS-1",
                schedule = {
                    id = "vm-schedule-lower",
                    name = "VM overnight lower",
                    playlist = vmPlaylistId,
                    enabled = true,
                    weekdays = { 0, 1, 2, 3, 4, 5, 6 },
                    months = { vmScheduleMonth },
                    start_minute = 1080,
                    end_minute = 360,
                    all_day = false,
                },
            })
        elseif event == "vm-schedule-probe" then
            local outputConfig = config.outputs["HEADLESS-1"] or { schedules = {} }
            local winner = wallInOne.winningScheduleAt(outputConfig, 2, vmScheduleMonth, 15, 1200)
            local missMonth = (vmScheduleMonth % 12) + 1
            local missed = wallInOne.winningScheduleAt(outputConfig, 2, missMonth, 15, 1200)
            noctalia.log(
                "WALL_IN_ONE_VM_SCHEDULE "
                    .. tostring(payload or "")
                    .. " month=" .. tostring(vmScheduleMonth)
                    .. " winner=" .. tostring(type(winner) == "table" and winner.id or "")
                    .. " miss=" .. tostring(missed == nil)
            )
        elseif event == "vm-output-options-override" then
            vmHandle({
                kind = "output_options",
                output = "HEADLESS-1",
                interval_seconds = 120,
                order = "shuffle",
                inherit = false,
            })
        elseif event == "vm-output-options-inherit" then
            vmHandle({ kind = "output_options", output = "HEADLESS-1", inherit = true })
        elseif event == "vm-pairing-create" then
            if vmPairingPlaylistId == "" then
                vmPairingPlaylistId = wallInOne.createPlaylist(
                    "VM pairing commands",
                    "HEADLESS-1",
                    false
                ) or ""
            end
        elseif event == "vm-pairing-save-adaptive" then
            vmHandle({
                kind = "pairing_save",
                pairing = {
                    id = "vm-pairing-adaptive",
                    label = "VM adaptive still",
                    media = nil,
                    still = { mode = "selected", path = "${fixtureStill}" },
                    theme = { mode = "dark", source = "wallpaper", selection = "m3-rainbow" },
                    added_at = "2026-08-02 00:00:00",
                },
            })
        elseif event == "vm-pairing-save-video" then
            vmHandle({
                kind = "pairing_save",
                pairing = {
                    id = "vm-pairing-video",
                    label = "VM catalog video",
                    media = { kind = "video", source = "${fixtureVideo}" },
                    still = { mode = "selected", path = "${fixtureVideoStill}" },
                    theme = { mode = "light", source = "builtin", selection = "Nord" },
                    added_at = "2026-08-02 00:01:00",
                },
            })
        elseif event == "vm-pairing-add-adaptive" then
            vmHandle({
                kind = "playlist_add_pairing",
                output = "HEADLESS-1",
                playlist_id = vmPairingPlaylistId,
                pairing_id = "vm-pairing-adaptive",
                before_id = "",
            })
        elseif event == "vm-pairing-add-video" then
            vmHandle({
                kind = "playlist_add_pairing",
                output = "HEADLESS-1",
                playlist_id = vmPairingPlaylistId,
                pairing_id = "vm-pairing-video",
                before_id = "",
            })
        elseif event == "vm-pairing-save-update" then
            vmHandle({
                kind = "pairing_save",
                pairing = {
                    id = "vm-pairing-adaptive",
                    label = "VM adaptive still updated",
                    media = nil,
                    still = { mode = "selected", path = "${fixtureStill}" },
                    theme = { mode = "light", source = "wallpaper", selection = "m3-rainbow" },
                    added_at = "2026-08-02 00:00:00",
                },
            })
        elseif event == "vm-pairing-place" then
            local playlist = config.playlists[vmPairingPlaylistId]
            local adaptiveId = ""
            local videoId = ""
            for _, entry in ipairs(type(playlist) == "table" and playlist.entries or {}) do
                if entry.pairing_id == "vm-pairing-adaptive" then
                    adaptiveId = entry.id
                elseif entry.pairing_id == "vm-pairing-video" then
                    videoId = entry.id
                end
            end
            vmHandle({
                kind = "playlist_place_entry",
                playlist_id = vmPairingPlaylistId,
                entry_id = videoId,
                anchor_id = adaptiveId,
                placement = "before",
            })
        elseif event == "vm-pairing-delete" then
            vmHandle({ kind = "pairing_delete", pairing_id = "vm-pairing-adaptive" })
        elseif event == "vm-palette-preview" then
            vmHandle({
                kind = "palette_preview",
                key = "vm-adaptive-preview",
                pairing_id = "vm-pairing-adaptive",
            })
        elseif event == "vm-palette-preview-probe" then
            local paletteStatus = noctalia.state.get(PALETTES_STATUS_KEY)
            local preview = type(paletteStatus) == "table" and paletteStatus.preview or {}
            local colors = type(preview) == "table" and preview.preview or {}
            local dark = type(colors) == "table" and colors.dark or {}
            local light = type(colors) == "table" and colors.light or {}
            local darkAccents = type(dark) == "table" and dark.accents or {}
            local lightAccents = type(light) == "table" and light.accents or {}
            noctalia.log(
                "WALL_IN_ONE_VM_PALETTE_PREVIEW "
                    .. tostring(payload or "")
                    .. " state=" .. tostring(type(preview) == "table" and preview.state or "")
                    .. " key=" .. tostring(type(preview) == "table" and preview.key or "")
                    .. " path=" .. tostring(type(preview) == "table" and preview.path or "")
                    .. " scheme=" .. tostring(type(preview) == "table" and preview.scheme or "")
                    .. " dark_surface=" .. tostring(type(dark) == "table" and dark.surface or "")
                    .. " dark_primary=" .. tostring(type(darkAccents) == "table" and darkAccents[1] or "")
                    .. " light_surface=" .. tostring(type(light) == "table" and light.surface or "")
                    .. " light_primary=" .. tostring(type(lightAccents) == "table" and lightAccents[1] or "")
                    .. " error=" .. tostring(type(preview) == "table" and preview.error or "")
            )
        elseif event == "vm-renderer-backoff-probe" then
            local samples = {}
            for index, startedAt in ipairs({ 100, 110, 120, 130, 140, 150, 160 }) do
                local nonce = tostring(index)
                wallInOne.noteRendererStarted("VM-BACKOFF-A", nonce, startedAt)
                local exitedAt = startedAt + 1
                table.insert(
                    samples,
                    tostring(wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-A", nonce, exitedAt) - exitedAt)
                )
            end
            wallInOne.noteRendererStarted("VM-BACKOFF-B", "other", 200)
            local independent = wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-B", "other", 201) - 201
            wallInOne.noteRendererStarted("VM-BACKOFF-A", "stable", 1000)
            local stableReset = wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-A", "stable", 1060) - 1060
            wallInOne.noteRendererStarted("VM-BACKOFF-A", "quick", 1100)
            local afterStableQuick = wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-A", "quick", 1101) - 1101
            wallInOne.invalidateCycleIntent("VM-BACKOFF-A", false)
            wallInOne.noteRendererStarted("VM-BACKOFF-A", "intent", 1200)
            local intentReset = wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-A", "intent", 1201) - 1201
            wallInOne.noteRendererStarted("VM-BACKOFF-C", "first", 2000)
            wallInOne.noteUnexpectedRendererExit("VM-BACKOFF-C", "first", 2001)
            wallInOne.noteRendererStarted("VM-BACKOFF-C", "recovering", 2002)
            local retainedFloor = wallInOne.rendererRetryFloor("VM-BACKOFF-C") - 2002
            noctalia.log(
                "WALL_IN_ONE_VM_RENDERER_BACKOFF "
                    .. tostring(payload or "")
                    .. " delays=" .. table.concat(samples, ",")
                    .. " independent=" .. tostring(independent)
                    .. " stable_reset=" .. tostring(stableReset)
                    .. " after_stable_quick=" .. tostring(afterStableQuick)
                    .. " intent_reset=" .. tostring(intentReset)
                    .. " retained_floor=" .. tostring(retainedFloor)
            )
        elseif event == "vm-cycle-action" then
            local action = tostring(payload or "")
            if action == "resume-stale-renderer-state" then
                -- Reproduce the coordinator/renderer observation race: the
                -- exact child is signal-paused, while this service still sees
                -- the preceding running snapshot. Resume must remain an
                -- idempotent intent instead of being gated away.
                local owned = type(rendererStatus.outputs) == "table"
                        and rendererStatus.outputs["HEADLESS-1"]
                    or nil
                if type(owned) == "table" then
                    owned.state = "running"
                end
                action = "resume"
            end
            vmHandle({
                kind = "playlist_action",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
                action = action,
                manual_pin = true,
            })
        elseif event == "vm-cycle-probe" then
            local playlist, playlistId = wallInOne.playlistForOutput("HEADLESS-1", vmPlaylistId)
            local state = playlistId ~= nil and wallInOne.playlistRunState("HEADLESS-1", playlistId) or {}
            local cursor = type(playlist) == "table"
                    and wallInOne.entryIndexById(playlist, tostring(state.current_entry or ""))
                or nil
            local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs["HEADLESS-1"] or {}
            local cycleError = tostring(state.last_error or "")
            cycleError = string.sub(string.gsub(cycleError, "[%c%s]+", "-"), 1, 160)
            noctalia.log(
                "WALL_IN_ONE_VM_CYCLE "
                    .. tostring(payload or "")
                    .. " running=" .. tostring(state.running == true)
                    .. " paused=" .. tostring(state.paused == true)
                    .. " cursor=" .. tostring(tonumber(cursor) or 0)
                    .. " current_entry=" .. tostring(state.current_entry or "")
                    .. " history=" .. tostring(type(state.history) == "table" and #state.history or 0)
                    .. " applying=" .. tostring(cycleApplying["HEADLESS-1"] ~= nil)
                    .. " ok=" .. tostring(tostring(state.last_error or "") == "")
                    .. " error=" .. cycleError
                    .. " backend=" .. tostring((type(owned) == "table" and owned.backend) or "none")
            )
        elseif event == "vm-action-probe" then
            local actionError = tostring(lastActionError or "")
            actionError = string.sub(string.gsub(actionError, "[%c%s]+", "-"), 1, 200)
            local rendererError = tostring(rendererStatus.last_error or "")
            rendererError = string.sub(string.gsub(rendererError, "[%c%s]+", "-"), 1, 200)
            noctalia.log(
                "WALL_IN_ONE_VM_ACTION "
                    .. tostring(payload or "")
                    .. " action_error=" .. actionError
                    .. " renderer_event=" .. tostring(rendererStatus.last_event or "")
                    .. " renderer_error=" .. rendererError
                    .. " renderer_pending=" .. tostring(wallInOne.rendererPendingCount())
                    .. " internal_capture=" .. tostring(
                        type(pendingInternalCaptures["HEADLESS-1"]) == "table"
                    )
                    .. " capture_active=" .. tostring(type(captureInFlight["HEADLESS-1"]) == "table")
            )
        elseif event == "vm-library-refresh" then
            wallInOne.refreshLibrary()
            local completed = wallInOne.stepLibraryScan()
            local scan = type(libraryScan) == "table" and libraryScan or {}
            noctalia.log(
                "WALL_IN_ONE_VM_LIBRARY_REFRESH "
                    .. tostring(payload or "")
                    .. " completed=" .. tostring(completed == true)
                    .. " scanning=" .. tostring(library.scanning == true)
                    .. " queued_media=" .. tostring(type(scan.media_entries) == "table" and #scan.media_entries or 0)
                    .. " consumed_media=" .. tostring(math.max(0, (tonumber(scan.media_index) or 1) - 1))
                    .. " accepted_media=" .. tostring(
                        (type(scan.stills) == "table" and #scan.stills or 0)
                            + (type(scan.videos) == "table" and #scan.videos or 0)
                    )
                    .. " phase=" .. tostring(scan.phase or "")
            )
        elseif event == "vm-library-probe" then
            local motionManaged = false
            local motionDeletable = false
            local userManaged = false
            local userDeletable = false
            local motionProvider = ""
            local userProvider = ""
            for _, entry in ipairs(type(library.videos) == "table" and library.videos or {}) do
                if type(entry) == "table" and entry.path == "${videoRoot}/night-city.hd.mp4" then
                    motionManaged = entry.managed == true
                    motionDeletable = entry.deletable == true
                    motionProvider = tostring(entry.provider or "")
                elseif type(entry) == "table" and entry.path == "${videoRoot}/library-1.mp4" then
                    userManaged = entry.managed == true
                    userDeletable = entry.deletable == true
                    userProvider = tostring(entry.provider or "")
                end
            end
            noctalia.log(
                "WALL_IN_ONE_VM_LIBRARY "
                    .. tostring(payload or "")
                    .. " scanning=" .. tostring(library.scanning == true)
                    .. " videos=" .. tostring(type(library.videos) == "table" and #library.videos or 0)
                    .. " workshops=" .. tostring(type(library.workshops) == "table" and #library.workshops or 0)
                    .. " motion_managed=" .. tostring(motionManaged)
                    .. " motion_deletable=" .. tostring(motionDeletable)
                    .. " motion_provider=" .. motionProvider
                    .. " user_managed=" .. tostring(userManaged)
                    .. " user_deletable=" .. tostring(userDeletable)
                    .. " user_provider=" .. userProvider
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
        elseif event == "vm-delete-motion-download" then
            local itemId = ""
            for _, entry in ipairs(type(library.videos) == "table" and library.videos or {}) do
                if type(entry) == "table" and entry.path == "${videoRoot}/night-city.hd.mp4" then
                    itemId = tostring(entry.id or "")
                    break
                end
            end
            if itemId ~= "" then
                vmHandle({ kind = "library_delete", item_id = itemId })
            end
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

  # State is scoped by plugin ID, and teardown drops buffered log side effects.
  # This guest-only wrapper therefore verifies the production palette terminal
  # snapshot synchronously from inside the owning plugin runtime.
  vmPaletteExitProbe = pkgs.writeText "wall-in-one-vm-palette-exit-probe.luau" ''
    local vmProductionPaletteOnExit = onExit

    function onExit(signal, reason)
        vmProductionPaletteOnExit(signal, reason)
        local value = noctalia.state.get(STATUS_KEY)
        local preview = type(value) == "table" and value.preview or nil
        local shapeComplete = type(value) == "table"
            and type(value.cache) == "table"
            and type(value.counts) == "table"
            and type(value.palettes) == "table"
        local result = "protocol="
            .. tostring(type(value) == "table" and value.protocol or 0)
            .. " ready_false=" .. tostring(type(value) == "table" and value.ready == false)
            .. " refreshing_false=" .. tostring(type(value) == "table" and value.refreshing == false)
            .. " event_stopped=" .. tostring(type(value) == "table" and value.last_event == "stopped")
            .. " preview_idle=" .. tostring(type(preview) == "table" and preview.state == "idle")
            .. " shape_complete=" .. tostring(shapeComplete)
        noctalia.writeFile("${pluginDataRoot}/.vm-palette-exit", result .. "\n")
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
    internal_renderer_layer = "background"
    capture_directory = "${captureRoot}"
    video_directory = "${videoRoot}"
    motionbgs_download_directory = "${videoRoot}"
    motionbgs_quality = "hd"
    motionbgs_result_limit = 24
    motionbgs_cache_minutes = 30
    motionbgs_max_download_mb = 16
    auto_capture = true
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
      # same blobless Git cache layout Noctalia owns so v5.0.0's asynchronous
      # enable workers exercise catalog resolution and export without racing
      # each other during the first clone. The single-plugin VM tests cover
      # Noctalia's clone-on-enable path itself.
      install -d -m 0755 "${sourceStorageRoot}"
      git clone --filter=blob:none --no-checkout \
        "${sourceUrl}" "${clonedRepoRoot}"

      : > /tmp/wall-in-one-vm-noctalia-calls.log
      : > /tmp/wall-in-one-vm-engine-invocations.log
      : > /tmp/wall-in-one-vm-engine-capture-invocations.log
      : > /tmp/wall-in-one-vm-mpvpaper-invocations.log
      : > /tmp/wall-in-one-vm-mpv-invocations.log
      : > /tmp/wall-in-one-vm-motion-calls.log
      printf '%s\n' all > /tmp/wall-in-one-vm-provider-mode
      printf '%s\n' success > /tmp/wall-in-one-vm-engine-capture-mode
      printf '%s\n' hold > /tmp/wall-in-one-vm-mpvpaper-mode
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
          renderer_pending: int | None = None,
          renderer_queue_depth: int | None = None,
          renderer_write_in_flight: bool | None = None,
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
          if renderer_pending is not None:
              fragments.append(f"renderer_pending={renderer_pending}")
          if renderer_queue_depth is not None:
              fragments.append(f"renderer_queue_depth={renderer_queue_depth}")
          if renderer_write_in_flight is not None:
              fragments.append(
                  f"renderer_write_in_flight={str(renderer_write_in_flight).lower()}"
              )
          if extra_allowed is not None:
              fragments.append(f"extra_allowed={str(extra_allowed).lower()}")
          if left is not None:
              fragments.append(f"left={left}")
          if right is not None:
              fragments.append(f"right={right}")
          filters = journal
          for fragment in fragments:
              filters += f" | grep -F -- {shlex.quote(fragment)}"
          # Deliver the action once, then poll only the read-only diagnostic.
          # Replaying a provider probe on every retry can keep asynchronous
          # discovery permanently busy and obscures whether one command
          # converged. Bound failures and retain fixture diagnostics.
          noctalia_msg("plugin ${serviceId} all probe")
          try:
              machine.wait_until_succeeds(
                  noctalia_command(f"plugin ${serviceId} all vm-probe {token}")
                  + " >/dev/null && "
                  + filters,
                  timeout=60,
              )
          except Exception:
              print(
                  "provider wait failed; fixture mode="
                  + machine.succeed("cat /tmp/wall-in-one-vm-provider-mode")
                  + "\nrecent fake-noctalia calls:\n"
                  + machine.succeed("tail -n 40 /tmp/wall-in-one-vm-noctalia-calls.log")
              )
              raise

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
              "ok=true",
              f"backend={backend}",
          )
          filters = journal
          for fragment in fragments:
              filters += f" | grep -F -- {shlex.quote(fragment)}"
          try:
              machine.wait_until_succeeds(
                  noctalia_command(f"plugin ${serviceId} all vm-cycle-probe {token}")
                  + " >/dev/null && "
                  + filters,
                  timeout=60,
              )
          except Exception:
              # Capture both the coordinator's adopted snapshot and the live
              # shared renderer slot before teardown. This distinguishes a
              # child-launch failure from a missed command/status observation
              # without replaying the user action under test.
              diagnostic_token = f"{token}-failure"
              machine.execute(
                  noctalia_command(f"plugin ${serviceId} all vm-probe {diagnostic_token}")
                  + " >/dev/null"
              )
              machine.sleep(1)
              print(
                  "cycle wait failed; recent Noctalia journal:\n"
                  + machine.execute(
                      "journalctl -b --no-pager -u noctalia-test.service | tail -n 220"
                  )[1]
                  + "\nrenderer runtime files:\n"
                  + machine.execute(
                      "find /run/noctalia-wall-in-one-vm -maxdepth 3 -type f -print "
                      "-exec tail -n 80 {} \\;"
                  )[1]
                  + "\nrenderer fixture invocations:\n"
                  + machine.execute(
                      "find /tmp -maxdepth 1 -type f "
                      "-name 'wall-in-one-vm-*-invocations.log' -print "
                      "-exec tail -n 80 {} \\;"
                  )[1]
              )
              raise

      def drive_cycle(action: str, condition: str):
          # Noctalia v5 delivers plugin IPC reliably. Send each user action
          # once, then poll only its durable result; replaying an asynchronous
          # action here can continually restart it and hide the real outcome.
          noctalia_msg(f"plugin ${serviceId} all vm-cycle-action {action}")
          machine.wait_until_succeeds(
              condition,
              timeout=60,
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

      library_probe_number = [0]
      def wait_library(**expected):
          library_probe_number[0] += 1
          token = f"library-{library_probe_number[0]}"
          filters = journal + " | grep -F -- " + shlex.quote(
              f"WALL_IN_ONE_VM_LIBRARY {token}"
          )
          for key, value in expected.items():
              if isinstance(value, bool):
                  value = str(value).lower()
              filters += " | grep -F -- " + shlex.quote(f"{key}={value}")
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-library-probe {token}")
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
      # Keep one real schema-3 document in the VM path. Schema 4 must create a
      # reusable catalog record, link the legacy occurrence to it, expand the
      # omitted calendar months, and retire numeric schedule priority.
      legacy_config = json.dumps({
          "schema_version": 3,
          "gestures": {
              "left": "hub_open",
              "middle": "native_open",
              "right": "native_next",
          },
          "playlists": {
              "legacy-schema3-playlist": {
                  "name": "Legacy schema 3 fixture",
                  "order": "rotate",
                  "interval_seconds": 900,
                  "quick_choice": False,
                  "entries": [
                      {
                          "id": "legacy-schema3-entry",
                          "label": "Legacy still",
                          "media": None,
                          "still": {"mode": "selected", "path": "${fixtureStill}"},
                          "theme": {
                              "mode": "dark",
                              "source": "wallpaper",
                              "selection": "m3-rainbow",
                          },
                          "added_at": "2026-07-31 00:00:00",
                      }
                  ],
              }
          },
          "outputs": {
              "HEADLESS-1": {
                  "fallback_playlist": "legacy-schema3-playlist",
                  "quick_choice_playlist": "",
                  "schedules": [
                      {
                          "id": "legacy-schema3-schedule",
                          "name": "Legacy all-month schedule",
                          "playlist": "legacy-schema3-playlist",
                          "enabled": False,
                          "weekdays": [0, 1, 2, 3, 4, 5, 6],
                          "start_minute": 1080,
                          "end_minute": 360,
                          "all_day": False,
                          "priority": 42,
                      }
                  ],
              }
          },
      })
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
          + shlex.quote(legacy_config)
          + " > ${pluginDataRoot}/config.json; "
          "printf '%s\\n' "
          + shlex.quote(legacy_runtime)
          + " > ${pluginDataRoot}/runtime.json; "
          "chown ${testUser}:users ${pluginDataRoot}/config.json ${pluginDataRoot}/runtime.json"
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
      wait_log("started service '${palettesServiceId}'")
      wait_log("started service '${wallhavenServiceId}'")
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

      # Pin the exact v5.0.0 output grammar before feeding equivalent controlled
      # snapshots to the service subprocess fixture.
      real_plugin_list = noctalia_msg("plugins list")
      assert "noctalia/wallhaven [${sourceName}] 1.0.10 enabled" in real_plugin_list
      assert "tadomika_ari/w-engine [${sourceName}] 1.1.0 enabled" in real_plugin_list
      assert "noctalia/mpvpaper [${sourceName}] 1.0.7 enabled" in real_plugin_list
      assert "${pluginId} [${sourceName}] ${manifest.version} enabled" in real_plugin_list

      machine.succeed(
          "cat ${materializedRoot}/service.luau ${vmProbe} "
          "> ${materializedRoot}/service.luau.new && "
          "mv ${materializedRoot}/service.luau.new ${materializedRoot}/service.luau && "
          "cat ${materializedRoot}/palettes.luau ${vmPaletteExitProbe} "
          "> ${materializedRoot}/palettes.luau.new && "
          "mv ${materializedRoot}/palettes.luau.new ${materializedRoot}/palettes.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")
      wait_log("hot reload: reloaded service '${palettesServiceId}'")
      machine.succeed(
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/panel.luau && "
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/palettes.luau"
      )
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
          left="hub_open",
          right="native_next",
      )

      noctalia_msg("plugin ${serviceId} all vm-renderer-backoff-probe deterministic")
      wait_log(
          "WALL_IN_ONE_VM_RENDERER_BACKOFF deterministic "
          "delays=10,20,40,80,160,300,300 independent=10 "
          "stable_reset=10 after_stable_quick=20 intent_reset=10 retained_floor=9"
      )

      # The two standalone v1 services publish versioned snapshots. Exercise a
      # deterministic rejected palette command and Wallhaven clear without
      # depending on public network availability.
      noctalia_msg("plugin ${serviceId} all vm-standalone-command")
      standalone_token = "standalone-contract"
      standalone_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_STANDALONE {standalone_token}",
          "coordinator_protocol=4",
          "config_domain_protocol=1",
          "config_domain_revisioned=true",
          "config_schema=4",
          "runtime_domain_protocol=1",
          "runtime_domain_revisioned=true",
          "runtime_schema=6",
          "library_domain_protocol=1",
          "library_domain_revisioned=true",
          "lightweight_playlists=false",
          "embedded_renderer=false",
          "embedded_provider_catalogs=false",
          "retired_reels=false",
          "retired_cycles=false",
          "public_pair_registry=false",
          "palettes_protocol=1",
          "palettes_ready=true",
          "palettes_degraded=true",
          "palette_builtin=10",
          "wallhaven_schema=1",
          "wallhaven_ready=true",
          "wallhaven_action=clear",
          "wallhaven_results_schema=1",
          "wallhaven_results_kind=empty",
      ):
          standalone_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-standalone-probe {standalone_token}"
          )
          + " >/dev/null && "
          + standalone_filters
      )

      # Refresh performs only bounded candidate collection synchronously. One
      # explicit production scan step consumes exactly the four-item budget;
      # normal update ticks finish the remaining media and Workshop metadata.
      # Managed-directory markers and subdirectories may also be queued, so
      # accepted media is deliberately not asserted at this intermediate point.
      library_refresh_token = "bounded-library-refresh"
      noctalia_msg(
          f"plugin ${serviceId} all vm-library-refresh {library_refresh_token}"
      )
      for fragment in (
          f"WALL_IN_ONE_VM_LIBRARY_REFRESH {library_refresh_token}",
          "completed=false",
          "scanning=true",
          "consumed_media=4",
          "phase=media",
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

      # The explicit schema-3 fixture is upgraded to schema 4 without losing
      # its occurrence snapshot. Its omitted month filter becomes all months,
      # and the retired priority field does not cross the migration boundary.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 4 and .gestures.left == \"hub_open\" "
          "and .gestures.middle == \"native_open\" "
          "and .gestures.right == \"native_next\" "
          "and (.pairings | type) == \"object\" and (.pairings | length) == 1 "
          "and (.playlists[\"legacy-schema3-playlist\"].entries | length) == 1 "
          "and (.playlists[\"legacy-schema3-playlist\"].entries[0] as $entry "
          "| .pairings[$entry.pairing_id] as $pair "
          "| ($entry.pairing_id | type) == \"string\" "
          "and $pair.id == $entry.pairing_id "
          "and $pair.id != $entry.id "
          "and $pair.label == $entry.label "
          "and $pair.media == $entry.media "
          "and $pair.still == $entry.still "
          "and $pair.theme == $entry.theme "
          "and ($pair | has(\"pairing_id\")) == false) "
          "and (.outputs[\"HEADLESS-1\"].schedules[0].months "
          "== [1,2,3,4,5,6,7,8,9,10,11,12]) "
          "and (.outputs[\"HEADLESS-1\"].schedules[0] | has(\"priority\")) == false "
          "and has(\"reels\") == false' "
          "${pluginDataRoot}/config.json"
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 3 "
          "and .playlists[\"legacy-schema3-playlist\"].entries[0].id "
          "== \"legacy-schema3-entry\" "
          "and (.outputs[\"HEADLESS-1\"].schedules[0] | has(\"months\")) == false "
          "and .outputs[\"HEADLESS-1\"].schedules[0].priority == 42' "
          "${pluginDataRoot}/config.json.bak"
      )

      # Legacy runtime is migrated without losing pairs. Provider observations
      # are deliberately reconstructed rather than trusted from disk.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 6 "
          "and (.providers | type) == \"object\" "
          "and (.providers | has(\"legacy_fixture\")) == false "
          "and (.providers.wallhaven | type) == \"object\" "
          "and (.providers.w_engine | type) == \"object\" "
          "and (.providers.mpvpaper | type) == \"object\" "
          "and (.pair_registry | type) == \"object\" "
          "and (.runs | type) == \"object\" "
          "and (.output_states | type) == \"object\" "
          "and (.palette | type) == \"object\" "
          "and has(\"cycles\") == false "
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
          right="native_next",
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
          right="native_next",
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
      machine.succeed("test ! -s /tmp/wall-in-one-vm-engine-capture-invocations.log")
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
      assert mpv_args[1:6] == ["--layer", "background", "--auto-pause", "--auto-mode", "FULL"], mpv_args
      assert mpv_args[-2:] == ["HEADLESS-1", "${fixtureVideo}"], mpv_args
      mpv_options = mpv_args[mpv_args.index("-o") + 1]
      for token in (
          "loop-file=inf",
          "panscan=1.0",
          "terminal=no",
          "volume=100",
          "mute=yes",
          "hwdec=auto",
          "keep-open=yes",
      ):
          assert token in mpv_options, (token, mpv_options)

      # Native project capture is intentionally limited to an idle output or
      # the exact active Workshop. Stop the video fixture explicitly so this
      # section exercises linux-wallpaperengine's rendered-FBO path; applying a
      # different project over active playback uses non-destructive fallback.
      noctalia_msg("plugin ${serviceId} all vm-renderer-stop")
      machine.wait_until_fails(f"kill -0 {mpv_pid}")
      renderer_idle_token = "renderer-idle-before-native-capture"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-probe {renderer_idle_token}"
          )
          + " >/dev/null && "
          + journal
          + " | grep -F -- "
          + shlex.quote(f"WALL_IN_ONE_VM_PROBE {renderer_idle_token}")
          + " | grep -F -- 'renderer_owned=false'"
      )
      internal_engine_still = "${captureRoot}/Wall-in-One/Automatic Stills/wall-in-one-w-engine-431960001-HEADLESS-1.png"
      # The earlier external-adapter path deliberately proves pair creation and
      # cache reuse. Remove only that disposable VM-owned pair before this case
      # so native linux-wallpaperengine screenshot generation is deterministic.
      machine.succeed(
          "rm -f -- "
          + shlex.quote(internal_engine_still)
          + " "
          + shlex.quote(internal_engine_still + ".wall-in-one.json")
          + " /tmp/wall-in-one-vm-engine-capture-current.pid"
      )
      noctalia_msg("plugin ${serviceId} all vm-apply-workshop")
      try:
          machine.wait_until_succeeds(
              "test -s /tmp/wall-in-one-vm-engine-capture-current.pid",
              timeout=50,
          )
      except Exception as capture_error:
          capture_probe = "native-workshop-capture"
          noctalia_msg(f"plugin ${serviceId} all vm-action-probe {capture_probe}")
          capture_diagnostic = machine.succeed(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_ACTION {capture_probe}")
              + " | tail -n 1"
          ).strip()
          raise AssertionError(
              "native Workshop capture did not start: " + capture_diagnostic
          ) from capture_error
      capture_pid = machine.succeed(
          "cat /tmp/wall-in-one-vm-engine-capture-current.pid"
      ).strip()
      capture_args = machine.succeed(
          f"tr '\\0' '\\n' < /tmp/wall-in-one-vm-engine-{capture_pid}.args"
      ).splitlines()
      assert capture_args[1:18] == [
          "--screen-root", "HEADLESS-1", "--bg", "${fixtureWorkshop}/431960001",
          "--scaling", "fill", "--clamp", "border", "--fps", "60",
          "--layer", "background", "--volume", "15", "--noautomute",
          "--no-audio-processing", "--disable-particles",
      ], capture_args
      for flag in (
          "--disable-mouse",
          "--disable-parallax",
          "--fullscreen-pause-only-active",
      ):
          assert flag in capture_args, (flag, capture_args)
      screenshot_index = capture_args.index("--screenshot")
      capture_staging = capture_args[screenshot_index + 1]
      assert capture_staging.startswith("${pluginDataRoot}/staging/capture-"), capture_staging
      assert capture_staging.endswith(".png"), capture_staging
      assert capture_args[screenshot_index + 2:] == ["--screenshot-delay", "3"], capture_args
      machine.succeed("test ! -s /tmp/wall-in-one-vm-engine-current.pid")
      machine.wait_until_fails(f"kill -0 {capture_pid}")

      machine.wait_until_succeeds("test -s " + shlex.quote(internal_engine_still))
      machine.succeed(
          "${lib.getExe pkgs.ffmpeg} -v error -i "
          + shlex.quote(internal_engine_still)
          + " -f null -"
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --arg path "
          + shlex.quote(internal_engine_still)
          + " '.schema_version == 6 "
          + "and .last_capture.provider == \"w_engine\" "
          + "and .last_capture.dynamic_id == \"431960001\" "
          + "and .last_capture.method == \"linux-wallpaperengine-fbo-v1\" "
          + "and .last_capture.path == $path "
          + "and .pairs[\"HEADLESS-1\"].still_path == $path' "
          + "${pluginDataRoot}/runtime.json"
      )
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- "
          + shlex.quote(internal_engine_still)
      )
      try:
          machine.wait_until_succeeds(
              "test -s /tmp/wall-in-one-vm-engine-current.pid",
              timeout=50,
          )
      except Exception as renderer_start_error:
          start_probe = "native-workshop-live-start"
          noctalia_msg(f"plugin ${serviceId} all vm-action-probe {start_probe}")
          noctalia_msg(f"plugin ${serviceId} all vm-probe {start_probe}")
          action_diagnostic = machine.wait_until_succeeds(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_ACTION {start_probe}")
              + " | tail -n 1",
              timeout=10,
          ).strip()
          renderer_diagnostic = machine.wait_until_succeeds(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_PROBE {start_probe}")
              + " | tail -n 1",
              timeout=10,
          ).strip()
          cpu_diagnostic = machine.succeed(
              journal
              + " | grep -F -- 'exceeded its CPU budget' | tail -n 3 || true"
          ).strip()
          raise AssertionError(
              "native Workshop live renderer did not start: "
              + action_diagnostic
              + " | "
              + renderer_diagnostic
              + " | cpu="
              + (cpu_diagnostic or "none")
          ) from renderer_start_error
      engine_pid = machine.succeed("cat /tmp/wall-in-one-vm-engine-current.pid").strip()
      assert engine_pid != capture_pid
      machine.succeed(f"kill -0 {engine_pid}")
      machine.wait_until_fails(f"kill -0 {mpv_pid}")
      engine_args = machine.succeed(
          f"tr '\\0' '\\n' < /tmp/wall-in-one-vm-engine-{engine_pid}.args"
      ).splitlines()
      assert engine_args[1:] == [
          "--screen-root", "HEADLESS-1", "--bg", "${fixtureWorkshop}/431960001",
          "--scaling", "fill", "--clamp", "border", "--fps", "60",
          "--layer", "background", "--volume", "15", "--noautomute",
          "--no-audio-processing", "--disable-particles", "--disable-mouse",
          "--disable-parallax", "--fullscreen-pause-only-active",
      ], engine_args
      assert "--screenshot" not in engine_args, engine_args
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.current_workshops[\"HEADLESS-1\"] == \"431960001\"' "
          "${pluginDataRoot}/runtime.json"
      )
      internal_state_token = "internal-workshop-state"
      noctalia_msg(
          f"plugin ${serviceId} all vm-probe {internal_state_token}"
      )
      for fragment in (
          f"WALL_IN_ONE_VM_PROBE {internal_state_token}",
          "internal_current=431960001",
          "persisted_workshop=431960001",
          "renderer_workshop=431960001",
          "renderer_layer=background",
      ):
          wait_log(fragment)
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # Direct application is represented by the output's one-entry Quick
      # Choice playlist. It applies once and parks instead of becoming a timer.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e --slurpfile config ${pluginDataRoot}/config.json "
          "'(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| $config[0].playlists[$p].quick_choice == true "
          "and ($config[0].playlists[$p].entries | length) == 1 "
          "and .runs[\"HEADLESS-1\"][$p].running == false "
          "and .runs[\"HEADLESS-1\"][$p].paused == false "
          "and .runs[\"HEADLESS-1\"][$p].parked == true "
          "and .runs[\"HEADLESS-1\"][$p].next_due == 0 "
          "and .runs[\"HEADLESS-1\"][$p].current_entry "
          "== $config[0].playlists[$p].entries[0].id)' "
          "${pluginDataRoot}/runtime.json"
      )

      # Seed and drive one persistent named playlist while both internal
      # backends are active. The first static entry replaces the existing live
      # child; later entries exercise owned pause/resume/replacement.
      for event in (
          "vm-cycle-create",
          "vm-cycle-add-static",
          "vm-cycle-add-video",
          "vm-cycle-add-workshop",
          "vm-cycle-options",
          "vm-cycle-assign",
          "vm-cycle-schedule-upper",
          "vm-cycle-schedule-lower",
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 4 and "
          "(. as $config "
          "| ((.playlists | to_entries | map(select(.value.name == \"VM mixed playlist\")) | .[0]) as $record "
          "| $record.value as $p "
          "| $p.interval_seconds == 60 "
          "and $p.order == \"rotate\" "
          "and ($p.entries | length) == 3 "
          "and ([ $p.entries[].id ] | length) == ([ $p.entries[].id ] | unique | length) "
          "and ([ $p.entries[] as $entry "
          "| $config.pairings[$entry.pairing_id] as $pair "
          "| ($entry.pairing_id | type) == \"string\" "
          "and ($pair | type) == \"object\" "
          "and $pair.id == $entry.pairing_id "
          "and $pair.id != $entry.id "
          "and $pair.label == $entry.label "
          "and $pair.media == $entry.media "
          "and $pair.still == $entry.still "
          "and $pair.theme == $entry.theme ] | all) "
          "and $p.entries[0].media == null "
          "and $p.entries[0].still.mode == \"selected\" "
          "and $p.entries[0].still.path == \"${fixtureStill}\" "
          "and $p.entries[1].media.kind == \"video\" "
          "and $p.entries[1].still.path == \"${fixtureVideoStill}\" "
          "and $p.entries[2].media.kind == \"workshop\" "
          "and $p.entries[2].still.path == \"${fixtureWorkshopStill}\" "
          "and .outputs[\"HEADLESS-1\"].fallback_playlist == $record.key "
          "and (.outputs[\"HEADLESS-1\"].schedules | length) == 3 "
          "and ([ .outputs[\"HEADLESS-1\"].schedules[1:][].id ] "
          "== [\"vm-schedule-upper\",\"vm-schedule-lower\"]) "
          "and ([ .outputs[\"HEADLESS-1\"].schedules[1:][].playlist ] "
          "| all(. == $record.key)) "
          "and ([ .outputs[\"HEADLESS-1\"].schedules[1:][].enabled ] | all) "
          "and (.outputs[\"HEADLESS-1\"].schedules[1].months | length) == 1 "
          "and .outputs[\"HEADLESS-1\"].schedules[1].months "
          "== .outputs[\"HEADLESS-1\"].schedules[2].months "
          "and .outputs[\"HEADLESS-1\"].schedules[1].start_minute == 1080 "
          "and .outputs[\"HEADLESS-1\"].schedules[1].end_minute == 360 "
          "and ([ .outputs[\"HEADLESS-1\"].schedules[] | has(\"priority\") ] | any) == false))' "
          "${pluginDataRoot}/config.json"
      )

      # The lower matching row wins, while the adjacent month remains a miss.
      schedule_token = "month-list-order"
      noctalia_msg(f"plugin ${serviceId} all vm-schedule-probe {schedule_token}")
      for fragment in (
          f"WALL_IN_ONE_VM_SCHEDULE {schedule_token}",
          "winner=vm-schedule-lower",
          "miss=true",
      ):
          wait_log(fragment)

      # A screen can override playback independently, then return to inheriting
      # the playlist/global values without leaving stale output fields behind.
      noctalia_msg("plugin ${serviceId} all vm-output-options-override")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.outputs[\"HEADLESS-1\"].order == \"shuffle\" "
          "and .outputs[\"HEADLESS-1\"].interval_seconds == 120' "
          "${pluginDataRoot}/config.json"
      )
      noctalia_msg("plugin ${serviceId} all vm-output-options-inherit")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(.outputs[\"HEADLESS-1\"] | has(\"order\")) == false "
          "and (.outputs[\"HEADLESS-1\"] | has(\"interval_seconds\")) == false' "
          "${pluginDataRoot}/config.json"
      )

      # Exercise the public catalog command path independently of legacy entry
      # translation: save, add two reusable records, synchronize an edit across
      # linked occurrences, place by stable occurrence ID, then safely detach a
      # deleted drawer record while retaining its last valid snapshot.
      for event in (
          "vm-pairing-create",
          "vm-pairing-save-adaptive",
          "vm-pairing-save-video",
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.pairings[\"vm-pairing-adaptive\"].still.path == \"${fixtureStill}\" "
          "and .pairings[\"vm-pairing-adaptive\"].theme.source == \"wallpaper\" "
          "and .pairings[\"vm-pairing-video\"].media.kind == \"video\" "
          "and .pairings[\"vm-pairing-video\"].still.path == \"${fixtureVideoStill}\"' "
          "${pluginDataRoot}/config.json"
      )
      for event in (
          "vm-pairing-add-adaptive",
          "vm-pairing-add-video",
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(. as $config "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| ($p.entries | length) == 2 "
          "and [ $p.entries[].pairing_id ] "
          "== [\"vm-pairing-adaptive\",\"vm-pairing-video\"] "
          "and ([ $p.entries[] as $entry "
          "| $config.pairings[$entry.pairing_id] as $pair "
          "| $entry.id != $pair.id "
          "and $entry.label == $pair.label "
          "and $entry.media == $pair.media "
          "and $entry.still == $pair.still "
          "and $entry.theme == $pair.theme ] | all))' "
          "${pluginDataRoot}/config.json"
      )
      noctalia_msg("plugin ${serviceId} all vm-pairing-save-update")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(. as $config "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| $config.pairings[\"vm-pairing-adaptive\"].label == \"VM adaptive still updated\" "
          "and $config.pairings[\"vm-pairing-adaptive\"].theme.mode == \"light\" "
          "and ($p.entries[] | select(.pairing_id == \"vm-pairing-adaptive\") "
          "| .label == \"VM adaptive still updated\" and .theme.mode == \"light\"))' "
          "${pluginDataRoot}/config.json"
      )
      noctalia_msg("plugin ${serviceId} all vm-pairing-place")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value.entries "
          "| [ .[].pairing_id ]) == [\"vm-pairing-video\",\"vm-pairing-adaptive\"]' "
          "${pluginDataRoot}/config.json"
      )

      # The adaptive preview request deliberately supplies only the catalog ID;
      # the coordinator resolves the exact still and scheme, and the palette
      # service invokes Noctalia's isolated `theme ... --both -o` CLI.
      noctalia_msg("plugin ${serviceId} all vm-palette-preview")
      preview_token = "adaptive-ready"
      preview_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_PALETTE_PREVIEW {preview_token}",
          "state=ready",
          "key=vm-adaptive-preview",
          "path=${fixtureStill}",
          "scheme=m3-rainbow",
          "dark_surface=#101820",
          "dark_primary=#11AA22",
          "light_surface=#F4F5F6",
          "light_primary=#2255AA",
          "error=",
      ):
          preview_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-palette-preview-probe {preview_token}"
          )
          + " >/dev/null && "
          + preview_filters
      )
      preview_calls = [call for call in fixture_calls() if call and call[0] == "theme"]
      assert len(preview_calls) == 1, preview_calls
      assert preview_calls[0][:6] == [
          "theme",
          "${fixtureStill}",
          "--scheme",
          "m3-rainbow",
          "--both",
          "-o",
      ], preview_calls[0]
      assert len(preview_calls[0]) == 7, preview_calls[0]
      assert preview_calls[0][6].startswith("${pluginDataRoot}/palette-preview/preview-")
      assert preview_calls[0][6].endswith(".json")

      noctalia_msg("plugin ${serviceId} all vm-pairing-delete")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(. as $config "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| ($config.pairings | has(\"vm-pairing-adaptive\")) == false "
          "and ($p.entries | length) == 2 "
          "and $p.entries[0].pairing_id == \"vm-pairing-video\" "
          "and ($p.entries[1] | has(\"pairing_id\")) == false "
          "and $p.entries[1].label == \"VM adaptive still updated\" "
          "and $p.entries[1].still.path == \"${fixtureStill}\" "
          "and $p.entries[1].theme.mode == \"light\")' "
          "${pluginDataRoot}/config.json"
      )
      drive_cycle(
          "start",
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 6 "
          "and (.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].running == true "
          "and .runs[\"HEADLESS-1\"][$p].paused == false "
          "and (.runs[\"HEADLESS-1\"][$p].current_entry | type) == \"string\" "
          "and .runs[\"HEADLESS-1\"][$p].next_due > now "
          "and (.runs[\"HEADLESS-1\"][$p].history | length) == 1)' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_fails(f"kill -0 {engine_pid}")
      wait_cycle(running=True, paused=False, cursor=1, history=1, applying=False, backend="none")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(.current_workshops | has(\"HEADLESS-1\")) == false' "
          "${pluginDataRoot}/runtime.json"
      )

      drive_cycle(
          "next",
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| (.runs[\"HEADLESS-1\"][$p].history | length) == 2 "
          "and .runs[\"HEADLESS-1\"][$p].current_entry == .runs[\"HEADLESS-1\"][$p].history[-1])' "
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
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].paused == true)' "
          "${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" = T"
      )
      wait_cycle(running=True, paused=True, cursor=2, history=2, applying=False, backend="mpvpaper")
      noctalia_msg("plugin ${serviceId} all vm-cycle-action next")
      machine.sleep(1)
      machine.succeed(
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].paused == true "
          "and (.runs[\"HEADLESS-1\"][$p].history | length) == 2)' "
          "${pluginDataRoot}/runtime.json"
      )
      machine.succeed(
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" = T"
      )
      drive_cycle(
          "resume-stale-renderer-state",
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].running == true "
          "and .runs[\"HEADLESS-1\"][$p].paused == false)' ${pluginDataRoot}/runtime.json",
      )
      machine.wait_until_succeeds(
          f"test -r /proc/{cycle_mpv_pid}/status; "
          f"test \"$(awk '/^State:/ {{print $2}}' /proc/{cycle_mpv_pid}/status)\" != T"
      )
      wait_cycle(running=True, paused=False, cursor=2, history=2, applying=False, backend="mpvpaper")

      drive_cycle(
          "next",
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| (.runs[\"HEADLESS-1\"][$p].history | length) == 3)' "
          "${pluginDataRoot}/runtime.json",
      )
      wait_cycle(running=True, paused=False, cursor=3, history=3, applying=False, backend="w-engine")
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

      # A child that survives the supervisor's startup probe but exits one
      # couple of seconds later must not turn playlist recovery into an
      # immediate loop.
      machine.succeed(
          "runuser -u vmtester -- bash -c "
          + shlex.quote("printf '%s\\n' delayed-exit > /tmp/wall-in-one-vm-mpvpaper-mode")
      )
      mpv_invocations_before_crash = len(
          machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-invocations.log").splitlines()
      )
      drive_cycle(
          "previous",
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| (.runs[\"HEADLESS-1\"][$p].history | length) == 2)' "
          "${pluginDataRoot}/runtime.json",
      )
      wait_cycle(running=True, paused=False, cursor=2, history=2, applying=False, backend="mpvpaper")
      machine.wait_until_succeeds(
          "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -eq "
          + str(mpv_invocations_before_crash + 1)
      )
      delayed_exit_pid = machine.succeed(
          "cat /tmp/wall-in-one-vm-mpvpaper-current.pid"
      ).strip()
      machine.wait_until_fails(f"kill -0 {delayed_exit_pid}")
      machine.succeed(
          "runuser -u vmtester -- bash -c "
          + shlex.quote("printf '%s\\n' hold > /tmp/wall-in-one-vm-mpvpaper-mode")
      )
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].running == true "
          "and .runs[\"HEADLESS-1\"][$p].paused == false "
          "and (.runs[\"HEADLESS-1\"][$p].history | length) == 2 "
          "and (.runs[\"HEADLESS-1\"][$p].last_error | length) > 0 "
          "and .runs[\"HEADLESS-1\"][$p].next_due >= (now + 5))' "
          "${pluginDataRoot}/runtime.json"
      )
      machine.sleep(3)
      machine.succeed(
          "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -eq "
          + str(mpv_invocations_before_crash + 1)
          + " && ${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| (.runs[\"HEADLESS-1\"][$p].history | length) == 2)' ${pluginDataRoot}/runtime.json"
      )
      wait_cycle(running=True, paused=False, cursor=3, history=3, applying=False, backend="w-engine")
      machine.wait_until_succeeds(
          "test \"$(cat /tmp/wall-in-one-vm-engine-current.pid)\" != " + cycle_engine_pid
      )
      history_before_random = int(machine.succeed(
          "${lib.getExe pkgs.jq} '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].history | length)' "
          "${pluginDataRoot}/runtime.json"
      ))
      # The preceding probe proves the previous transition is settled. Send
      # random once, then observe its durable history change without replaying
      # the user action while its asynchronous renderer work completes.
      noctalia_msg("plugin ${serviceId} all vm-cycle-action random")
      machine.wait_until_succeeds(
          "test $(${lib.getExe pkgs.jq} "
          "'(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].history | length)' "
          "${pluginDataRoot}/runtime.json) -gt " + str(history_before_random),
          timeout=60,
      )
      drive_cycle(
          "stop",
          "${lib.getExe pkgs.jq} -e '(.output_states[\"HEADLESS-1\"].active_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].running == false "
          "and .runs[\"HEADLESS-1\"][$p].paused == false "
          "and .runs[\"HEADLESS-1\"][$p].next_due == 0)' "
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
          renderer_pending=0,
          renderer_queue_depth=0,
          renderer_write_in_flight=False,
      )
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # Losing the external-ownership observation is not evidence that no
      # external owner exists. Force a provider probe failure while an internal
      # child is live: both backends must fail closed and the exact owned child
      # must stop, without touching the unrelated sentinel. A successful probe
      # is required before internal apply becomes available again.
      def wait_internal_video_settled():
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
              renderer_owned=True,
              renderer_pending=0,
              renderer_queue_depth=0,
              renderer_write_in_flight=False,
          )

      previous_mpv_invocations = len(
          machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-invocations.log").splitlines()
      )
      noctalia_msg("plugin ${serviceId} all vm-apply-video")
      machine.sleep(2)
      if len(machine.succeed(
          "cat /tmp/wall-in-one-vm-mpvpaper-invocations.log"
      ).splitlines()) <= previous_mpv_invocations:
          noctalia_msg("plugin ${serviceId} all vm-probe renderer-restart-pending")
          machine.sleep(6)
          noctalia_msg("plugin ${serviceId} all vm-probe renderer-restart-timeout")
      machine.wait_until_succeeds(
          "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -eq "
          + str(previous_mpv_invocations + 1),
          timeout=5,
      )
      probe_failure_pid = machine.succeed(
          "cat /tmp/wall-in-one-vm-mpvpaper-current.pid"
      ).strip()
      machine.succeed(f"kill -0 {probe_failure_pid}")
      wait_internal_video_settled()
      machine.succeed(
          "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -eq "
          + str(previous_mpv_invocations + 1)
      )

      # Replacing one owned renderer with another must remain a one-shot user
      # action even when stop/start commands and their async completions arrive
      # back-to-back. This specifically guards the renderer FIFO latch.
      for replacement in range(8):
          previous_mpv_invocations = len(
              machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-invocations.log").splitlines()
          )
          previous_pid = probe_failure_pid
          noctalia_msg("plugin ${serviceId} all vm-apply-video")
          machine.wait_until_succeeds(
              "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -ge "
              + str(previous_mpv_invocations + 1)
              + " && test \"$(cat /tmp/wall-in-one-vm-mpvpaper-current.pid)\" != "
              + previous_pid,
              timeout=15,
          )
          probe_failure_pid = machine.succeed(
              "cat /tmp/wall-in-one-vm-mpvpaper-current.pid"
          ).strip()
          assert probe_failure_pid != previous_pid
          machine.wait_until_fails(f"kill -0 {previous_pid}")
          machine.succeed(f"kill -0 {probe_failure_pid}")
          wait_internal_video_settled()
          machine.succeed(
              "test $(wc -l < /tmp/wall-in-one-vm-mpvpaper-invocations.log) -eq "
              + str(previous_mpv_invocations + 1)
          )

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

      # The explicit MotionBGS directory intentionally equals the user video
      # root. Sidecar-proven downloads must still win ownership classification
      # and remain deletable, while unrelated files in that root stay owned by
      # the user. Re-downloading the same deterministic path must refresh the
      # library from the completion nonce rather than the path alone.
      wait_library(
          scanning=False,
          videos=7,
          workshops=1,
          motion_managed=True,
          motion_deletable=True,
          motion_provider="MotionBGS",
          user_managed=False,
          user_deletable=False,
          user_provider="local",
      )
      noctalia_msg("plugin ${serviceId} all vm-delete-motion-download")
      machine.wait_until_fails("test -e " + shlex.quote(motion_download), timeout=60)
      machine.wait_until_fails(
          "test -e " + shlex.quote(motion_download + ".motionbgs.json"),
          timeout=60,
      )
      wait_library(scanning=False, videos=6, workshops=1)
      noctalia_msg("plugin ${serviceId} all vm-motion-download night-city")
      wait_motion(action="download", download=motion_download, busy=False)
      machine.wait_until_succeeds(
          "test -s "
          + shlex.quote(motion_download)
          + " && test -s "
          + shlex.quote(motion_download + ".motionbgs.json"),
          timeout=60,
      )
      wait_library(
          scanning=False,
          videos=7,
          workshops=1,
          motion_managed=True,
          motion_deletable=True,
          motion_provider="MotionBGS",
          user_managed=False,
          user_deletable=False,
          user_provider="local",
      )

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
      for call in native_calls:
          if call[1] == "wallpaper-set":
              assert len(call) == 4, native_calls
              assert call[2] == "HEADLESS-1", native_calls
              assert call[3].startswith("/"), native_calls
          else:
              assert call[1] in (
                  "wallpaper-next",
                  "wallpaper-previous",
                  "wallpaper-random",
              ), native_calls
              assert len(call) == 3 and call[2] == "HEADLESS-1", native_calls

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
          + " '.schema_version == 6 "
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
          + " '.schema_version == 6 "
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
          "'.gestures.left == \"hub_open\" and .gestures.right == \"native_random\"' "
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
          "'.schema_version == 4 and (.pairings | type) == \"object\" "
          "and (. as $config "
          "| .outputs[\"HEADLESS-1\"].fallback_playlist as $p "
          "| .playlists[$p].name == \"VM mixed playlist\" "
          "and (.playlists[$p].entries | length) == 3 "
          "and ([ .playlists[$p].entries[].id ] | length) "
          "== ([ .playlists[$p].entries[].id ] | unique | length) "
          "and ([ .playlists[$p].entries[] as $entry "
          "| $config.pairings[$entry.pairing_id].id == $entry.pairing_id ] | all) "
          "and ($config.pairings | has(\"vm-pairing-adaptive\")) == false "
          "and $config.pairings[\"vm-pairing-video\"].media.kind == \"video\")' "
          "${pluginDataRoot}/config.json"
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e --slurpfile config ${pluginDataRoot}/config.json "
          "'.schema_version == 6 "
          "and ($config[0].outputs[\"HEADLESS-1\"].fallback_playlist as $p "
          "| .runs[\"HEADLESS-1\"][$p].running == false "
          "and (.runs[\"HEADLESS-1\"][$p].history | type) == \"array\") "
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
      # matrix. Prove that onOpen crossed panel.render(), that panel IPC is
      # alive, and that opening the panel changed the composed output. A mere
      # filename match can also match a Luau compiler error.
      panel_baseline = "/tmp/noctalia-wall-in-one-vm-before-panel.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} ${lib.getExe pkgs.grim} -o HEADLESS-1 {panel_baseline}"
      )
      panel_probe_marker = "W_ENGINE_VM_SERVICE wall-in-one-probe-v1"
      panel_probes_before = machine.succeed(journal).count(panel_probe_marker)
      assert noctalia_msg("panel-toggle ${pluginId}:hub").strip().startswith("ok")
      wait_log('panel manager: opened "${pluginId}:hub"')
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- {shlex.quote(panel_probe_marker)}) "
          f"-gt {panel_probes_before}"
      )
      assert noctalia_msg(
          "plugin ${pluginId}:hub all probe"
      ).strip() == "ok: dispatched 1"
      machine.sleep(1)
      screenshot = "/tmp/noctalia-wall-in-one-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} ${lib.getExe pkgs.grim} -o HEADLESS-1 {screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {screenshot}) -gt 1000")
      machine.fail(f"cmp -s {panel_baseline} {screenshot}")
      machine.fail(f"{journal} | grep -F -- 'luau_load failed'")
      machine.fail(f"{journal} | grep -F -- \"call to 'onOpen' failed\"")
      machine.copy_from_machine(screenshot)

      # Corrupt user data is evidence: reload must not reset or overwrite it,
      # and action dispatch remains disabled. Teardown deliberately leaves
      # Noctalia's last static backing and complete color selection in place,
      # so boot has the paired image/theme before a dynamic child starts.
      wallpaper_before_disable = machine.succeed(
          noctalia_command("wallpaper-get HEADLESS-1")
      ).strip()
      palette_before_disable = machine.succeed(
          noctalia_command("color-scheme-get")
      ).strip()
      theme_mode_before_disable = machine.succeed(
          noctalia_command("theme-mode-get")
      ).strip()
      assert wallpaper_before_disable
      assert palette_before_disable
      assert theme_mode_before_disable
      machine.succeed("rm -f ${pluginDataRoot}/.vm-palette-exit")
      assert noctalia_msg("plugins disable ${pluginId}").strip().startswith("ok")
      machine.wait_until_succeeds(
          "grep -Fx -- "
          "'protocol=1 ready_false=true refreshing_false=true "
          "event_stopped=true preview_idle=true shape_complete=true' "
          "${pluginDataRoot}/.vm-palette-exit"
      )
      assert machine.succeed(
          noctalia_command("wallpaper-get HEADLESS-1")
      ).strip() == wallpaper_before_disable
      assert machine.succeed(
          noctalia_command("color-scheme-get")
      ).strip() == palette_before_disable
      assert machine.succeed(
          noctalia_command("theme-mode-get")
      ).strip() == theme_mode_before_disable
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
          "grep -F 'noctalia msg wallpaper-set' ${materializedRoot}/service.luau"
      )
      machine.succeed(
          "grep -F 'capture-v1' ${materializedRoot}/service.luau"
      )
      machine.fail(
          "grep -F 'linux-wallpaperengine' ${materializedRoot}/scripts/capture-still"
      )
      machine.fail(
          "grep -n -F 'linux-wallpaperengine' ${materializedRoot}/service.luau "
          "| grep -Fv 'commandExists(\"linux-wallpaperengine\")' "
          "| grep -Fv 'linux-wallpaperengine-fbo-v1'"
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
      machine.succeed("test -s /tmp/wall-in-one-vm-engine-capture-invocations.log")
      machine.succeed("test -s /tmp/wall-in-one-vm-mpvpaper-invocations.log")
      machine.succeed("test ! -s /tmp/wall-in-one-vm-mpv-invocations.log")
      machine.succeed(
          "for log in /tmp/wall-in-one-vm-engine-invocations.log "
          "/tmp/wall-in-one-vm-engine-capture-invocations.log "
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
          "luau_load failed",
          "call to 'onOpen' failed",
          "Out of local registers",
          "[glyph] missing glyph",
          "undeclared setting",
          "hot reload: failed",
          "exceeded its CPU budget",
      ):
          assert forbidden not in logs, f"unexpected log marker: {forbidden}"

      noctalia_msg("plugins disable ${pluginId}")
      machine.wait_until_fails(
          "find ${runtimeRoot}/noctalia-wall-in-one -maxdepth 1 -type p "
          "-name 'renderer-*.fifo' | grep -q ."
      )
      machine.succeed(
          "for log in /tmp/wall-in-one-vm-engine-invocations.log "
          "/tmp/wall-in-one-vm-engine-capture-invocations.log "
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
