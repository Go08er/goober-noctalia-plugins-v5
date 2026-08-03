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
    ];
  };

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

  # Deliberately vivid, provider-specific colors make the panel screenshot a
  # deterministic assertion that ui.image rendered the cached file rather
  # than leaving the glyph fallback in place.
  fixtureWallhavenThumbnail = pkgs.runCommand "wall-in-one-vm-wallhaven-thumbnail.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 320x180 'xc:#f51166' -strip "png:$out"
  '';

  fixtureMotionBgsThumbnail = pkgs.runCommand "wall-in-one-vm-motionbgs-thumbnail.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 320x180 'xc:#12d6c5' -strip "png:$out"
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

  motionGenreCards = lib.concatMapStrings (index: ''
    <a href="/nature-${toString index}" title="Nature ${toString index} Live Wallpaper">
      <span class="ttl">Nature ${toString index}</span>
      <span class="frm">4K</span>
      <img src=/i/c/364x205/media/${toString index}/nature-${toString index}.3840x2160.jpg>
    </a>
  '') (lib.range 1 36);

  motionSearchHtml = pkgs.writeText "motionbgs-search.html" ''
    <!doctype html><html><body>
      <a href="/night-city" title="Night City Live Wallpaper">
        <span class="ttl">Night City</span>
        <span class="frm">4K</span>
        <picture>
          <source srcset=/i/c/364x205/media/4242/night-city.3840x2160.jpg.webp type=image/webp>
          <img src=/i/c/364x205/media/4242/night-city.3840x2160.jpg>
        </picture>
      </a>
      <a href="https://evil.example/not-a-card" title="Ignore Live Wallpaper">
        <span class="ttl">Cross origin</span>
      </a>
    </body></html>
  '';
  motionGenrePageOneHtml = pkgs.writeText "motionbgs-genre-page-1.html" ''
    <!doctype html><html><head>
      <title>610+ Nature Live Wallpapers 4K &amp; HD</title>
      <link rel="next" href="https://motionbgs.com/tag:nature/2/">
    </head><body>
      ${motionGenreCards}
    </body></html>
  '';
  motionGenrePageTwoHtml = pkgs.writeText "motionbgs-genre-page-2.html" ''
    <!doctype html><html><head>
      <title>600+ Nature Live Wallpapers 4K &amp; HD (Page 2)</title>
      <link rel="prev" href="https://motionbgs.com/tag:nature/">
    </head><body>
      <a href="/nature-page-two" title="Nature Page Two Live Wallpaper">
        <span class="ttl">Nature Page Two</span>
        <span class="frm">HD</span>
        <img src=/i/c/364x205/media/9999/nature-page-two.1920x1080.jpg>
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

  rawPluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = pluginRoot + "/wall-in-one";
  };
  stagedSource = pkgs.runCommand "noctalia-wall-in-one-vm-source" { } ''
    mkdir -p "$out/wall-in-one"
    cp -R ${rawPluginSource}/wall-in-one/. "$out/wall-in-one/"
    cp ${catalog} "$out/catalog.toml"
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
              https://motionbgs.com/tag:nature/) source=${motionGenrePageOneHtml} ;;
              https://motionbgs.com/tag:nature/2/) source=${motionGenrePageTwoHtml} ;;
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

  # The production helper is self-tested before this replacement is installed.
  # Panel coverage then stays fully offline while retaining the helper's exact
  # success protocol and recording every attempted cache miss.
  fakeProviderThumbnailHelper = pkgs.writeText "wall-in-one-provider-thumbnail-fixture" ''
    #!/usr/bin/env bash
    set -uo pipefail

    [[ ''${1:-} == fetch && $# -eq 4 ]] || {
      printf 'WIO-THUMB1\terror\tusage\t0\tfixture expected fetch PROVIDER URL OUTPUT\n'
      exit 64
    }

    provider=$2
    url=$3
    destination=$4
    printf 'fetch\t%s\t%s\t%s\n' "$provider" "$url" "$destination" \
      >> /tmp/wall-in-one-vm-thumbnail-calls.log

    mode=$(cat /tmp/wall-in-one-vm-thumbnail-mode 2>/dev/null || printf good)
    if [[ $mode == deny ]]; then
      printf 'WIO-THUMB1\terror\tfixture-deny\t0\tcache miss unexpectedly reached helper\n'
      exit 69
    fi
    [[ $mode == good ]] || exit 64

    case "$provider:$url" in
      wallhaven:https://th.wallhaven.cc/lg/ab/abc123.jpg)
        source=${fixtureWallhavenThumbnail}
        ;;
      motionbgs:https://motionbgs.com/i/c/364x205/media/4242/night-city.3840x2160.jpg)
        source=${fixtureMotionBgsThumbnail}
        ;;
      *)
        printf 'WIO-THUMB1\terror\tfixture-url\t0\tunexpected provider thumbnail URL\n'
        exit 64
        ;;
    esac

    cp -- "$source" "$destination"
    bytes=$(stat -c %s -- "$destination")
    printf 'WIO-THUMB1\tok\t%s\t200\t%s\timage/png\t%s\t%s\n' \
      "$provider" "$url" "$bytes" "$destination"
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
                    .. " wallhaven="
                    .. tostring(providers.wallhaven.available)
                    .. " w_command="
                    .. tostring(providers.w_engine.command_available)
                    .. " w_available="
                    .. tostring(providers.w_engine.available)
                    .. " w_apply="
                    .. tostring(providers.w_engine.apply_available)
                    .. " internal_current="
                    .. tostring(providers.w_engine.internal_current["HEADLESS-1"] or "")
                    .. " persisted_workshop="
                    .. tostring(runtime.current_workshops["HEADLESS-1"] or "")
                    .. " renderer_workshop="
                    .. tostring(type(vmOwned) == "table" and vmOwned.workshop_id or "")
                    .. " renderer_layer="
                    .. tostring(type(vmOwned) == "table" and vmOwned.layer or "")
                    .. " mpv_command="
                    .. tostring(providers.mpvpaper.command_available)
                    .. " mpv_available="
                    .. tostring(providers.mpvpaper.available)
                    .. " mpv_apply="
                    .. tostring(providers.mpvpaper.apply_available)
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
                    .. " left="
                    .. tostring(config.gestures.left)
                    .. " middle="
                    .. tostring(config.gestures.middle)
                    .. " right="
                    .. tostring(config.gestures.right)
                    .. " storage="
                    .. tostring(configValid and runtimeValid)
            )
        elseif event == "vm-output-engines" then
            vmHandle({
                kind = "output_engines",
                output = "HEADLESS-1",
                engines = {
                    layer = "bottom",
                    video = {
                        enabled = true,
                        mute = false,
                        hardware_decode = false,
                        auto_pause = false,
                        auto_pause_mode = "ACTIVE",
                        options = "keep-open=yes",
                    },
                    workshop = {
                        enabled = true,
                        fps = 60,
                        volume = 15,
                        silent = false,
                        scaling = "fill",
                        clamp = "border",
                        flags = {
                            noautomute = true,
                            no_audio_processing = true,
                            disable_particles = true,
                            disable_mouse = true,
                            disable_parallax = true,
                            no_fullscreen_pause = false,
                            fullscreen_pause_only_active = true,
                        },
                    },
                },
            })
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
        elseif event == "vm-motion-browse-genre" then
            vmHandle({
                kind = "motionbgs_search",
                mode = "genre",
                genre = "nature",
                page = tonumber(payload) or 1,
            })
        elseif event == "vm-motion-hd-page-two" then
            vmHandle({ kind = "motionbgs_search", mode = "hd", page = 2 })
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
            local meta = type(motionBgsResults) == "table" and motionBgsResults.meta or {}
            local downloaded = type(motionBgsStatus) == "table" and motionBgsStatus.last_download or {}
            noctalia.log(
                "WALL_IN_ONE_VM_MOTION "
                    .. tostring(payload or "")
                    .. " available=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.available == true)
                    .. " busy=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.busy == true)
                    .. " action=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.last_action or "")
                    .. " error_kind=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.last_error_kind or "")
                    .. " cached=" .. tostring(type(motionBgsResults) == "table" and motionBgsResults.cached == true)
                    .. " mode=" .. tostring(type(motionBgsResults) == "table" and motionBgsResults.mode or "")
                    .. " page=" .. tostring(type(meta) == "table" and meta.current_page or 0)
                    .. " previous=" .. tostring(type(meta) == "table" and meta.has_previous == true)
                    .. " next=" .. tostring(type(meta) == "table" and meta.has_next == true)
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

  # This is appended only to the materialized VM panel. It drives the real
  # provider-section builders with deterministic metadata and keeps them above
  # the fold, so the screenshot test exercises production preview.ensure(),
  # preview.node(), async completion, and ui.image rather than a test facsimile.
  vmPanelPreviewProbe = pkgs.writeText "wall-in-one-vm-panel-preview-probe.luau" ''
    do
        local vmPreview = {
            provider = "",
            render = render,
            onIpc = onIpc,
        }

        render = function()
            if vmPreview.provider == "" then
                vmPreview.render()
                return
            end
            if not isOpen then
                return
            end

            local section = if vmPreview.provider == "wallhaven"
                then wallhavenSection()
                else motionBgsSection()
            panel.render(ui.column({ gap = 10, padding = 14, align = "stretch", flexGrow = 1 }, {
                ui.label({
                    text = "VM provider preview · " .. vmPreview.provider,
                    fontSize = 14,
                    fontWeight = "bold",
                }),
                ui.scroll({
                    key = "wall-in-one-vm-provider-preview-" .. vmPreview.provider,
                    flexGrow = 1,
                    align = "stretch",
                    gap = 10,
                }, { section }),
            }))
        end

        onIpc = function(event, payload)
            if event == "vm-provider-preview" then
                local provider, token = tostring(payload or ""):match("^([a-z]+):([a-z0-9-]+)$")
                if provider == "wallhaven" then
                    local item = {
                        id = "abc123",
                        url = "https://wallhaven.cc/w/abc123",
                        short_url = "https://whvn.cc/abc123",
                        resolution = "320x180",
                        ratio = "16:9",
                        purity = "sfw",
                        category = "general",
                        file_size = 12345,
                        views = 12,
                        favorites = 3,
                        thumbs = {
                            large = "https://th.wallhaven.cc/lg/ab/abc123.jpg",
                        },
                    }
                    wallhavenResultsState = {
                        schema = 1,
                        kind = "search",
                        sequence = 901,
                        items = { item },
                        selected = item,
                        meta = { current_page = 1, last_page = 1, total = 1 },
                    }
                    wallhavenState = { available = true, busy = false }
                    vmPreview.provider = provider
                    status = composeStatus()
                    status.storage_valid = true
                    render()
                    noctalia.log("WALL_IN_ONE_VM_PROVIDER_PREVIEW wallhaven token=" .. token)
                    return
                elseif provider == "motionbgs" then
                    local item = {
                        slug = "night-city",
                        title = "Night City VM Preview",
                        quality = "4K",
                        source_url = "https://motionbgs.com/night-city",
                        thumbnail_url = "https://motionbgs.com/i/c/364x205/media/4242/night-city.3840x2160.jpg",
                        poster_url = "https://motionbgs.com/media/4242/poster.jpg",
                        duration = "00:30",
                        downloads = {},
                    }
                    motionBgsResultsState = {
                        schema = 1,
                        kind = "search",
                        sequence = 902,
                        items = { item },
                        selected = item,
                    }
                    vmPreview.provider = provider
                    status = composeStatus()
                    status.storage_valid = true
                    if type(status.providers) ~= "table" then
                        status.providers = {}
                    end
                    if type(status.providers.motionbgs) ~= "table" then
                        status.providers.motionbgs = {}
                    end
                    status.providers.motionbgs.integration_available = true
                    render()
                    noctalia.log("WALL_IN_ONE_VM_PROVIDER_PREVIEW motionbgs token=" .. token)
                    return
                end
            elseif event == "vm-provider-preview-reset" then
                vmPreview.provider = ""
                activePage = "main"
                reloadSharedState()
                vmPreview.render()
                noctalia.log("WALL_IN_ONE_VM_PROVIDER_PREVIEW reset")
                return
            end

            if type(vmPreview.onIpc) == "function" then
                vmPreview.onIpc(event, payload)
            end
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
    use_motionbgs = true
    capture_directory = "${captureRoot}"
    video_directory = "${videoRoot}"
    motionbgs_quality = "hd"
    motionbgs_result_limit = 48
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
    cycle_interval_minutes = 15
    cycle_order = "sequential"
    cycle_start_on_load = false

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

      # Seed Noctalia's blobless Git cache layout. Other VM tests cover the
      # clone-on-enable path; this fixture focuses on the plugin runtime.
      install -d -m 0755 "${sourceStorageRoot}"
      git clone --filter=blob:none --no-checkout \
        "${sourceUrl}" "${clonedRepoRoot}"

      : > /tmp/wall-in-one-vm-noctalia-calls.log
      : > /tmp/wall-in-one-vm-engine-invocations.log
      : > /tmp/wall-in-one-vm-engine-capture-invocations.log
      : > /tmp/wall-in-one-vm-mpvpaper-invocations.log
      : > /tmp/wall-in-one-vm-mpv-invocations.log
      : > /tmp/wall-in-one-vm-motion-calls.log
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
      def wait_direct(**expected):
          probe_number[0] += 1
          token = f"probe-{probe_number[0]}"
          filters = journal + " | grep -F -- " + shlex.quote(
              f"WALL_IN_ONE_VM_PROBE {token}"
          )
          for key, value in expected.items():
              if isinstance(value, bool):
                  value = str(value).lower()
              filters += " | grep -F -- " + shlex.quote(f"{key}={value}")
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-probe {token}")
              + " >/dev/null && "
              + filters,
              timeout=60,
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
          try:
              machine.wait_until_succeeds(
                  noctalia_command(f"plugin ${serviceId} all vm-motion-probe {token}")
                  + " >/dev/null && "
                  + filters,
                  timeout=60,
              )
          except Exception:
              print(
                  "MotionBGS wait failed; recent Noctalia journal:\n"
                  + machine.execute(
                      "journalctl -b --no-pager -u noctalia-wall-in-one-vm-session.service "
                      "| tail -n 180"
                  )[1]
                  + "\nMotionBGS fixture calls:\n"
                  + machine.execute("tail -n 80 /tmp/wall-in-one-vm-motion-calls.log")[1]
              )
              raise

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
      # Keep one real schema-3 document in the VM path. Schema 5 must create a
      # reusable catalog record, link the legacy occurrence to it, expand the
      # omitted calendar months, retire numeric schedule priority, and attach
      # per-output engine settings.
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
          "runuser -u ${testUser} -- bash "
          "${materializedRoot}/scripts/provider-thumbnail self-test "
          "| grep -Fx $'WIO-THUMB1\\tok\\tself-test'"
      )
      machine.succeed(
          "cp ${fakeMotionBgsHelper} ${materializedRoot}/scripts/motionbgs-provider; "
          "chmod 0755 ${materializedRoot}/scripts/motionbgs-provider; "
          "cp ${fakeProviderThumbnailHelper} ${materializedRoot}/scripts/provider-thumbnail; "
          "chmod 0755 ${materializedRoot}/scripts/provider-thumbnail"
      )

      machine.succeed(
          "cat ${materializedRoot}/service.luau ${vmProbe} "
          "> ${materializedRoot}/service.luau.new && "
          "mv ${materializedRoot}/service.luau.new ${materializedRoot}/service.luau && "
          "cat ${materializedRoot}/palettes.luau ${vmPaletteExitProbe} "
          "> ${materializedRoot}/palettes.luau.new && "
          "mv ${materializedRoot}/palettes.luau.new ${materializedRoot}/palettes.luau && "
          "cat ${materializedRoot}/panel.luau ${vmPanelPreviewProbe} "
          "> ${materializedRoot}/panel.luau.new && "
          "mv ${materializedRoot}/panel.luau.new ${materializedRoot}/panel.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")
      wait_log("hot reload: reloaded service '${palettesServiceId}'")
      machine.succeed(
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/panel.luau && "
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/palettes.luau"
      )
      wait_direct(
          wallhaven=True,
          w_command=True,
          w_available=True,
          w_apply=True,
          mpv_command=True,
          mpv_available=True,
          mpv_apply=True,
          renderer_ready=True,
          left="hub_open",
          right="native_next",
          storage=True,
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
          "config_schema=5",
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

      # The explicit schema-3 fixture is upgraded to schema 5 without losing
      # its occurrence snapshot. Its omitted month filter becomes all months,
      # the retired priority field does not cross the migration boundary, and
      # per-output engine defaults are materialized.
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 5 and .gestures.left == \"hub_open\" "
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
          "and (.outputs[\"HEADLESS-1\"].engines | type) == \"object\" "
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

      # Renderer configuration is persisted per display in schema 5. This
      # command deliberately differs from the defaults so launch argv proves
      # that the selected output owns the settings.
      noctalia_msg("plugin ${serviceId} all vm-output-engines")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 5 "
          "and .outputs[\"HEADLESS-1\"].engines.layer == \"bottom\" "
          "and .outputs[\"HEADLESS-1\"].engines.video.enabled == true "
          "and .outputs[\"HEADLESS-1\"].engines.video.mute == false "
          "and .outputs[\"HEADLESS-1\"].engines.video.auto_pause_mode == \"ACTIVE\" "
          "and .outputs[\"HEADLESS-1\"].engines.workshop.fps == 60 "
          "and .outputs[\"HEADLESS-1\"].engines.workshop.volume == 15 "
          "and .outputs[\"HEADLESS-1\"].engines.workshop.flags.disable_particles == true' "
          "${pluginDataRoot}/config.json"
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

      # Direct backend availability follows the executable itself. There is no
      # peer-plugin fallback or external ownership policy.
      machine.succeed("rm /tmp/noctalia-wall-in-one-tools/linux-wallpaperengine")
      wait_direct(
          wallhaven=True,
          w_command=False,
          w_available=False,
          w_apply=False,
          mpv_command=True,
          mpv_available=True,
          mpv_apply=True,
          right="native_next",
      )
      machine.succeed(
          "cp ${fakeWallpaperEngine}/bin/linux-wallpaperengine "
          "/tmp/noctalia-wall-in-one-tools/linux-wallpaperengine"
      )
      wait_direct(
          wallhaven=True,
          w_command=True,
          w_available=True,
          w_apply=True,
          mpv_command=True,
          mpv_available=True,
          mpv_apply=True,
          right="native_next",
      )

      # The fake executables stay alive so exact argv, replacement, playback,
      # and teardown can be checked without a real live-wallpaper compositor.
      noctalia_msg("plugin ${serviceId} all vm-apply-video")
      machine.wait_until_succeeds("test -s /tmp/wall-in-one-vm-mpvpaper-current.pid")
      mpv_pid = machine.succeed("cat /tmp/wall-in-one-vm-mpvpaper-current.pid").strip()
      machine.succeed(f"kill -0 {mpv_pid}")
      mpv_args = machine.succeed(
          f"tr '\\0' '\\n' < /tmp/wall-in-one-vm-mpvpaper-{mpv_pid}.args"
      ).splitlines()
      assert mpv_args[1:3] == ["--layer", "bottom"], mpv_args
      assert "--auto-pause" not in mpv_args, mpv_args
      assert "--auto-mode" not in mpv_args, mpv_args
      assert mpv_args[-2:] == ["HEADLESS-1", "${fixtureVideo}"], mpv_args
      mpv_options = mpv_args[mpv_args.index("-o") + 1]
      for token in (
          "loop-file=inf",
          "panscan=1.0",
          "terminal=no",
          "volume=100",
          "mute=no",
          "hwdec=no",
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
      # Remove any disposable VM-owned still before this case so direct
      # linux-wallpaperengine screenshot generation is deterministic.
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
          "--layer", "bottom", "--volume", "15", "--noautomute",
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
          "--layer", "bottom", "--volume", "15", "--noautomute",
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
          "renderer_layer=bottom",
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
          "'.schema_version == 5 and "
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
      wait_direct(
          wallhaven=True,
          w_command=True,
          w_available=True,
          w_apply=True,
          mpv_command=True,
          mpv_available=True,
          mpv_apply=True,
          renderer_ready=True,
          renderer_owned=False,
          renderer_pending=0,
          renderer_queue_depth=0,
          renderer_write_in_flight=False,
      )
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # Repeated direct applies replace exactly Wall-in-One's owned child and
      # never touch an unrelated process on the same system.
      def wait_internal_video_settled():
          wait_direct(
              wallhaven=True,
              w_command=True,
              w_available=True,
              w_apply=True,
              mpv_command=True,
              mpv_available=True,
              mpv_apply=True,
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

      noctalia_msg("plugin ${serviceId} all vm-renderer-stop")
      machine.wait_until_fails(f"kill -0 {probe_failure_pid}")
      assert machine.succeed(
          "systemctl show -p MainPID --value wall-in-one-renderer-sentinel.service"
      ).strip() == sentinel_pid

      # MotionBGS runs entirely against pinned local HTML/MP4 fixtures. The
      # shipped helper's self-test ran before replacement above.
      wait_motion(available=True, busy=False)
      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(
          action="search", cached=False, busy=False,
          items=1, first="night-city",
      )
      motion_calls_after_search = len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      )

      # A fresh cache hit must not invoke even a deliberately failing helper.
      set_motion_mode("deny")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(
          action="search", cached=True, busy=False,
          items=1, first="night-city",
      )
      assert len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      ) == motion_calls_after_search

      # Genre browsing uses the site's real page family, retains every one of
      # the 36 fixture cards, and caches each page independently. Search mode
      # remains deliberately unpaged.
      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 1")
      wait_motion(
          action="search", cached=False, busy=False, mode="genre", page=1,
          previous=False, next=True, items=36, first="nature-1",
      )
      motion_calls_after_genre = len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      )
      set_motion_mode("deny")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 1")
      wait_motion(
          action="search", cached=True, busy=False, mode="genre", page=1,
          previous=False, next=True, items=36, first="nature-1",
      )
      assert len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      ) == motion_calls_after_genre

      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 2")
      wait_motion(
          action="search", cached=False, busy=False, mode="genre", page=2,
          previous=True, next=False, items=1, first="nature-page-two",
      )
      motion_calls_after_page_two = len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      )
      noctalia_msg("plugin ${serviceId} all vm-motion-hd-page-two")
      wait_motion(action="search", error_kind="invalid-browse", busy=False)
      assert len(
          machine.succeed("cat /tmp/wall-in-one-vm-motion-calls.log").splitlines()
      ) == motion_calls_after_page_two

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

      # Reading Noctalia's public wallpaper-get path remains independent of
      # the dynamic executable backends. The copy is an export only and does
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

      # The staged VM config opts into an absolute export directory from boot.
      # No implicit plugin-data fallback is exercised: the explicit directory
      # exists before any capture or media-library work begins.

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
      wait_direct(
          wallhaven=True,
          w_command=True,
          w_available=True,
          w_apply=True,
          mpv_command=True,
          mpv_available=True,
          mpv_apply=True,
          left="native_previous",
          right="native_random",
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 5 and (.pairings | type) == \"object\" "
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

      # Render the full-size routed Wall-in-One hub after the direct backend,
      # capture, shop, and persistence matrix. Prove panel IPC remains alive
      # and opening the panel changes the composed output.
      panel_baseline = "/tmp/noctalia-wall-in-one-vm-before-panel.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} ${lib.getExe pkgs.grim} -o HEADLESS-1 {panel_baseline}"
      )
      assert noctalia_msg("panel-toggle ${pluginId}:hub").strip().startswith("ok")
      wait_log('panel manager: opened "${pluginId}:hub"')
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

      # Exercise both real provider panes against a deterministic offline
      # thumbnail transport. A cache entry alone is insufficient: the captured
      # pane must contain the fixture's unique color, proving that ui.image
      # replaced the glyph fallback after async completion.
      preview_cache = "${pluginDataRoot}/provider-previews/v1"
      preview_manifest = preview_cache + "/manifest.json"
      thumbnail_log = "/tmp/wall-in-one-vm-thumbnail-calls.log"
      thumbnail_mode = "/tmp/wall-in-one-vm-thumbnail-mode"
      preview_probe_number = [0]

      def render_provider_preview(provider: str):
          preview_probe_number[0] += 1
          token = f"preview-{preview_probe_number[0]}"
          assert noctalia_msg(
              f"plugin ${pluginId}:hub all vm-provider-preview {provider}:{token}"
          ).strip() == "ok: dispatched 1"
          wait_log(f"WALL_IN_ONE_VM_PROVIDER_PREVIEW {provider} token={token}")

      def wait_preview_entry(key: str, provider: str, url: str) -> str:
          predicate = (
              f'.schema == 1 and .entries[{json.dumps(key)}].provider == '
              f'{json.dumps(provider)} and .entries[{json.dumps(key)}].url == '
              f'{json.dumps(url)} and .entries[{json.dumps(key)}].bytes > 0 and '
              f'(.entries[{json.dumps(key)}].filename | type) == "string"'
          )
          machine.wait_until_succeeds(
              "${lib.getExe pkgs.jq} -e "
              + shlex.quote(predicate)
              + " "
              + shlex.quote(preview_manifest)
          )
          filename = machine.succeed(
              "${lib.getExe pkgs.jq} -r "
              + shlex.quote(f'.entries[{json.dumps(key)}].filename')
              + " "
              + shlex.quote(preview_manifest)
          ).strip()
          assert filename and "/" not in filename and "\\" not in filename, filename
          cached = preview_cache + "/" + filename
          machine.succeed(
              "test -s "
              + shlex.quote(cached)
              + " && ${pkgs.imagemagick}/bin/magick identify "
              + shlex.quote(cached)
          )
          return cached

      def wait_preview_color(path: str, color: str):
          machine.wait_until_succeeds(
              "rm -f "
              + shlex.quote(path)
              + " && runuser -u ${testUser} -- env -i "
              + ipc_environment
              + " ${lib.getExe pkgs.grim} -o HEADLESS-1 "
              + shlex.quote(path)
              + " && ${pkgs.imagemagick}/bin/magick "
              + shlex.quote(path)
              + " -format %c histogram:info:- | grep -Fqi -- "
              + shlex.quote(color)
          )

      machine.fail("test -e " + shlex.quote(thumbnail_log))
      machine.succeed("printf '%s\\n' good > " + shlex.quote(thumbnail_mode))

      render_provider_preview("motionbgs")
      motion_preview = wait_preview_entry(
          "motionbgs:night-city",
          "motionbgs",
          "https://motionbgs.com/i/c/364x205/media/4242/night-city.3840x2160.jpg",
      )
      machine.succeed(
          "cmp -s "
          + shlex.quote(motion_preview)
          + " ${fixtureMotionBgsThumbnail}"
      )
      wait_preview_color(
          "/tmp/noctalia-wall-in-one-vm-motion-preview.png",
          "#12D6C5",
      )
      assert len(machine.succeed("cat " + shlex.quote(thumbnail_log)).splitlines()) == 1

      # A second render under a helper that rejects every cache miss must stay
      # on the local entry and leave the transport call count unchanged.
      machine.succeed("printf '%s\\n' deny > " + shlex.quote(thumbnail_mode))
      render_provider_preview("motionbgs")
      assert len(machine.succeed("cat " + shlex.quote(thumbnail_log)).splitlines()) == 1
      wait_preview_color(
          "/tmp/noctalia-wall-in-one-vm-motion-cache-hit.png",
          "#12D6C5",
      )

      machine.succeed("printf '%s\\n' good > " + shlex.quote(thumbnail_mode))
      render_provider_preview("wallhaven")
      wallhaven_preview = wait_preview_entry(
          "wallhaven:abc123",
          "wallhaven",
          "https://th.wallhaven.cc/lg/ab/abc123.jpg",
      )
      machine.succeed(
          "cmp -s "
          + shlex.quote(wallhaven_preview)
          + " ${fixtureWallhavenThumbnail}"
      )
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          + shlex.quote('.schema == 1 and (.entries | length) == 2')
          + " "
          + shlex.quote(preview_manifest)
      )
      wait_preview_color(
          "/tmp/noctalia-wall-in-one-vm-wallhaven-preview.png",
          "#F51166",
      )

      thumbnail_calls = [
          line.split("\t")
          for line in machine.succeed("cat " + shlex.quote(thumbnail_log)).splitlines()
      ]
      assert [call[:3] for call in thumbnail_calls] == [
          ["fetch", "motionbgs", "https://motionbgs.com/i/c/364x205/media/4242/night-city.3840x2160.jpg"],
          ["fetch", "wallhaven", "https://th.wallhaven.cc/lg/ab/abc123.jpg"],
      ], thumbnail_calls

      machine.succeed("printf '%s\\n' deny > " + shlex.quote(thumbnail_mode))
      for provider in ("wallhaven", "motionbgs"):
          render_provider_preview(provider)
      assert len(machine.succeed("cat " + shlex.quote(thumbnail_log)).splitlines()) == 2
      machine.fail(
          "find "
          + shlex.quote(preview_cache)
          + " -maxdepth 1 -type f "
          + "\\( -name '*.stage' -o -name 'manifest.json.tmp' "
          + "-o -name '.wall-in-one-thumbnail.*' \\) | grep -q ."
      )
      assert noctalia_msg(
          "plugin ${pluginId}:hub all vm-provider-preview-reset"
      ).strip() == "ok: dispatched 1"
      wait_log("WALL_IN_ONE_VM_PROVIDER_PREVIEW reset")

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
          "call to 'async command callback' failed",
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
