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
  backendServiceId = "${pluginId}:backend";
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
  motionManagedRoot = "${videoRoot}/Wall-in-One/MotionBGS";

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

  rawPluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = lib.fileset.unions [
      (pluginRoot + "/wall-in-one")
      # Separately installed, but the guest still needs it on disk.
      (pluginRoot + "/wall-in-one-backend")
      # The offline contract asserts repository-root documentation parity.
      (pluginRoot + "/README.md")
      (pluginRoot + "/CHANGELOG.md")
    ];
  };
  stagedSource = pkgs.runCommand "noctalia-wall-in-one-vm-source" { } ''
    mkdir -p "$out/wall-in-one" "$out/wall-in-one-backend"
    cp -R ${rawPluginSource}/wall-in-one/. "$out/wall-in-one/"
    # The unified backend is installed separately from the plugin, but its
    # self-tests and offline contract still run from the staged guest tree.
    cp -R ${rawPluginSource}/wall-in-one-backend/. "$out/wall-in-one-backend/"
    cp ${rawPluginSource}/README.md ${rawPluginSource}/CHANGELOG.md "$out/"
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

  # The plugin keeps both production launchers. This separately configured
  # unified executable delegates generic, local-only library RPC to the real
  # Python backend while returning pinned MotionBGS records offline.
  fakeUnifiedBackend = pkgs.writeShellApplication {
    name = "wall-in-one-backend";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.python3
    ];
    text = ''
      umask 077

      readonly calls=/tmp/wall-in-one-vm-motion-calls.log
      readonly transports=/tmp/wall-in-one-vm-motion-transports.log
      readonly guard_wire=WIO-MBGS-GUARD1
      response=""
      request_id=""
      action=""
      cache_directory=""
      cache_file=""
      guard=""

      guard_ready() {
        local value owner size
        [[ -f $guard && ! -L $guard ]] || return 1
        owner=$(stat -c %u -- "$guard") || return 1
        size=$(stat -c %s -- "$guard") || return 1
        [[ $owner == "$(id -u)" && $size == 16 ]] || return 1
        IFS= read -r value < "$guard" || return 1
        [[ $value == "$guard_wire" ]]
      }

      protocol_error() {
        local wire=$1
        local kind=$2
        local detail=$3
        local code=''${4:-70}
        printf '%s\terror\t%s\t%s\n' "$wire" "$kind" "$detail"
        exit "$code"
      }

      install_response() {
        local payload=$1
        local temporary bytes
        guard_ready || protocol_error WIO-MBGS-RPC1 cancelled 'fixture cancellation guard is absent' 75
        [[ ! -e $response && ! -L $response ]] || \
          protocol_error WIO-MBGS-RPC1 conflict 'fixture response path already exists' 73
        temporary=$(mktemp -- "$response.fixture.XXXXXX") || \
          protocol_error WIO-MBGS-RPC1 local-io 'fixture could not stage its response' 73
        printf '%s\n' "$payload" > "$temporary"
        bytes=$(stat -c %s -- "$temporary")
        if (( bytes < 2 || bytes > 131072 )); then
          rm -f -- "$temporary"
          protocol_error WIO-MBGS-RPC1 response-size 'fixture response exceeded its bound'
        fi
        if ! ln -- "$temporary" "$response"; then
          rm -f -- "$temporary"
          protocol_error WIO-MBGS-RPC1 conflict 'fixture response install was not no-replace' 73
        fi
        rm -f -- "$temporary"
        guard_ready || {
          rm -f -- "$response"
          protocol_error WIO-MBGS-RPC1 cancelled 'fixture cancellation guard changed before completion' 75
        }
        printf 'WIO-MBGS-RPC1\tok\t%s\t%s\t%s\n' \
          "$request_id" "$response" "$bytes"
      }

      failure_response() {
        local kind=$1
        local message=$2
        local payload
        payload=$(jq -cn \
          --arg action "$action" \
          --arg request_id "$request_id" \
          --arg kind "$kind" \
          --arg message "$message" \
          '{schema:1,ok:false,action:$action,request_id:$request_id,error:{kind:$kind,message:$message}}')
        install_response "$payload"
        exit 0
      }

      detail_record() {
        jq -cn '{
          slug:"night-city",
          id:"4242",
          title:"Night City",
          source_url:"https://motionbgs.com/night-city",
          preview_url:"https://motionbgs.com/media/4242/preview.mp4",
          poster_url:"https://motionbgs.com/media/4242/poster.jpg",
          duration:"00:30",
          fetched_at:1767225600,
          downloads:{
            hd:{id:"4242",quality:"hd",resolution:"1920x1080",advertised_size_mb:3.5,url:"https://motionbgs.com/dl/hd/4242/"},
            "4k":{id:"4242",quality:"4k",resolution:"3840x2160",advertised_size_mb:9,url:"https://motionbgs.com/dl/4k/4242/"}
          }
        }'
      }

      valid_cache_file() {
        [[ -f $cache_file && ! -L $cache_file ]] \
          && jq -e '.schema == 1 and (.searches | type == "object") and (.details | type == "object")' \
            "$cache_file" >/dev/null
      }

      search_is_cached() {
        local key=$1
        valid_cache_file \
          && jq -e --arg key "$key" '.searches[$key] == true' "$cache_file" >/dev/null
      }

      detail_is_cached() {
        local slug=$1
        valid_cache_file \
          && jq -e --arg slug "$slug" '.details[$slug] == true' "$cache_file" >/dev/null
      }

      record_search_cache() {
        local key=$1
        local temporary
        temporary=$(mktemp -- "$cache_directory/.cache-v1.fixture.XXXXXX")
        if valid_cache_file; then
          jq -c --arg key "$key" \
            '.searches[$key] = true | .search_order = (((.search_order // []) + [$key]) | unique)' \
            "$cache_file" > "$temporary"
        else
          jq -cn --arg key "$key" \
            '{schema:1,searches:{($key):true},details:{},search_order:[$key],detail_order:[]}' \
            > "$temporary"
        fi
        mv -f -- "$temporary" "$cache_file"
      }

      record_detail_cache() {
        local slug=$1
        local temporary
        temporary=$(mktemp -- "$cache_directory/.cache-v1.fixture.XXXXXX")
        if valid_cache_file; then
          jq -c --arg slug "$slug" \
            '.details[$slug] = true | .detail_order = (((.detail_order // []) + [$slug]) | unique)' \
            "$cache_file" > "$temporary"
        else
          jq -cn --arg slug "$slug" \
            '{schema:1,searches:{},details:{($slug):true},search_order:[],detail_order:[$slug]}' \
            > "$temporary"
        fi
        mv -f -- "$temporary" "$cache_file"
      }

      mode=$(cat /tmp/wall-in-one-vm-motion-mode 2>/dev/null || printf good)
      case ''${1:-} in
        probe|rpc|self-test)
          exec ${lib.getExe pkgs.python3} \
            ${rawPluginSource}/wall-in-one-backend/wall-in-one-backend "$@"
          ;;
        motionbgs-probe)
          if (( $# != 3 )) || [[ $2 != --protocol || $3 != 1 ]]; then
            protocol_error WIO-MBGS-PROBE1 usage 'fixture probe expects --protocol 1' 64
          fi
          printf 'probe\t1\n' >> "$calls"
          printf 'WIO-MBGS-PROBE1\tok\t1\t1.0.0-fixture\tsearch,details,download,clear\n'
          ;;
        motionbgs-rpc)
          if (( $# != 9 )) \
            || [[ $2 != --protocol || $3 != 1 || $4 != --request || $6 != --response || $8 != --guard ]]; then
            protocol_error WIO-MBGS-RPC1 usage \
              'fixture rpc expects --protocol 1 --request ABS --response ABS --guard ABS' 64
          fi
          request=$5
          response=$7
          guard=$9
          [[ -f $request && ! -L $request ]] || \
            protocol_error WIO-MBGS-RPC1 invalid-request 'fixture request is not a regular file' 64
          request_bytes=$(stat -c %s -- "$request")
          (( request_bytes >= 2 && request_bytes <= 8192 )) || \
            protocol_error WIO-MBGS-RPC1 invalid-request 'fixture request exceeded 8 KiB' 64
          if ! request_id=$(jq -er '.request_id | select(type == "string")' "$request") \
            || ! action=$(jq -er '.action | select(type == "string")' "$request") \
            || ! cache_directory=$(jq -er '.cache_directory | select(type == "string" and startswith("/"))' "$request") \
            || ! request_guard=$(jq -er '.guard_path | select(type == "string" and startswith("/"))' "$request") \
            || ! operation_timeout_ms=$(jq -er '.operation_timeout_ms | select(type == "number")' "$request") \
            || ! jq -e '.schema == 1 and (.cache_ttl_seconds | type == "number")' "$request" >/dev/null; then
            protocol_error WIO-MBGS-RPC1 invalid-request 'fixture request envelope was invalid' 64
          fi
          [[ $request_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || \
            protocol_error WIO-MBGS-RPC1 invalid-request 'fixture request id was invalid' 64
          [[ -d $cache_directory && ! -L $cache_directory ]] || \
            protocol_error WIO-MBGS-RPC1 invalid-request 'fixture cache directory was invalid' 64
          [[ $request_guard == "$guard" && ''${guard%/*} == "''${response%/*}" ]] || \
            protocol_error WIO-MBGS-RPC1 invalid-path 'fixture cancellation guard did not match the envelope' 64
          if [[ $action == download ]]; then
            [[ $operation_timeout_ms == 75000 ]] || \
              protocol_error WIO-MBGS-RPC1 invalid-request 'fixture download deadline was invalid' 64
          else
            [[ $operation_timeout_ms == 30000 ]] || \
              protocol_error WIO-MBGS-RPC1 invalid-request 'fixture RPC deadline was invalid' 64
          fi
          guard_ready || protocol_error WIO-MBGS-RPC1 cancelled 'fixture cancellation guard is absent' 75
          cache_file="$cache_directory/cache-v1.json"
          printf 'rpc\t%s\t%s\t%s\t%s\t%s\n' \
            "$request_id" "$action" "$request" "$response" "$guard" >> "$calls"

          case $action in
            search)
              if ! browse_mode=$(jq -er '.mode | select(type == "string")' "$request") \
                || ! query=$(jq -er '.query | select(type == "string")' "$request") \
                || ! genre=$(jq -er '.genre | select(type == "string")' "$request") \
                || ! page=$(jq -er '.page | select(type == "number" and . >= 1 and . == floor)' "$request") \
                || ! limit=$(jq -er '.limit | select(type == "number" and . >= 1 and . <= 48 and . == floor)' "$request") \
                || ! force=$(jq -er '.force | select(type == "boolean") | tostring' "$request"); then
                failure_response protocol 'fixture search request omitted or malformed a required bridge field'
              fi
              cache_key=$(printf '%s\t%s\t%s\t%s\t%s' "$browse_mode" "$query" "$genre" "$page" "$limit" \
                | sha256sum | cut -d' ' -f1)
              cached=false
              if [[ $force != true ]] && search_is_cached "$cache_key"; then
                cached=true
              else
                printf 'search\t%s\t%s\n' "$cache_key" "$mode" >> "$transports"
                case $mode in
                  good) ;;
                  challenge) failure_response challenge 'pinned provider challenge fixture' ;;
                  markup) failure_response site-markup 'pinned changed-markup fixture' ;;
                  cross-origin) failure_response protocol 'pinned cross-origin fixture' ;;
                  deny) failure_response fixture-deny 'cache miss unexpectedly reached provider transport' ;;
                  *) failure_response fixture-mode 'unknown MotionBGS fixture mode' ;;
                esac
                record_search_cache "$cache_key"
              fi

              previous=false
              next=false
              pageable=false
              total_hint=0
              case $browse_mode in
                search)
                  source_url=https://motionbgs.com/tag:night-city
                  items=$(jq -cn '[{
                    slug:"night-city",id:"4242",title:"Night City",quality:"4K",
                    source_url:"https://motionbgs.com/night-city",
                    thumbnail_url:"https://motionbgs.com/i/c/364x205/media/4242/night-city.3840x2160.jpg"
                  }]')
                  total_hint=1
                  ;;
                genre)
                  pageable=true
                  if (( page == 1 )); then
                    source_url=https://motionbgs.com/tag:nature/
                    next=true
                    total_hint=610
                    items=$(jq -cn '[range(1; 37) as $index | {
                      slug:("nature-" + ($index | tostring)),
                      id:($index | tostring),
                      title:("Nature " + ($index | tostring)),
                      quality:"4K",
                      source_url:("https://motionbgs.com/nature-" + ($index | tostring)),
                      thumbnail_url:("https://motionbgs.com/i/c/364x205/media/" + ($index | tostring) + "/nature-" + ($index | tostring) + ".3840x2160.jpg")
                    }]')
                  else
                    source_url="https://motionbgs.com/tag:nature/$page/"
                    previous=true
                    total_hint=600
                    items=$(jq -cn '[{
                      slug:"nature-page-two",id:"9999",title:"Nature Page Two",quality:"HD",
                      source_url:"https://motionbgs.com/nature-page-two",
                      thumbnail_url:"https://motionbgs.com/i/c/364x205/media/9999/nature-page-two.1920x1080.jpg"
                    }]')
                  fi
                  ;;
                latest)
                  pageable=true
                  source_url=https://motionbgs.com/
                  items='[]'
                  ;;
                4k)
                  pageable=true
                  source_url=https://motionbgs.com/4k
                  items='[]'
                  ;;
                hd)
                  source_url=https://motionbgs.com/hd
                  items='[]'
                  ;;
                *) failure_response protocol 'fixture received an unsupported browse mode' ;;
              esac
              payload=$(jq -cn \
                --arg action "$action" \
                --arg request_id "$request_id" \
                --arg mode "$browse_mode" \
                --arg query "$query" \
                --arg genre "$genre" \
                --arg source_url "$source_url" \
                --argjson cached "$cached" \
                --argjson fetched_at 1767225600 \
                --argjson items "$items" \
                --argjson page "$page" \
                --argjson previous "$previous" \
                --argjson next "$next" \
                --argjson pageable "$pageable" \
                --argjson total_hint "$total_hint" \
                '{schema:1,ok:true,action:$action,request_id:$request_id,
                  mode:$mode,query:$query,genre:$genre,page:$page,cached:$cached,
                  source_url:$source_url,fetched_at:$fetched_at,items:$items,
                  meta:{current_page:$page,has_previous:$previous,has_next:$next,
                    pageable:$pageable,total_hint:$total_hint}}')
              install_response "$payload"
              ;;
            details)
              if ! slug=$(jq -er '.slug | select(type == "string")' "$request") \
                || ! force=$(jq -er '.force | select(type == "boolean") | tostring' "$request"); then
                failure_response protocol 'fixture details request omitted or malformed a required bridge field'
              fi
              [[ $slug == night-city ]] || failure_response site-markup 'fixture detail slug was not pinned'
              cached=false
              if [[ $force != true ]] && detail_is_cached "$slug"; then
                cached=true
              else
                printf 'details\t%s\t%s\n' "$slug" "$mode" >> "$transports"
                [[ $mode == good ]] || failure_response fixture-deny 'detail transport was denied by fixture mode'
                record_detail_cache "$slug"
              fi
              selected=$(detail_record)
              payload=$(jq -cn \
                --arg action "$action" \
                --arg request_id "$request_id" \
                --argjson cached "$cached" \
                --argjson selected "$selected" \
                '{schema:1,ok:true,action:$action,request_id:$request_id,cached:$cached,
                  source_url:$selected.source_url,fetched_at:$selected.fetched_at,selected:$selected}')
              install_response "$payload"
              ;;
            download)
              if ! slug=$(jq -er '.slug | select(type == "string")' "$request") \
                || ! quality=$(jq -er '.quality | select(. == "hd" or . == "4k")' "$request") \
                || ! download_directory=$(jq -er '.download_directory | select(type == "string" and startswith("/"))' "$request") \
                || ! managed_marker=$(jq -er '.managed_marker_path | select(type == "string" and startswith("/"))' "$request") \
                || ! max_download_bytes=$(jq -er '.max_download_bytes | select(type == "number" and . >= 1 and . == floor)' "$request") \
                || ! jq -e '.download_timeout_seconds | type == "number" and . == 50' "$request" >/dev/null \
                || ! jq -e '.force | type == "boolean"' "$request" >/dev/null; then
                failure_response protocol 'fixture download request omitted or malformed a required bridge field'
              fi
              [[ $slug == night-city && -d $download_directory && -f $managed_marker ]] || \
                failure_response configuration 'fixture download request was not pinned or managed'
              printf 'download\t%s\t%s\t%s\n' "$slug" "$quality" "$mode" >> "$transports"
              [[ $mode == good ]] || failure_response fixture-deny 'download transport was denied by fixture mode'
              destination="$download_directory/$slug.$quality.mp4"
              sidecar="$destination.motionbgs.json"
              [[ ! -e $destination && ! -L $destination && ! -e $sidecar && ! -L $sidecar ]] || \
                failure_response conflict 'fixture download destination already exists'
              media_temporary=$(mktemp -- "$download_directory/.fixture-media.XXXXXX")
              sidecar_temporary=$(mktemp -- "$download_directory/.fixture-sidecar.XXXXXX")
              cp -- "${fixtureVideo}" "$media_temporary"
              bytes=$(stat -c %s -- "$media_temporary")
              digest=$(sha256sum -- "$media_temporary" | cut -d' ' -f1)
              if (( bytes < 1 || bytes > max_download_bytes )); then
                rm -f -- "$media_temporary" "$sidecar_temporary"
                failure_response download-size 'fixture video exceeded the configured download bound'
              fi
              download_url="https://motionbgs.com/dl/$quality/4242/"
              sidecar_payload=$(jq -cn \
                --arg path "$destination" \
                --arg quality "$quality" \
                --arg download_url "$download_url" \
                --arg digest "$digest" \
                --argjson bytes "$bytes" \
                '{schema:1,plugin:"goober/wall-in-one",provider:"MotionBGS",path:$path,
                  title:"Night City",source_page:"https://motionbgs.com/night-city",
                  download_url:$download_url,quality:$quality,content_type:"video/mp4",
                  bytes:$bytes,sha256:$digest,downloaded_at:"2026-01-01T00:00:00Z"}')
              printf '%s\n' "$sidecar_payload" > "$sidecar_temporary"
              if ! ln -- "$media_temporary" "$destination"; then
                rm -f -- "$media_temporary" "$sidecar_temporary"
                failure_response conflict 'fixture media install was not no-replace'
              fi
              if ! ln -- "$sidecar_temporary" "$sidecar"; then
                rm -f -- "$destination" "$media_temporary" "$sidecar_temporary"
                failure_response conflict 'fixture sidecar install was not no-replace'
              fi
              rm -f -- "$media_temporary" "$sidecar_temporary"
              record_detail_cache "$slug"
              selected=$(detail_record)
              download=$(jq -cn \
                --arg path "$destination" \
                --arg sidecar "$sidecar" \
                --arg slug "$slug" \
                --arg quality "$quality" \
                --arg download_url "$download_url" \
                --arg digest "$digest" \
                --argjson bytes "$bytes" \
                '{path:$path,sidecar:$sidecar,slug:$slug,title:"Night City",quality:$quality,
                  bytes:$bytes,source_url:"https://motionbgs.com/night-city",
                  download_url:$download_url,content_type:"video/mp4",sha256:$digest,
                  downloaded_at:"2026-01-01T00:00:00Z"}')
              payload=$(jq -cn \
                --arg action "$action" \
                --arg request_id "$request_id" \
                --argjson selected "$selected" \
                --argjson download "$download" \
                '{schema:1,ok:true,action:$action,request_id:$request_id,cached:false,
                  source_url:$selected.source_url,fetched_at:$selected.fetched_at,
                  selected:$selected,download:$download}')
              install_response "$payload"
              ;;
            clear)
              cache_temporary=$(mktemp -- "$cache_directory/.cache-v1.fixture.XXXXXX")
              jq -cn '{schema:1,searches:{},details:{},search_order:[],detail_order:[]}' \
                > "$cache_temporary"
              guard_ready || {
                rm -f -- "$cache_temporary"
                protocol_error WIO-MBGS-RPC1 cancelled 'fixture cancellation guard changed before clear' 75
              }
              mv -f -- "$cache_temporary" "$cache_file"
              guard_ready || protocol_error WIO-MBGS-RPC1 cancelled \
                'fixture cancellation guard changed after clear' 75
              payload=$(jq -cn \
                --arg action "$action" \
                --arg request_id "$request_id" \
                '{schema:1,ok:true,action:$action,request_id:$request_id,cleared:true}')
              install_response "$payload"
              ;;
            *) failure_response unsupported-action 'fixture received an unsupported action' ;;
          esac
          ;;
        *)
          protocol_error WIO-MBGS-RPC1 usage \
            'fixture expected a generic backend or motionbgs-* command' 64
          ;;
      esac
    '';
  };

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
        if [[ $provider == motionbgs \
          && $url =~ ^https://motionbgs\.com/i/c/364x205/media/([0-9]+)/nature-([0-9]+)\.3840x2160\.jpg$ ]]; then
          media_id=$((10#''${BASH_REMATCH[1]}))
          nature_id=$((10#''${BASH_REMATCH[2]}))
          if (( nature_id >= 1 && nature_id <= 36 && media_id == 5000 + nature_id )); then
            source=${fixtureMotionBgsThumbnail}
          else
            printf 'WIO-THUMB1\terror\tfixture-url\t0\tunexpected provider thumbnail URL\n'
            exit 64
          fi
        else
          printf 'WIO-THUMB1\terror\tfixture-url\t0\tunexpected provider thumbnail URL\n'
          exit 64
        fi
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
    local vmDefaultPlaylistId = ""
    local vmReplacementEntryId = ""
    local vmReplacementAddedAt = ""
    local vmReplacementOldPairingId = ""
    local vmAdaptivePairingId = ""
    local vmVideoPairingId = ""
    local vmScheduleUpperPlaylistId = ""
    local vmScheduleLowerPlaylistId = ""
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

    local function vmPairingId(kind, source)
        local selected = ""
        for id, pairing in pairs(config.pairings) do
            local media = type(pairing) == "table" and type(pairing.media) == "table"
                    and pairing.media
                or nil
            local still = type(pairing) == "table" and type(pairing.still) == "table"
                    and pairing.still
                or {}
            local matches = if kind == "static"
                then media == nil and tostring(still.path or "") == source
                else media ~= nil
                    and tostring(media.kind or "") == kind
                    and tostring(media.source or "") == source
            if matches and (selected == "" or tostring(id) < selected) then
                selected = tostring(id)
            end
        end
        return selected
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
                    .. " palette_community=" .. tostring(
                        type(paletteStatus) == "table"
                            and type(paletteStatus.counts) == "table"
                            and paletteStatus.counts.community
                            or 0
                    )
                    .. " palette_cache_source=" .. tostring(
                        type(paletteStatus) == "table"
                            and type(paletteStatus.cache) == "table"
                            and paletteStatus.cache.source
                            or ""
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
        elseif event == "vm-cycle-create-schedule-upper" then
            vmScheduleUpperPlaylistId = wallInOne.createPlaylist(
                "VM schedule upper",
                nil,
                false
            ) or ""
        elseif event == "vm-cycle-create-schedule-lower" then
            vmScheduleLowerPlaylistId = wallInOne.createPlaylist(
                "VM schedule lower",
                nil,
                false
            ) or ""
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
                -- Keep manual transition assertions deterministic. The VM
                -- deliberately exercises several slow renderer/capture paths;
                -- a one-minute timer can advance the playlist underneath a
                -- later assertion without testing anything about rotation.
                interval_seconds = 900,
                order = "rotate",
            })
        elseif event == "vm-cycle-assign" then
            vmHandle({
                kind = "playlist_assign",
                output = "HEADLESS-1",
                playlist_id = vmPlaylistId,
            })
        elseif event == "vm-cycle-schedule-upper" then
            vmHandle({
                kind = "schedule_save",
                output = "HEADLESS-1",
                before_id = "vm-schedule-lower",
                schedule = {
                    id = "vm-schedule-upper",
                    name = "VM overnight upper",
                    playlist = vmScheduleUpperPlaylistId,
                    enabled = true,
                    weekdays = { 0, 1, 2, 3, 4, 5, 6 },
                    months = { vmScheduleMonth },
                    start_minute = 1080,
                    end_minute = 360,
                    all_day = false,
                },
            })
        elseif event == "vm-cycle-schedule-lower" then
            local currentMonth = math.max(1, math.min(12, tonumber(noctalia.formatTime("%m")) or 1))
            vmScheduleMonth = (currentMonth % 12) + 1
            vmHandle({
                kind = "schedule_save",
                output = "HEADLESS-1",
                schedule = {
                    id = "vm-schedule-lower",
                    name = "VM overnight lower",
                    playlist = vmScheduleLowerPlaylistId,
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
            local missPlaylist = if type(missed) == "table"
                then tostring(missed.playlist or "")
                else tostring(outputConfig.fallback_playlist or "")
            noctalia.log(
                "WALL_IN_ONE_VM_SCHEDULE "
                    .. tostring(payload or "")
                    .. " month=" .. tostring(vmScheduleMonth)
                    .. " winner=" .. tostring(type(winner) == "table" and winner.id or "")
                    .. " winner_is_lower=" .. tostring(
                        type(winner) == "table"
                            and tostring(winner.playlist or "") == vmScheduleLowerPlaylistId
                    )
                    .. " distinct=" .. tostring(
                        vmPlaylistId ~= ""
                            and vmScheduleUpperPlaylistId ~= ""
                            and vmScheduleLowerPlaylistId ~= ""
                            and vmPlaylistId ~= vmScheduleUpperPlaylistId
                            and vmPlaylistId ~= vmScheduleLowerPlaylistId
                            and vmScheduleUpperPlaylistId ~= vmScheduleLowerPlaylistId
                    )
                    .. " miss=" .. tostring(missed == nil)
                    .. " miss_uses_fallback=" .. tostring(
                        missed == nil
                            and missPlaylist == tostring(outputConfig.fallback_playlist or "")
                            and missPlaylist == vmPlaylistId
                    )
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
        elseif event == "vm-default-profile-create" then
            if vmDefaultPlaylistId == "" then
                vmDefaultPlaylistId = wallInOne.createPlaylist(
                    "VM default identity",
                    "HEADLESS-1",
                    false
                ) or ""
            end
            vmHandle({
                kind = "playlist_add_entry",
                output = "HEADLESS-1",
                playlist_id = vmDefaultPlaylistId,
                entry = {
                    id = "vm-default-first",
                    label = "VM default first",
                    media = { kind = "video", source = "${fixtureVideo}" },
                    still = { mode = "selected", path = "${fixtureVideoStill}" },
                    theme = { mode = "auto", source = "wallpaper", selection = "m3-content" },
                    customized = false,
                    added_at = "2026-08-03 00:00:00",
                },
            })
        elseif event == "vm-default-profile-refresh" then
            vmHandle({
                kind = "playlist_add_entry",
                output = "HEADLESS-1",
                playlist_id = vmDefaultPlaylistId,
                entry = {
                    id = "vm-default-second",
                    label = "VM default refreshed",
                    media = { kind = "video", source = "${fixtureVideo}" },
                    still = { mode = "selected", path = "${fixtureVideoStill}" },
                    theme = { mode = "auto", source = "wallpaper", selection = "m3-rainbow" },
                    customized = false,
                    added_at = "2026-08-03 00:01:00",
                },
            })
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
            vmAdaptivePairingId = vmPairingId("static", "${fixtureStill}")
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
            vmVideoPairingId = vmPairingId("video", "${fixtureVideo}")
        elseif event == "vm-pairing-add-adaptive" then
            vmHandle({
                kind = "playlist_add_pairing",
                output = "HEADLESS-1",
                playlist_id = vmPairingPlaylistId,
                pairing_id = vmAdaptivePairingId,
                before_id = "",
            })
        elseif event == "vm-pairing-add-video" then
            vmHandle({
                kind = "playlist_add_pairing",
                output = "HEADLESS-1",
                playlist_id = vmPairingPlaylistId,
                pairing_id = vmVideoPairingId,
                before_id = "",
            })
        elseif event == "vm-pairing-save-update" then
            vmHandle({
                kind = "pairing_save",
                pairing = {
                    id = vmAdaptivePairingId,
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
                if entry.pairing_id == vmAdaptivePairingId then
                    adaptiveId = entry.id
                elseif entry.pairing_id == vmVideoPairingId then
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
        elseif event == "vm-pairing-reset" then
            vmHandle({
                kind = "pairing_reset",
                pairing = {
                    id = vmAdaptivePairingId,
                    label = "VM adaptive still reset",
                    media = nil,
                    still = { mode = "selected", path = "${fixtureStill}" },
                    theme = { mode = "auto", source = "wallpaper", selection = "m3-rainbow" },
                    added_at = "2026-08-02 00:00:00",
                },
            })
        elseif event == "vm-playlist-entry-replace" then
            local playlist = config.playlists[vmPairingPlaylistId]
            local previous = type(playlist) == "table" and playlist.entries[1] or nil
            if type(previous) == "table" then
                vmReplacementEntryId = tostring(previous.id or "")
                vmReplacementAddedAt = tostring(previous.added_at or "")
                vmReplacementOldPairingId = tostring(previous.pairing_id or "")
                vmHandle({
                    kind = "playlist_replace_entry",
                    playlist_id = vmPairingPlaylistId,
                    entry_id = vmReplacementEntryId,
                    entry = {
                        id = vmReplacementEntryId,
                        label = "VM graphical Workshop replacement",
                        media = { kind = "workshop", source = "431960001" },
                        still = { mode = "selected", path = "${fixtureWorkshopStill}" },
                        theme = { mode = "dark", source = "builtin", selection = "Nord" },
                        added_at = "must-not-replace-the-occurrence-timestamp",
                    },
                })
            end
        elseif event == "vm-playlist-entry-replace-probe" then
            local playlist = config.playlists[vmPairingPlaylistId]
            local current = type(playlist) == "table" and playlist.entries[1] or nil
            local currentPairing = type(current) == "table"
                    and config.pairings[tostring(current.pairing_id or "")]
                or nil
            local oldPairing = config.pairings[vmReplacementOldPairingId]
            noctalia.log(
                "WALL_IN_ONE_VM_ENTRY_REPLACE "
                    .. tostring(payload or "")
                    .. " preserved_id=" .. tostring(
                        type(current) == "table" and current.id == vmReplacementEntryId
                    )
                    .. " preserved_time=" .. tostring(
                        type(current) == "table" and current.added_at == vmReplacementAddedAt
                    )
                    .. " rebound=" .. tostring(
                        type(current) == "table"
                            and tostring(current.pairing_id or "") ~= ""
                            and tostring(current.pairing_id or "") ~= vmReplacementOldPairingId
                    )
                    .. " workshop=" .. tostring(
                        type(current) == "table"
                            and type(current.media) == "table"
                            and current.media.kind == "workshop"
                            and current.media.source == "431960001"
                    )
                    .. " customized=" .. tostring(
                        type(currentPairing) == "table" and currentPairing.customized == true
                    )
                    .. " old_intact=" .. tostring(
                        type(oldPairing) == "table"
                            and type(oldPairing.media) == "table"
                            and oldPairing.media.kind == "video"
                            and oldPairing.media.source == "${fixtureVideo}"
                    )
            )
        elseif event == "vm-palette-preview" then
            vmHandle({
                kind = "palette_preview",
                key = "vm-adaptive-preview",
                pairing_id = vmAdaptivePairingId,
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
        elseif event == "vm-backend-probe" then
            noctalia.log(
                "WALL_IN_ONE_VM_BACKEND "
                    .. tostring(payload or "")
                    .. " ready=" .. tostring(type(backendStatus) == "table" and backendStatus.ready == true)
                    .. " available=" .. tostring(
                        type(backendStatus) == "table" and backendStatus.available == true
                    )
                    .. " busy=" .. tostring(type(backendStatus) == "table" and backendStatus.busy == true)
                    .. " compatible=" .. tostring(
                        type(backendStatus) == "table" and backendStatus.binary_compatible == true
                    )
                    .. " version=" .. tostring(
                        type(backendStatus) == "table" and backendStatus.binary_version or ""
                    )
            )
        elseif event == "vm-library-refresh" then
            local accepted = wallInOne.refreshLibrary()
            noctalia.log(
                "WALL_IN_ONE_VM_LIBRARY_REFRESH "
                    .. tostring(payload or "")
                    .. " accepted=" .. tostring(accepted == true)
                    .. " scanning=" .. tostring(library.scanning == true)
                    .. " backend_available=" .. tostring(
                        type(backendStatus) == "table" and backendStatus.available == true
                    )
                    .. " backend_busy=" .. tostring(
                        type(backendStatus) == "table" and backendStatus.busy == true
                    )
                    .. " nonce_set=" .. tostring((tonumber(libraryScanNonce) or 0) > 0)
            )
        elseif event == "vm-library-probe" then
            local motionManaged = false
            local motionDeletable = false
            local userManaged = false
            local userDeletable = false
            local motionProvider = ""
            local userProvider = ""
            for _, entry in ipairs(type(library.videos) == "table" and library.videos or {}) do
                if type(entry) == "table" and entry.path == "${motionManagedRoot}/night-city.hd.mp4" then
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
                    .. " backend_scan_complete=" .. tostring(
                        (tonumber(libraryScanNonce) or 0) > 0
                            and (tonumber(backendStatus.last_completed_nonce) or 0)
                                >= (tonumber(libraryScanNonce) or 0)
                    )
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
                if type(entry) == "table" and entry.path == "${motionManagedRoot}/night-city.hd.mp4" then
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
                    .. " binary_source=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.binary_source or "")
                    .. " binary_version=" .. tostring(type(motionBgsStatus) == "table" and motionBgsStatus.binary_version or "")
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
            renderNow = panelPages.renderNow,
            onIpc = onIpc,
            update = update,
            frameTick = onFrameTick,
            sustained = false,
            frameTicks = 0,
            renderPasses = 0,
        }

        panelPages.renderNow = function()
            if vmPreview.sustained then
                vmPreview.renderPasses += 1
            end
            if vmPreview.provider == "" then
                vmPreview.renderNow()
                return
            end
            if not isOpen then
                return
            end
            local section = if vmPreview.provider == "wallhaven"
                then panelUi.wallhavenSection()
                else panelUi.motionBgsSection()
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

        update = function()
            vmPreview.update()
            -- update() normally turns frame delivery off once bounded work is
            -- idle. Keep pressure enabled for this probe until its explicit
            -- stop command so the interval cannot collapse after one frame.
            if vmPreview.sustained then
                panel.setNeedsFrameTick(true)
            end
        end

        onFrameTick = function(deltaMs)
            if vmPreview.sustained then
                vmPreview.frameTicks += 1
            end
            vmPreview.frameTick(deltaMs)
            -- The production callback deliberately disables frame delivery
            -- once its bounded drag work settles. Re-arm it only in this VM
            -- pressure probe so an accidental full render on every frame is
            -- observable under the same 36-result route that failed live.
            if vmPreview.sustained then
                panel.setNeedsFrameTick(true)
            end
        end

        onIpc = function(event, payload)
            if event == "vm-library-default-edit" then
                local source = "999999999"
                local entry = {
                    kind = "workshop",
                    source = source,
                    label = "VM Fresh Workshop",
                }
                local existing = panelUi.matchingPairingForLibraryEntry(entry)
                panelUi.openLibraryEntryPairing(entry, {
                    id = "vm-fresh-workshop",
                    preview = "",
                    ownership = "steam",
                })
                noctalia.log(
                    "WALL_IN_ONE_VM_LIBRARY_DEFAULT_EDIT "
                        .. tostring(payload or "")
                        .. " existing=" .. tostring(type(existing) == "table")
                        .. " open=" .. tostring(pairingEditorOpen == true)
                        .. " editor_kind=" .. tostring(pairingEditorKind)
                        .. " media_kind=" .. tostring(entryMediaKindDraft)
                        .. " source=" .. tostring(entryMediaSourceDraft)
                        .. " still=" .. tostring(entryStillModeDraft)
                        .. " id_empty=" .. tostring(editingPairingId == "")
                )
                panelUi.closePairingEditor()
                activePage = "main"
                activeSubpage = ""
                return
            elseif event == "vm-playlist-entry-editor" then
                local playlistId = ""
                local playlistEntryIndex = 0
                local playlistEntry = nil
                for _, candidateId in ipairs(panelUi.sortedPlaylistIds(false)) do
                    local candidate = panelUi.playlistMap()[candidateId]
                    local entries = type(candidate) == "table" and candidate.entries or nil
                    if type(entries) == "table" and type(entries[1]) == "table" then
                        playlistId = candidateId
                        playlistEntryIndex = 1
                        playlistEntry = entries[1]
                        break
                    end
                end

                local opened = false
                local selected = false
                local sourceChanged = false
                local idPreserved = false
                local addedAtPreserved = false
                local positionPreserved = false
                local editorRendered = false
                local sourceChoices = {}
                local sourceTotal = 0
                if playlistId ~= "" and type(playlistEntry) == "table" then
                    local originalId = tostring(playlistEntry.id or "")
                    local originalAddedAt = tostring(playlistEntry.added_at or "")
                    local originalMedia = type(playlistEntry.media) == "table" and playlistEntry.media or {}
                    local originalSource = tostring(originalMedia.source or "")
                    panelUi.beginPlaylistEntryEditor(playlistEntry, playlistId, playlistEntryIndex)
                    opened = playlistEntryEditorOpen == true
                        and editingPlaylistEntryId == originalId
                        and editingPlaylistEntryPlaylistId == playlistId
                        and editingPlaylistEntryIndex == playlistEntryIndex

                    -- Mirror choosing the Videos tab before choosing a real
                    -- indexed card. No media path is fabricated by this probe.
                    playlistEntrySourceKind = "video"
                    playlistEntrySourcePage = 1
                    local pageChoices, _library, totalChoices = panelUi.libraryItems(
                        "video",
                        0,
                        const.ENTRY_SOURCE_PAGE_SIZE
                    )
                    sourceChoices = pageChoices
                    sourceTotal = totalChoices
                    for _, choice in ipairs(sourceChoices) do
                        local entry = type(choice) == "table" and choice.entry or nil
                        if type(entry) == "table" and tostring(entry.source or "") ~= originalSource then
                            choice.kind = "video"
                            panelUi.selectPlaylistEntrySource(choice)
                            selected = true
                            break
                        end
                    end

                    sourceChanged = selected
                        and entryMediaKindDraft == "video"
                        and tostring(entryMediaSourceDraft or "") ~= ""
                        and tostring(entryMediaSourceDraft or "") ~= originalSource
                    idPreserved = originalId ~= "" and editingPlaylistEntryId == originalId
                    addedAtPreserved = originalAddedAt ~= ""
                        and tostring(entryAddedAtDraft or "") == originalAddedAt
                    positionPreserved = editingPlaylistEntryPlaylistId == playlistId
                        and editingPlaylistEntryIndex == playlistEntryIndex

                    local editorNode = panelUi.playlistEntryEditor(playlistId, "HEADLESS-1")
                    editorRendered = editorNode ~= nil
                    if editorRendered then
                        panel.render(ui.scroll({
                            key = "wall-in-one-vm-playlist-entry-editor",
                            flexGrow = 1,
                            align = "stretch",
                            gap = 8,
                        }, { editorNode }))
                    end
                end

                noctalia.log(
                    "WALL_IN_ONE_VM_PLAYLIST_ENTRY_EDITOR "
                        .. tostring(payload or "")
                        .. " playlist=" .. tostring(playlistId ~= "")
                        .. " entry=" .. tostring(type(playlistEntry) == "table")
                        .. " open=" .. tostring(opened)
                        .. " choices=" .. tostring(#sourceChoices)
                        .. " selected=" .. tostring(selected)
                        .. " source_changed=" .. tostring(sourceChanged)
                        .. " id_preserved=" .. tostring(idPreserved)
                        .. " added_at_preserved=" .. tostring(addedAtPreserved)
                        .. " position_preserved=" .. tostring(positionPreserved)
                        .. " rendered=" .. tostring(editorRendered)
                        .. " total=" .. tostring(sourceTotal)
                )
                closePlaylistEntryEditor()
                activePage = "main"
                activeSubpage = ""
                render()
                return
            elseif event == "vm-wallhaven-route-cache" then
                local items = {}
                -- Exercise a full provider-sized result set. Production still
                -- materializes only the current 12-card page, so navigation
                -- and preview planning must not scale with all 48 records.
                for index = 0, 47 do
                    local identifier = string.format("aa%04d", index)
                    table.insert(items, {
                        id = identifier,
                        url = "https://wallhaven.cc/w/" .. identifier,
                        short_url = "https://whvn.cc/" .. identifier,
                        resolution = "320x180",
                        ratio = "16:9",
                        purity = "sfw",
                        category = "general",
                        file_size = 12345,
                        views = index,
                        favorites = index,
                        thumbs = {
                            large = "https://th.wallhaven.cc/lg/aa/" .. identifier .. ".jpg",
                        },
                    })
                end
                wallhavenResultsState = {
                    schema = 1,
                    kind = "search",
                    sequence = 903,
                    items = items,
                    selected = items[1],
                    meta = { current_page = 1, last_page = 1, total = #items },
                }
                wallhavenState = { available = true, busy = false }
                providerResultEpochs.wallhaven += 1
                vmPreview.provider = ""
                status = panelUi.composeStatus()
                status.storage_valid = true
                activePage = "main"
                activeSubpage = ""
                panelPages.selectShopPage("wallhaven")
                local visible = panelUi.providerItems(
                    items,
                    providerResultPages.wallhaven,
                    const.PROVIDER_RESULT_CHUNK
                )
                noctalia.log(
                    "WALL_IN_ONE_VM_WALLHAVEN_ROUTE_CACHE "
                        .. tostring(payload or "")
                        .. " items=" .. tostring(#items)
                        .. " visible=" .. tostring(#visible)
                        .. " page=" .. tostring(activePage)
                        .. " subpage=" .. tostring(activeSubpage)
                )
                return
            elseif event == "vm-motion-sustained-start" then
                preview.cancel()
                local items = {}
                for index = 1, 36 do
                    local slug = "nature-" .. tostring(index)
                    table.insert(items, {
                        slug = slug,
                        title = "Nature " .. tostring(index),
                        quality = "4K",
                        source_url = "https://motionbgs.com/" .. slug,
                        thumbnail_url = "https://motionbgs.com/i/c/364x205/media/"
                            .. tostring(5000 + index)
                            .. "/"
                            .. slug
                            .. ".3840x2160.jpg",
                        poster_url = "https://motionbgs.com/media/"
                            .. tostring(5000 + index)
                            .. "/"
                            .. slug
                            .. ".3840x2160.jpg",
                        duration = "00:30",
                        downloads = {},
                    })
                end
                motionBgsResultsState = {
                    schema = 1,
                    kind = "search",
                    sequence = 904,
                    mode = "search",
                    items = items,
                    selected = items[1],
                    meta = { current_page = 1, pageable = false, total_hint = #items },
                }
                motionBgsState = {
                    available = true,
                    busy = false,
                    binary_compatible = true,
                }
                providerResultEpochs.motionbgs += 1
                providerResultPages.motionbgs = 1
                -- Exercise the production route (header, navigation, and the
                -- fixed provider page), not the smaller screenshot wrapper.
                vmPreview.provider = ""
                vmPreview.sustained = true
                vmPreview.frameTicks = 0
                vmPreview.renderPasses = 0
                status = panelUi.composeStatus()
                status.storage_valid = true
                if type(status.providers) ~= "table" then
                    status.providers = {}
                end
                if type(status.providers.motionbgs) ~= "table" then
                    status.providers.motionbgs = {}
                end
                status.providers.motionbgs.integration_available = true
                activePage = "shops"
                activeSubpage = "motionbgs"
                render()
                panel.setNeedsFrameTick(true)
                local visible = panelUi.providerItems(items, providerResultPages.motionbgs, const.PROVIDER_RESULT_CHUNK)
                noctalia.log(
                    "WALL_IN_ONE_VM_MOTION_SUSTAINED_START "
                        .. tostring(payload or "")
                        .. " items=" .. tostring(#items)
                        .. " visible=" .. tostring(#visible)
                )
                return
            elseif event == "vm-motion-sustained-probe" then
                local snapshot = preview.debugSnapshot("motionbgs:nature-1")
                local source = type(motionBgsResultsState) == "table"
                        and type(motionBgsResultsState.items) == "table"
                        and motionBgsResultsState.items
                    or {}
                local visible = panelUi.providerItems(source, providerResultPages.motionbgs, const.PROVIDER_RESULT_CHUNK)
                noctalia.log(
                    "WALL_IN_ONE_VM_MOTION_SUSTAINED "
                        .. tostring(payload or "")
                        .. " items=" .. tostring(#source)
                        .. " visible=" .. tostring(#visible)
                        .. " frames=" .. tostring(vmPreview.frameTicks)
                        .. " renders=" .. tostring(vmPreview.renderPasses)
                        .. " initialized=" .. tostring(snapshot.initialized)
                        .. " ready=" .. tostring(snapshot.ready)
                        .. " initialization_phase=" .. tostring(snapshot.initialization_phase)
                        .. " initialization_requested=" .. tostring(snapshot.initialization_requested)
                        .. " queue=" .. tostring(snapshot.queue_depth)
                        .. " active=" .. tostring(snapshot.active)
                        .. " dirty=" .. tostring(snapshot.manifest_dirty)
                        .. " render_pending=" .. tostring(snapshot.render_pending)
                        .. " entries=" .. tostring(snapshot.entries)
                        .. " paths=" .. tostring(snapshot.paths)
                        .. " last_used=" .. tostring(snapshot.key_last_used)
                        .. " interval=" .. tostring(snapshot.update_interval)
                        .. " scope=" .. tostring(snapshot.scope)
                        .. " sweep=" .. tostring(snapshot.sweep_index)
                        .. "/" .. tostring(snapshot.sweep_limit)
                        .. " drag_dirty=" .. tostring(snapshot.drag_tokens_dirty)
                        .. " open=" .. tostring(snapshot.is_open)
                )
                return
            elseif event == "vm-motion-sustained-stop" then
                vmPreview.sustained = false
                panel.setNeedsFrameTick(false)
                vmPreview.provider = ""
                preview.cancel()
                vmPreview.render()
                noctalia.log("WALL_IN_ONE_VM_MOTION_SUSTAINED_STOP " .. tostring(payload or ""))
                return
            elseif event == "vm-preview-cache-diagnostic" then
                local snapshot = preview.debugSnapshot("wallhaven:aa0000")
                noctalia.log(
                    "WALL_IN_ONE_VM_PREVIEW_CACHE "
                        .. tostring(payload or "")
                        .. " initialized=" .. tostring(snapshot.initialized)
                        .. " ready=" .. tostring(snapshot.ready)
                        .. " initialization_phase=" .. tostring(snapshot.initialization_phase)
                        .. " initialization_requested=" .. tostring(snapshot.initialization_requested)
                        .. " queue=" .. tostring(snapshot.queue_depth)
                        .. " active=" .. tostring(snapshot.active)
                        .. " dirty=" .. tostring(snapshot.manifest_dirty)
                        .. " render_pending=" .. tostring(snapshot.render_pending)
                        .. " open=" .. tostring(snapshot.is_open)
                        .. " page=" .. tostring(snapshot.active_page)
                        .. " subpage=" .. tostring(snapshot.active_subpage)
                        .. " entries=" .. tostring(snapshot.entries)
                        .. " paths=" .. tostring(snapshot.paths)
                        .. " last_used=" .. tostring(snapshot.key_last_used)
                        .. " clock=" .. tostring(snapshot.clock)
                        .. " interval=" .. tostring(snapshot.update_interval)
                        .. " scope=" .. tostring(snapshot.scope)
                        .. " drag_dirty=" .. tostring(snapshot.drag_tokens_dirty)
                )
                return
            elseif event == "vm-provider-preview" then
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
                    providerResultEpochs.wallhaven += 1
                    vmPreview.provider = provider
                    status = panelUi.composeStatus()
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
                    providerResultEpochs.motionbgs += 1
                    vmPreview.provider = provider
                    status = panelUi.composeStatus()
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
    backend_binary_path = "${lib.getExe fakeUnifiedBackend}"
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
      : > /tmp/wall-in-one-vm-motion-transports.log
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
              # Bash %q uses $'...\\t...' for the wrapper's tab-delimited
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

      def motion_calls():
          return machine.succeed(
              "cat /tmp/wall-in-one-vm-motion-calls.log"
          ).splitlines()

      def motion_transports():
          return machine.succeed(
              "cat /tmp/wall-in-one-vm-motion-transports.log"
          ).splitlines()

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
                  + "\nMotionBGS fixture transports:\n"
                  + machine.execute("tail -n 80 /tmp/wall-in-one-vm-motion-transports.log")[1]
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

      service_reload_marker = "hot reload: reloaded service '${serviceId}'"
      service_reload_probe = [0]
      def reload_service_source(label: str):
          # Noctalia watches the materialized parent directory for a completed
          # write or same-directory rename. Let its 100 ms debounce window
          # expire, then atomically replace the source with a visibly changed,
          # fully written file. This cannot expose a partial Luau program and
          # gives a missed inotify event a bounded, actionable failure.
          machine.sleep(1)
          reloads_before = int(machine.succeed(
              f"{journal} | grep -Fc -- {shlex.quote(service_reload_marker)}"
          ).strip())
          service_source = "${materializedRoot}/service.luau"
          service_stage = service_source + f".vm-reload-{service_reload_probe[0]}"
          service_reload_probe[0] += 1
          comment = f"-- {label} {service_reload_probe[0]}"
          machine.succeed(
              "cp -- "
              + shlex.quote(service_source)
              + " "
              + shlex.quote(service_stage)
              + " && printf '%s\\n' "
              + shlex.quote(comment)
              + " >> "
              + shlex.quote(service_stage)
              + " && mv -f -- "
              + shlex.quote(service_stage)
              + " "
              + shlex.quote(service_source)
              + " && tail -n 1 "
              + shlex.quote(service_source)
              + " | grep -Fx -- "
              + shlex.quote(comment)
          )
          machine.wait_until_succeeds(
              f"test $({journal} | grep -Fc -- {shlex.quote(service_reload_marker)}) "
              f"-gt {reloads_before}",
              timeout=60,
          )
          reload_token = f"service-reload-{service_reload_probe[0]}"
          machine.wait_until_succeeds(
              noctalia_command(
                  f"plugin ${serviceId} all vm-probe {reload_token}"
              )
              + " >/dev/null && "
              + journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_PROBE {reload_token}"),
              timeout=60,
          )

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
      # Keep palettes.inventory fully offline and deterministic. A current
      # schema-1 cache exercises the real Python reader and paged RPC response
      # without allowing the backend to attempt api.noctalia.dev during boot.
      palette_cache = json.dumps({
          "schema": 1,
          "fetched_at": int(machine.succeed("date +%s").strip()),
          "fetched_at_text": "VM fresh cache",
          "entries": [{
              "name": "VM Community",
              "md5": "0123456789abcdef0123456789abcdef",
              "preview": {
                  "dark": {
                      "surface": "#101820",
                      "accents": ["#11AA22", "#22BB33", "#33CC44", "#DD3344"],
                  },
                  "light": {
                      "surface": "#F4F5F6",
                      "accents": ["#2255AA", "#3366BB", "#4477CC", "#CC2233"],
                  },
              },
          }],
      })
      machine.succeed(
          "install -d -o ${testUser} -g users ${pluginDataRoot}; "
          "printf '%s\\n' "
          + shlex.quote(legacy_config)
          + " > ${pluginDataRoot}/config.json; "
          "printf '%s\\n' "
          + shlex.quote(legacy_runtime)
          + " > ${pluginDataRoot}/runtime.json; "
          "printf '%s\\n' "
          + shlex.quote(palette_cache)
          + " > ${pluginDataRoot}/palettes-cache.json; "
          "chown ${testUser}:users ${pluginDataRoot}/config.json "
          "${pluginDataRoot}/runtime.json ${pluginDataRoot}/palettes-cache.json"
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
      wait_log("started service '${backendServiceId}'")
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
          "${materializedRoot}/scripts/backend-provider self-test "
          "| grep -Fx $'WIO-BACKEND-SELFTEST1\\tok\\tself-test'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- python3 "
          "${guestSourceRoot}/wall-in-one-backend/wall-in-one-backend self-test "
          "| grep -Fx $'WIO-BACKEND-SELFTEST1\\tok\\t0.1.0'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- ${lib.getExe fakeUnifiedBackend} "
          "probe --protocol 1 "
          "| grep -F $'WIO-BACKEND-PROBE1\\tok\\t1\\t0.1.0\\tlibrary.scan'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- bash "
          "${materializedRoot}/scripts/backend-provider probe "
          "${lib.getExe fakeUnifiedBackend} "
          "| grep -F $'WIO-BACKEND-PROBE1\\tok\\t1\\t0.1.0\\tlibrary.scan'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- ${lib.getExe fakeUnifiedBackend} "
          "motionbgs-probe --protocol 1 "
          "| grep -Fx $'WIO-MBGS-PROBE1\\tok\\t1\\t1.0.0-fixture\\tsearch,details,download,clear'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- bash "
          "${materializedRoot}/scripts/motionbgs-provider probe "
          "${lib.getExe fakeUnifiedBackend} "
          "| grep -Fx $'WIO-MBGS-PROBE1\\tok\\t1\\t1.0.0-fixture\\tsearch,details,download,clear'"
      )
      machine.succeed(
          "runuser -u ${testUser} -- bash "
          "${materializedRoot}/scripts/provider-thumbnail self-test "
          "| grep -Fx $'WIO-THUMB1\\tok\\tself-test'"
      )
      machine.succeed(
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
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/service.luau && "
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/panel.luau && "
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/palettes.luau && "
          "${pkgs.luau}/bin/luau-compile --null ${materializedRoot}/backend.luau"
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
          "palette_community=1",
          "palette_cache_source=primary",
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

      # Refresh now crosses the process boundary. The coordinator only publishes
      # one nonce-bound request; the backend service validates paged results and
      # atomically replaces the library on later bounded update ticks.
      backend_ready_token = "process-backend-ready"
      backend_ready_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_BACKEND {backend_ready_token}",
          "ready=true",
          "available=true",
          "compatible=true",
          "version=0.1.0",
      ):
          backend_ready_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-backend-probe {backend_ready_token}"
          )
          + " >/dev/null && "
          + backend_ready_filters,
          timeout=60,
      )
      library_refresh_token = "process-library-refresh"
      noctalia_msg(
          f"plugin ${serviceId} all vm-library-refresh {library_refresh_token}"
      )
      for fragment in (
          f"WALL_IN_ONE_VM_LIBRARY_REFRESH {library_refresh_token}",
          "accepted=true",
          "scanning=true",
          "backend_available=true",
          "nonce_set=true",
      ):
          wait_log(fragment)
      library_done_token = "process-library-done"
      library_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_LIBRARY {library_done_token}",
          "scanning=false",
          "videos=6",
          "workshops=1",
          "backend_scan_complete=true",
      ):
          library_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-library-probe {library_done_token}"
          )
          + " >/dev/null && "
          + library_filters
      )
      machine.fail(
          "find ${pluginDataRoot}/backend-bridge-v1/rpc -mindepth 1 -maxdepth 1 "
          "-type f ! -name '.wall-in-one-backend-library.lock' | grep -q ."
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
          "vm-cycle-create-schedule-upper",
          "vm-cycle-create-schedule-lower",
          "vm-cycle-add-static",
          "vm-cycle-add-video",
          "vm-cycle-add-workshop",
          "vm-cycle-options",
          "vm-cycle-assign",
          "vm-cycle-schedule-lower",
          # Create the lower rule first, then insert the upper rule before it.
          # This exercises schedule_save.before_id while preserving the visual
          # top-to-bottom precedence model used by the display editor.
          "vm-cycle-schedule-upper",
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'.schema_version == 5 and "
          "(. as $config "
          "| ((.playlists | to_entries | map(select(.value.name == \"VM mixed playlist\")) | .[0]) as $record "
          "| $record.value as $p "
          "| $p.interval_seconds == 900 "
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
          "and .playlists[.outputs[\"HEADLESS-1\"].schedules[1].playlist].name "
          "== \"VM schedule upper\" "
          "and .playlists[.outputs[\"HEADLESS-1\"].schedules[2].playlist].name "
          "== \"VM schedule lower\" "
          "and .outputs[\"HEADLESS-1\"].schedules[1].playlist != $record.key "
          "and .outputs[\"HEADLESS-1\"].schedules[2].playlist != $record.key "
          "and .outputs[\"HEADLESS-1\"].schedules[1].playlist "
          "!= .outputs[\"HEADLESS-1\"].schedules[2].playlist "
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
          "winner_is_lower=true",
          "distinct=true",
          "miss=true",
          "miss_uses_fallback=true",
      ):
          wait_log(fragment)

      # A changed global item default reuses the medium/source identity, updates
      # every linked snapshot, and does not leak another hidden profile.
      noctalia_msg("plugin ${serviceId} all vm-default-profile-create")
      noctalia_msg("plugin ${serviceId} all vm-default-profile-refresh")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(. as $config "
          "| ([.pairings | to_entries[] "
          "| select(.value.customized == false "
          "and .value.media.kind == \"video\" "
          "and .value.media.source == \"${fixtureVideo}\")]) as $profiles "
          "| (.playlists | to_entries "
          "| map(select(.value.name == \"VM default identity\")) | .[0].value) as $playlist "
          "| ($profiles | length) == 1 "
          "and ($playlist.entries | length) == 2 "
          "and $playlist.entries[0].pairing_id == $profiles[0].key "
          "and $playlist.entries[1].pairing_id == $profiles[0].key "
          "and $profiles[0].value.label == \"VM default refreshed\" "
          "and $profiles[0].value.theme.selection == \"m3-rainbow\" "
          "and ([.playlists[].entries[] "
          "| select(.pairing_id == $profiles[0].key) "
          "| .label == \"VM default refreshed\" "
          "and .theme.selection == \"m3-rainbow\"] | all))' "
          "${pluginDataRoot}/config.json"
      )

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
      # translation. Saving customization for media already discovered by the
      # mixed playlist must reuse the one profile owned by that source, then
      # synchronize edits and resets across every linked occurrence.
      for event in (
          "vm-pairing-create",
          "vm-pairing-save-adaptive",
          "vm-pairing-save-video",
      ):
          noctalia_msg(f"plugin ${serviceId} all {event}")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")]) as $adaptive "
          "| ([.pairings | to_entries[] "
          "| select(.value.media.kind == \"video\" "
          "and .value.media.source == \"${fixtureVideo}\")]) as $video "
          "| ($adaptive | length) == 1 "
          "and ($video | length) == 1 "
          "and $adaptive[0].value.customized == true "
          "and $adaptive[0].value.theme.source == \"wallpaper\" "
          "and $video[0].value.customized == true "
          "and $video[0].value.still.path == \"${fixtureVideoStill}\"' "
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
          "| ([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")][0]) as $adaptive "
          "| ([.pairings | to_entries[] "
          "| select(.value.media.kind == \"video\" "
          "and .value.media.source == \"${fixtureVideo}\")][0]) as $video "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| ($p.entries | length) == 2 "
          "and [ $p.entries[].pairing_id ] "
          "== [$adaptive.key,$video.key] "
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
          "| ([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")][0]) as $adaptive "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| $adaptive.value.label == \"VM adaptive still updated\" "
          "and $adaptive.value.customized == true "
          "and $adaptive.value.theme.mode == \"light\" "
          "and ($p.entries[] | select(.pairing_id == $adaptive.key) "
          "| .label == \"VM adaptive still updated\" and .theme.mode == \"light\"))' "
          "${pluginDataRoot}/config.json"
      )
      noctalia_msg("plugin ${serviceId} all vm-pairing-place")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")][0].key) as $adaptive "
          "| ([.pairings | to_entries[] "
          "| select(.value.media.kind == \"video\" "
          "and .value.media.source == \"${fixtureVideo}\")][0].key) as $video "
          "| (.playlists | to_entries "
          "| map(select(.value.name == \"VM pairing commands\")) "
          "| .[0].value.entries | [ .[].pairing_id ]) == [$video,$adaptive]' "
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

      noctalia_msg("plugin ${serviceId} all vm-pairing-reset")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
          "'(. as $config "
          "| ([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")]) as $adaptive "
          "| (.playlists | to_entries | map(select(.value.name == \"VM pairing commands\")) | .[0].value) as $p "
          "| ($adaptive | length) == 1 "
          "and $adaptive[0].value.customized == false "
          "and $adaptive[0].value.label == \"VM adaptive still reset\" "
          "and $adaptive[0].value.theme.mode == \"auto\" "
          "and ($p.entries | length) == 2 "
          "and $p.entries[1].pairing_id == $adaptive[0].key "
          "and $p.entries[1].customized == false "
          "and $p.entries[1].label == \"VM adaptive still reset\" "
          "and $p.entries[1].still.path == \"${fixtureStill}\" "
          "and $p.entries[1].theme.mode == \"auto\" "
          "and ([.playlists[].entries[] "
          "| select(.pairing_id == $adaptive[0].key) "
          "| .customized == false "
          "and .label == \"VM adaptive still reset\" "
          "and .theme.mode == \"auto\"] | all))' "
          "${pluginDataRoot}/config.json"
      )

      # The graphical entry editor rebinds one occurrence to another indexed
      # medium. It must preserve occurrence identity/order metadata and must
      # not mutate the old medium's shared pairing profile.
      noctalia_msg("plugin ${serviceId} all vm-playlist-entry-replace")
      replacement_token = "graphical-picker"
      replacement_filters = journal
      for fragment in (
          f"WALL_IN_ONE_VM_ENTRY_REPLACE {replacement_token}",
          "preserved_id=true",
          "preserved_time=true",
          "rebound=true",
          "workshop=true",
          "customized=true",
          "old_intact=true",
      ):
          replacement_filters += f" | grep -F -- {shlex.quote(fragment)}"
      machine.wait_until_succeeds(
          noctalia_command(
              f"plugin ${serviceId} all vm-playlist-entry-replace-probe {replacement_token}"
          )
          + " >/dev/null && "
          + replacement_filters,
          timeout=20,
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
      try:
          machine.wait_until_succeeds(
              "test -s /tmp/wall-in-one-vm-mpvpaper-current.pid; "
              "test \"$(cat /tmp/wall-in-one-vm-mpvpaper-current.pid)\" != " + mpv_pid,
              timeout=30,
          )
      except Exception as renderer_advance_error:
          # Capture the shared command slot and the renderer's independently
          # published nonce/event snapshot before the VM is torn down. Without
          # this, the outer 15-minute action timeout hides whether the command
          # was absent, rejected, queued at the FIFO, or acknowledged without a
          # replacement child.
          token = "renderer-playlist-advance-timeout"
          noctalia_msg(f"plugin ${serviceId} all vm-probe {token}")
          machine.sleep(1)
          renderer_diagnostic = machine.wait_until_succeeds(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_PROBE {token}")
              + " | tail -n 1",
              timeout=10,
          ).strip()
          renderer_invocations = machine.succeed(
              "cat /tmp/wall-in-one-vm-mpvpaper-invocations.log 2>/dev/null || true"
          ).strip()
          raise AssertionError(
              "playlist advanced without replacing its mpvpaper child:\n"
              + renderer_diagnostic
              + "\nmpvpaper fixture invocations:\n"
              + renderer_invocations
          ) from renderer_advance_error
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

      # MotionBGS runs through the real bundled launcher and a separately
      # configured external protocol fixture. The fixture emits pinned
      # normalized listing/detail data and installs the pinned MP4, while the
      # Luau service only performs bounded request/response validation.
      motion_cache = "${pluginDataRoot}/motionbgs-bridge-v1/cache/cache-v1.json"
      motion_rpc = "${pluginDataRoot}/motionbgs-bridge-v1/cache/rpc/"
      wait_motion(
          available=True,
          busy=False,
          binary_source="configured",
          binary_version="1.0.0-fixture",
      )
      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(
          action="search", cached=False, busy=False,
          items=1, first="night-city",
      )
      motion_calls_after_search = len(motion_calls())
      motion_transports_after_search = len(motion_transports())
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          + shlex.quote('.schema == 1 and (.searches | length) == 1')
          + " "
          + shlex.quote(motion_cache)
      )
      machine.fail("test -e ${pluginDataRoot}/motionbgs/cache-v2.json")

      # Cache ownership moved across the process boundary. A hit still invokes
      # one RPC process, but must not attempt the deliberately denied provider
      # transport and must report the cached bit through the bridge.
      set_motion_mode("deny")
      noctalia_msg("plugin ${serviceId} all vm-motion-search 'night city'")
      wait_motion(
          action="search", cached=True, busy=False,
          items=1, first="night-city",
      )
      assert len(motion_calls()) == motion_calls_after_search + 1
      cache_hit_call = motion_calls()[-1].split("\t")
      assert cache_hit_call[0:3:2] == ["rpc", "search"]
      assert cache_hit_call[3].startswith(motion_rpc + "request-")
      assert cache_hit_call[4].startswith(motion_rpc + "response-")
      assert cache_hit_call[5].startswith(motion_rpc + ".wall-in-one-motionbgs-guard-")
      machine.fail(
          "find " + shlex.quote(motion_rpc) + " -maxdepth 1 -type f "
          "-name '.wall-in-one-motionbgs-guard-*' | grep -q ."
      )
      assert len(motion_transports()) == motion_transports_after_search

      # The pinned normalized genre response retains all 36 cards from the
      # former realistic provider-page fixture. This still exercises bounded
      # service validation and large-list publication/rendering without doing
      # HTML parsing on a Noctalia callback.
      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 1")
      wait_motion(
          action="search", cached=False, busy=False, mode="genre", page=1,
          previous=False, next=True, items=36, first="nature-1",
      )
      machine.fail(f"{journal} | grep -F -- 'exceeded its CPU budget'")
      motion_calls_after_genre = len(motion_calls())
      motion_transports_after_genre = len(motion_transports())
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          + shlex.quote('.schema == 1 and (.searches | length) == 2')
          + " "
          + shlex.quote(motion_cache)
      )
      set_motion_mode("deny")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 1")
      wait_motion(
          action="search", cached=True, busy=False, mode="genre", page=1,
          previous=False, next=True, items=36, first="nature-1",
      )
      assert len(motion_calls()) == motion_calls_after_genre + 1
      assert motion_calls()[-1].split("\t")[0:3:2] == ["rpc", "search"]
      assert len(motion_transports()) == motion_transports_after_genre

      set_motion_mode("good")
      noctalia_msg("plugin ${serviceId} all vm-motion-browse-genre 2")
      wait_motion(
          action="search", cached=False, busy=False, mode="genre", page=2,
          previous=True, next=False, items=1, first="nature-page-two",
      )
      motion_calls_after_page_two = len(motion_calls())
      motion_transports_after_page_two = len(motion_transports())
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          + shlex.quote('.schema == 1 and (.searches | length) == 3')
          + " "
          + shlex.quote(motion_cache)
      )
      noctalia_msg("plugin ${serviceId} all vm-motion-hd-page-two")
      wait_motion(action="search", error_kind="invalid-browse", busy=False)
      assert len(motion_calls()) == motion_calls_after_page_two
      assert len(motion_transports()) == motion_transports_after_page_two

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
      motion_download = "${motionManagedRoot}/night-city.hd.mp4"
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

      # The managed MotionBGS directory is a dedicated child of the selected
      # user video root. Sidecar-proven downloads in that child remain deletable,
      # while unrelated files at the selected root stay owned by the user.
      # Re-downloading the same deterministic path must refresh the library from
      # the completion nonce rather than the path alone.
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
      machine.succeed(
          "${lib.getExe pkgs.jq} -e "
          + shlex.quote(
              '.schema == 1 and (.searches | length) == 0 '
              'and (.details | length) == 0 and (.search_order | length) == 0 '
              'and (.detail_order | length) == 0'
          )
          + " "
          + shlex.quote(motion_cache)
      )

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
      noctalia_msg("plugin ${serviceId} all pair-manual")
      machine.wait_until_succeeds(
          "${lib.getExe pkgs.jq} -e "
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
      reload_service_source("VM GIF persistence reload probe")
      machine.wait_until_succeeds(
          noctalia_command("wallpaper-get HEADLESS-1")
          + " | grep -Fx -- "
          + shlex.quote(gif_still),
          timeout=60,
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

      reload_service_source("VM persistence reload probe")
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
          "| ([.pairings | to_entries[] "
          "| select(.value.media == null "
          "and .value.still.path == \"${fixtureStill}\")]) as $adaptive "
          "| ([.pairings | to_entries[] "
          "| select(.value.media.kind == \"video\" "
          "and .value.media.source == \"${fixtureVideo}\")]) as $video "
          "| .outputs[\"HEADLESS-1\"].fallback_playlist as $p "
          "| .playlists[$p].name == \"VM mixed playlist\" "
          "and (.playlists[$p].entries | length) == 3 "
          "and ([ .playlists[$p].entries[].id ] | length) "
          "== ([ .playlists[$p].entries[].id ] | unique | length) "
          "and ([ .playlists[$p].entries[] as $entry "
          "| $config.pairings[$entry.pairing_id].id == $entry.pairing_id ] | all) "
          "and ($adaptive | length) == 1 "
          "and $adaptive[0].value.customized == false "
          "and $adaptive[0].value.theme.mode == \"auto\" "
          "and ($video | length) == 1 "
          "and $video[0].value.customized == true)' "
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

      # Invoke the production edit callback with a Workshop identity that has
      # no saved pairing. This is the common synthesized-default path and must
      # reach the editor without resolving panelUi as an undeclared global.
      assert noctalia_msg(
          "plugin ${pluginId}:hub all vm-library-default-edit fresh-workshop"
      ).strip() == "ok: dispatched 1"
      wait_log(
          "WALL_IN_ONE_VM_LIBRARY_DEFAULT_EDIT fresh-workshop "
          "existing=false open=true editor_kind=workshop media_kind=workshop "
          "source=999999999 still=automatic id_empty=true"
      )

      # Exercise the actual playlist-occurrence editor against persisted
      # playlist state and a real indexed video card. This must build and render
      # the production graphical picker without a raw source-path field while
      # preserving the occurrence's durable identity fields in the draft.
      # The panel adopts the coordinator's library domain asynchronously, so a
      # single dispatch can land before any indexed video has reached panel
      # state and answer with choices=0. Waiting longer cannot help: the probe
      # already logged its one-shot answer. Re-dispatch under a fresh token
      # instead. The probe closes its editor and returns to the main page on
      # every pass, so repeating it is side-effect free.
      entry_editor_matched = False
      for attempt in range(1, 9):
          entry_editor_token = f"indexed-video-{attempt}"
          assert noctalia_msg(
              f"plugin ${pluginId}:hub all vm-playlist-entry-editor {entry_editor_token}"
          ).strip() == "ok: dispatched 1"
          entry_editor_marker = (
              f"WALL_IN_ONE_VM_PLAYLIST_ENTRY_EDITOR {entry_editor_token} "
              "playlist=true entry=true open=true choices=6 "
              "selected=true source_changed=true id_preserved=true "
              "added_at_preserved=true position_preserved=true rendered=true"
          )
          try:
              machine.wait_until_succeeds(
                  journal + " | grep -F -- " + shlex.quote(entry_editor_marker),
                  timeout=10,
              )
          except Exception:
              continue
          entry_editor_matched = True
          break
      assert entry_editor_matched, (
          "playlist entry editor probe never reported the populated shape:\n"
          + machine.succeed(
              journal
              + " | grep -F -- WALL_IN_ONE_VM_PLAYLIST_ENTRY_EDITOR || true"
          )
      )
      machine.fail(f"{journal} | grep -F -- 'exceeded its CPU budget'")
      machine.fail(
          f"{journal} | grep -F -- \"plugin panel '${pluginId}:hub' disabled after repeated timeouts\""
      )

      # Reproduce the live Wallhaven navigation shape: a full 64-entry stale
      # preview manifest and 12 visible cache hits. The production route
      # callback must only schedule its render; cache validation, LRU touches,
      # and the single manifest rewrite run on bounded update callbacks.
      preview_cache = "${pluginDataRoot}/provider-previews/v1"
      preview_manifest = preview_cache + "/manifest.json"
      preview_bytes = int(machine.succeed(
          "stat -c %s ${fixtureWallhavenThumbnail}"
      ).strip())
      route_entries = {}
      route_keys = []
      for index in range(64):
          identifier = f"aa{index:04d}"
          key = f"wallhaven:{identifier}"
          filename = f"wallhaven-{identifier}-1-{index + 1}.png"
          route_entries[key] = {
              "provider": "wallhaven",
              "id": identifier,
              "url": f"https://th.wallhaven.cc/lg/aa/{identifier}.jpg",
              "filename": filename,
              "bytes": preview_bytes,
              "last_used": 1,
          }
          if index < 12:
              route_keys.append(key)
      route_manifest = json.dumps({"schema": 1, "entries": route_entries})
      machine.succeed(
          "runuser -u ${testUser} -- install -d "
          + shlex.quote(preview_cache)
      )
      seed_cache = (
          "set -eu; i=0; while [ \"$i\" -lt 64 ]; do "
          "identifier=$(printf 'aa%04d' \"$i\"); "
          "sequence=$((i + 1)); "
          "cp ${fixtureWallhavenThumbnail} "
          + shlex.quote(preview_cache)
          + "/wallhaven-$identifier-1-$sequence.png; "
          "i=$((i + 1)); done"
      )
      machine.succeed(
          "runuser -u ${testUser} -- bash -c " + shlex.quote(seed_cache)
      )
      machine.succeed(
          "runuser -u ${testUser} -- bash -c "
          + shlex.quote(
              "printf '%s\\n' "
              + shlex.quote(route_manifest)
              + " > "
              + shlex.quote(preview_manifest)
          )
      )
      assert noctalia_msg(
          "plugin ${pluginId}:hub all vm-wallhaven-route-cache stale-64"
      ).strip() == "ok: dispatched 1"
      wait_log(
          "WALL_IN_ONE_VM_WALLHAVEN_ROUTE_CACHE stale-64 "
          "items=48 visible=12 page=shops subpage=wallhaven"
      )
      route_touch_predicate = (
          ".schema == 1 and (.entries | length) == 64 and (["
          + ",".join(
              f'.entries[{json.dumps(key)}].last_used > 1'
              for key in route_keys
          )
          + "] | all)"
      )
      try:
          machine.wait_until_succeeds(
              "${lib.getExe pkgs.jq} -e "
              + shlex.quote(route_touch_predicate)
              + " "
              + shlex.quote(preview_manifest),
              timeout=30,
          )
      except Exception as preview_cache_error:
          token = "stale-64-timeout"
          assert noctalia_msg(
              f"plugin ${pluginId}:hub all vm-preview-cache-diagnostic {token}"
          ).strip() == "ok: dispatched 1"
          preview_diagnostic = machine.wait_until_succeeds(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_PREVIEW_CACHE {token}")
              + " | tail -n 1",
              timeout=10,
          ).strip()
          manifest_diagnostic = machine.succeed(
              "${lib.getExe pkgs.jq} -c "
              + shlex.quote(
                  '{schema, entries: (.entries | length), '
                  'target: .entries["wallhaven:aa0000"]}'
              )
              + " "
              + shlex.quote(preview_manifest)
              + " 2>/dev/null || { cat "
              + shlex.quote(preview_manifest)
              + " 2>/dev/null || true; }"
          ).strip()
          thumbnail_invocations = machine.succeed(
              "cat /tmp/wall-in-one-vm-thumbnail-calls.log 2>/dev/null || true"
          ).strip()
          raise AssertionError(
              "Wallhaven stale-cache entries were not touched within 30 seconds:\n"
              + preview_diagnostic
              + "\npreview manifest:\n"
              + manifest_diagnostic
              + "\nthumbnail helper invocations:\n"
              + thumbnail_invocations
          ) from preview_cache_error

      # Exercise both real provider panes against a deterministic offline
      # thumbnail transport. A cache entry alone is insufficient: the captured
      # pane must contain the fixture's unique color, proving that ui.image
      # replaced the glyph fallback after async completion.
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
          + shlex.quote('.schema == 1 and (.entries | length) == 64')
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

      # Regression for the live 0.7.0 failure: a 36-result MotionBGS set must
      # remain a fixed 12-card production route. The VM deliberately keeps frame
      # callbacks armed after thumbnail work settles; those callbacks must not
      # trigger any further full panel renders or trip Noctalia's CPU watchdog.
      machine.succeed("printf '%s\\n' good > " + shlex.quote(thumbnail_mode))
      sustained_token = "motion-36"
      assert noctalia_msg(
          f"plugin ${pluginId}:hub all vm-motion-sustained-start {sustained_token}"
      ).strip() == "ok: dispatched 1"
      wait_log(
          f"WALL_IN_ONE_VM_MOTION_SUSTAINED_START {sustained_token} "
          "items=36 visible=12"
      )
      nature_entries = [
          (
              f"motionbgs:nature-{index}",
              "https://motionbgs.com/i/c/364x205/media/"
              f"{5000 + index}/nature-{index}.3840x2160.jpg",
          )
          for index in range(1, 13)
      ]
      nature_keys = [key for key, _url in nature_entries]
      nature_predicate = (
          ".schema == 1 and (["
          + ",".join(
              f'(.entries[{json.dumps(key)}].provider == "motionbgs" '
              f'and .entries[{json.dumps(key)}].url == {json.dumps(url)} '
              f'and .entries[{json.dumps(key)}].bytes > 0 '
              f'and (.entries[{json.dumps(key)}].filename | type) == "string")'
              for key, url in nature_entries
          )
          + "] | all)"
      )
      try:
          machine.wait_until_succeeds(
              "${lib.getExe pkgs.jq} -e "
              + shlex.quote(nature_predicate)
              + " "
              + shlex.quote(preview_manifest),
              timeout=45,
          )
      except Exception as sustained_error:
          timeout_token = "motion-36-timeout"
          diagnostic_ipc = machine.execute(
              noctalia_command(
                  f"plugin ${pluginId}:hub all vm-motion-sustained-probe {timeout_token}"
              )
          )
          machine.sleep(1)
          diagnostic_log = machine.execute(
              journal
              + " | grep -F -- "
              + shlex.quote(f"WALL_IN_ONE_VM_MOTION_SUSTAINED {timeout_token}")
              + " | tail -n 1"
          )
          sustained_diagnostic = (
              str(diagnostic_log[1] or "").strip() or "<probe unavailable>"
          )
          try:
              manifest_value = json.loads(machine.succeed("cat " + shlex.quote(preview_manifest)))
              manifest_entries = manifest_value.get("entries", {})
              missing_nature = [key for key in nature_keys if key not in manifest_entries]
              manifest_diagnostic = json.dumps({
                  "entries": len(manifest_entries),
                  "nature": len([key for key in manifest_entries if key.startswith("motionbgs:nature-")]),
                  "missing": missing_nature,
              })
          except Exception as manifest_error:
              manifest_diagnostic = "unreadable manifest: " + repr(manifest_error)
          thumbnail_diagnostic = machine.succeed(
              "tail -n 80 " + shlex.quote(thumbnail_log) + " 2>/dev/null || true"
          ).strip()
          watchdog_diagnostic = machine.succeed(
              journal
              + " | grep -E -- "
              + shlex.quote(
                  "exceeded its CPU budget|"
                  "plugin panel '${pluginId}:hub' disabled after repeated timeouts"
              )
              + " | tail -n 20 || true"
          ).strip()
          journal_diagnostic = machine.succeed(journal + " | tail -n 220").strip()
          raise AssertionError(
              "36-result MotionBGS preview sweep did not settle:\n"
              + "IPC exit="
              + str(diagnostic_ipc[0])
              + " output="
              + str(diagnostic_ipc[1] or "").strip()
              + "\n"
              + sustained_diagnostic
              + "\nmanifest:\n"
              + manifest_diagnostic
              + "\nthumbnail helper calls:\n"
              + thumbnail_diagnostic
              + "\nwatchdog markers:\n"
              + (watchdog_diagnostic or "none")
              + "\nrecent journal:\n"
              + journal_diagnostic
          ) from sustained_error

      machine.sleep(2)
      probe_token = "motion-36-settled"
      assert noctalia_msg(
          f"plugin ${pluginId}:hub all vm-motion-sustained-probe {probe_token}"
      ).strip() == "ok: dispatched 1"
      sustained_line = machine.wait_until_succeeds(
          journal
          + " | grep -F -- "
          + shlex.quote(f"WALL_IN_ONE_VM_MOTION_SUSTAINED {probe_token}")
          + " | tail -n 1",
          timeout=10,
      ).strip()
      sustained_fields = {
          part.split("=", 1)[0]: part.split("=", 1)[1]
          for part in sustained_line.split()
          if "=" in part
      }
      assert sustained_fields["items"] == "36", sustained_line
      assert sustained_fields["visible"] == "12", sustained_line
      assert int(sustained_fields["frames"]) > 0, sustained_line
      assert int(sustained_fields["renders"]) >= 2, sustained_line
      assert sustained_fields["initialized"] == "true", sustained_line
      assert sustained_fields["ready"] == "true", sustained_line
      assert sustained_fields["initialization_phase"] == "nil", sustained_line
      assert sustained_fields["initialization_requested"] == "false", sustained_line
      assert sustained_fields["queue"] == "0", sustained_line
      assert sustained_fields["active"] == "0", sustained_line
      assert sustained_fields["dirty"] == "false", sustained_line
      assert sustained_fields["render_pending"] == "false", sustained_line
      assert int(sustained_fields["entries"]) <= 64, sustained_line
      assert 12 <= int(sustained_fields["paths"]) <= 64, sustained_line
      # The preview LRU moved into the backend in 0.8, so the panel no longer
      # tracks per-key recency and reports none. Its own cache population is
      # covered by entries/paths above.
      assert sustained_fields["last_used"] == "nil", sustained_line
      assert sustained_fields["interval"] == "5000", sustained_line
      # Index 0 is the settled state: no sweep is in progress. The limit is the
      # current plan's size, not a panel-side cursor bound.
      assert sustained_fields["sweep"].startswith("0/"), sustained_line
      assert sustained_fields["drag_dirty"] == "false", sustained_line
      assert sustained_fields["open"] == "true", sustained_line
      assert sustained_fields["scope"].startswith("motionbgs:"), sustained_line
      nature_calls = [
          line.split("\t")
          for line in machine.succeed("cat " + shlex.quote(thumbnail_log)).splitlines()
          if "/nature-" in line
      ]
      assert len(nature_calls) == 12, nature_calls
      assert {call[2] for call in nature_calls} == {
          url for _key, url in nature_entries
      }, nature_calls
      settled_frames = int(sustained_fields["frames"])
      settled_renders = int(sustained_fields["renders"])
      machine.sleep(3)
      driven_token = "motion-36-driven"
      assert noctalia_msg(
          f"plugin ${pluginId}:hub all vm-motion-sustained-probe {driven_token}"
      ).strip() == "ok: dispatched 1"
      driven_line = machine.wait_until_succeeds(
          journal
          + " | grep -F -- "
          + shlex.quote(f"WALL_IN_ONE_VM_MOTION_SUSTAINED {driven_token}")
          + " | tail -n 1",
          timeout=10,
      ).strip()
      driven_fields = {
          part.split("=", 1)[0]: part.split("=", 1)[1]
          for part in driven_line.split()
          if "=" in part
      }
      assert int(driven_fields["frames"]) - settled_frames >= 10, driven_line
      assert int(driven_fields["renders"]) == settled_renders, driven_line
      machine.fail(f"{journal} | grep -F -- 'exceeded its CPU budget'")
      machine.fail(
          f"{journal} | grep -F -- \"plugin panel '${pluginId}:hub' disabled after repeated timeouts\""
      )
      assert noctalia_msg(
          f"plugin ${pluginId}:hub all vm-motion-sustained-stop {sustained_token}"
      ).strip() == "ok: dispatched 1"
      wait_log(f"WALL_IN_ONE_VM_MOTION_SUSTAINED_STOP {sustained_token}")

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
          "grep -F 'action = \"capture_w_engine\"' ${materializedRoot}/service.luau"
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
          "script callback 'update' exceeded its CPU budget",
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
