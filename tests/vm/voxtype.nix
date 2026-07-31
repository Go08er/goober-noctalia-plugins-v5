{
  pkgs,
  noctaliaPackage,
  pluginRoot,
}:

let
  inherit (pkgs) lib;

  testUser = "vmtester";
  runtimeRoot = "/run/noctalia-voxtype-vm";
  stateRoot = "/var/lib/noctalia-voxtype-vm";
  cacheRoot = "/var/cache/noctalia-voxtype-vm";
  guestSourceRoot = "${stateRoot}/plugin-source";
  sourceName = "voxtype-vm";
  sourceUrl = "file://${guestSourceRoot}";
  pluginId = "goober/voxtype-suite";
  serviceId = "${pluginId}:listener";
  widgetId = "${pluginId}:voxtype";
  materializedRoot =
    "${stateRoot}/state/noctalia/plugins/materialized/${sourceName}/voxtype-suite";

  manifest = builtins.fromTOML (
    builtins.readFile (pluginRoot + "/voxtype-suite/plugin.toml")
  );
  catalog = (pkgs.formats.toml { }).generate "voxtype-vm-catalog.toml" {
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
  rawPluginSource = lib.fileset.toSource {
    root = pluginRoot;
    fileset = pluginRoot + "/voxtype-suite";
  };
  stagedSource = pkgs.runCommand "noctalia-voxtype-vm-source" { } ''
    mkdir -p "$out"
    cp -R ${rawPluginSource}/voxtype-suite "$out/voxtype-suite"
    cp ${catalog} "$out/catalog.toml"
  '';

  fakeVoxtype = pkgs.writeShellApplication {
    name = "voxtype";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      {
        printf '%s' "$$"
        for argument in "$@"; do
          printf '\t%q' "$argument"
        done
        printf '\n'
      } >> /tmp/voxtype-vm-calls.log

      if [[ "$#" -ge 1 && "$1" == "status" ]]; then
        printf '%s\n' "$$" >> /tmp/voxtype-vm-followers.log
        touch /tmp/voxtype-vm-status-events
        tail -n +1 -F /tmp/voxtype-vm-status-events
        exit 0
      fi

      if [[ "$#" -eq 1 && "$1" == "--version" ]]; then
        while [[ -e /tmp/voxtype-vm-hold-diagnostics ]]; do
          sleep 0.1
        done
        printf '%s\n' "voxtype 0.7.5-vm-fixture"
        exit 0
      fi

      if [[ "$#" -eq 3 && "$1" == "info" && "$2" == "variants" && "$3" == "--json" ]]; then
        while [[ -e /tmp/voxtype-vm-hold-diagnostics ]]; do
          sleep 0.1
        done
        printf '%s\n' '{"install_kind":"vm-fixture","active_variant":"cpu","compiled_features":["wayland"],"cpu":{"avx2":true,"avx512":false},"gpus":{"nvidia":false,"amd":false},"recommendation":{"primary":"cpu","whisper":"cpu","onnx":"cpu"}}'
        exit 0
      fi

      if [[ "$#" -ge 2 && "$1" == "record" ]]; then
        if [[ -e "/tmp/voxtype-vm-fail-$2" ]]; then
          printf 'fixture failure: %s\n' "$2" >&2
          exit 23
        fi
        exit 0
      fi

      printf 'unexpected voxtype fixture invocation\n' >&2
      exit 64
    '';
  };

  # This is appended only to the materialized guest copy. It exposes internal
  # state for deterministic assertions and two override-validation probes; the
  # production plugin remains untouched.
  vmProbe = pkgs.writeText "voxtype-vm-probe.luau" ''
    local vmProductionOnIpc = onIpc
    local vmCommandSequence = 900000

    function onIpc(event, payload)
        if event == "vm-probe" then
            local vmDiagnostics = noctalia.state.get(DIAGNOSTICS_KEY)
            noctalia.log(
                "VOXTYPE_VM_PROBE "
                    .. tostring(payload or "")
                    .. " state="
                    .. tostring(current.state)
                    .. " raw="
                    .. tostring(current.raw_state)
                    .. " malformed="
                    .. tostring(current.malformed_count)
                    .. " diagnostics_pending="
                    .. tostring(type(vmDiagnostics) == "table" and vmDiagnostics.pending == true)
                    .. " diagnostics_error="
                    .. tostring(type(vmDiagnostics) == "table" and vmDiagnostics.error or "")
            )
        elseif event == "vm-file-override" then
            vmCommandSequence += 1
            handleCommand({
                action = "start",
                sequence = vmCommandSequence,
                overrides = {
                    output = "file",
                    file_path = "/tmp/voice notes/o'clock.txt",
                    model = "parakeet-tdt-0.6b-v3-int8",
                    profile = "work_notes",
                    auto_submit = "on",
                    shift_enter_newlines = "off",
                    smart_auto_submit = "inherit",
                },
            })
        elseif event == "vm-invalid-override" then
            vmCommandSequence += 1
            handleCommand({
                action = "start",
                sequence = vmCommandSequence,
                overrides = {
                    output = "file",
                    file_path = "relative.txt",
                    profile = "bad;touch-pwned",
                },
            })
        elseif type(vmProductionOnIpc) == "function" then
            vmProductionOnIpc(event, payload)
        end
    end
  '';

  pluginRuntimePackages = [
    fakeVoxtype
    pkgs.bash
    pkgs.coreutils
  ];
  noctaliaRuntimePackages = pluginRuntimePackages ++ [ pkgs.git ];

  vmConfig = pkgs.writeText "noctalia-voxtype-vm-config.toml" ''
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
    notify_transitions = false
    notify_failures = false
    tooltip_show_model = true
    tooltip_show_device = true
    tooltip_show_backend = true
    idle_color = "on_surface"
    recording_color = "error"
    transcribing_color = "tertiary"
    stopped_color = "on_surface_variant"
    unknown_color = "tertiary"
    enable_one_shot_overrides = true

    [widget.voxtype-a]
    type = "${widgetId}"
    left_action = "toggle"
    middle_action = "cancel"
    right_action = "panel"
    idle_display = "glyph_text"
    active_label = "rec"
    width_mode = "compact"
    show_override_name = false
    idle_glyph = "microphone"
    active_glyph = "microphone"
    stopped_glyph = "microphone-off"
    unknown_glyph = "help-circle"

    [widget.voxtype-b]
    type = "${widgetId}"
    left_action = "toggle"
    middle_action = "cancel"
    right_action = "none"
    idle_display = "glyph_only"
    active_label = "elapsed"
    width_mode = "expanded"
    show_override_name = true
    idle_glyph = "microphone"
    active_glyph = "wave-sine"
    stopped_glyph = "microphone-off"
    unknown_glyph = "help-circle"

    [bar.voxtype-test]
    start = ["voxtype-a"]
    center = ["voxtype-b"]
    end = []
    reserve_space = false
    hover_highlight = false
  '';

  runner = pkgs.writeShellApplication {
    name = "noctalia-voxtype-vm-run";
    runtimeInputs = noctaliaRuntimePackages;
    text = ''
      install -d -m 0755 \
        "${guestSourceRoot}" \
        "${stateRoot}/state/noctalia" \
        "${stateRoot}/data/noctalia" \
        "${cacheRoot}/noctalia"
      cp -R --no-preserve=ownership ${stagedSource}/. "${guestSourceRoot}/"
      chmod -R u+w "${guestSourceRoot}"
      git -C "${guestSourceRoot}" init --initial-branch=main
      git -C "${guestSourceRoot}" config user.name "Noctalia VM Test"
      git -C "${guestSourceRoot}" config user.email "noctalia-vm@example.invalid"
      git -C "${guestSourceRoot}" add .
      git -C "${guestSourceRoot}" commit -m "VoxType VM fixture"

      : > /tmp/voxtype-vm-calls.log
      : > /tmp/voxtype-vm-followers.log
      printf '%s\n' \
        '{"text":"Idle","alt":"idle","class":"idle","tooltip":"fixture","model":"parakeet-tdt-0.6b-v3-int8","device":"default","backend":"cpu"}' \
        > /tmp/voxtype-vm-status-events
      touch "${stateRoot}/state/noctalia/.setup-complete"

      export NOCTALIA_CONFIG_HOME=/etc/noctalia-voxtype-vm
      export NOCTALIA_STATE_HOME="${stateRoot}/state"
      export NOCTALIA_DATA_HOME="${stateRoot}/data"
      export XDG_CACHE_HOME="${cacheRoot}"
      export NOCTALIA_LOG_LEVEL=debug

      exec "${lib.getExe noctaliaPackage}"
    '';
  };

  swayConfig = pkgs.writeText "noctalia-voxtype-vm-sway.conf" ''
    xwayland disable
    output HEADLESS-1 mode 1280x720
    exec ${lib.getExe runner}
  '';

in
pkgs.testers.runNixOSTest (
  { ... }:
  {
    name = "noctalia-voxtype-suite-vm";

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
          etc."noctalia-voxtype-vm/noctalia/config.toml".source = vmConfig;
          systemPackages = [
            noctaliaPackage
            fakeVoxtype
            pkgs.grim
          ];
        };

        systemd.services.voxtype-daemon-sentinel = {
          description = "Daemon-lifecycle sentinel for VoxType Suite";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${lib.getExe' pkgs.coreutils "sleep"} infinity";
            Restart = "always";
          };
        };

        systemd.services.noctalia-voxtype-vm-session = {
          description = "Isolated Noctalia VoxType Suite test session";
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
            RuntimeDirectory = "noctalia-voxtype-vm";
            RuntimeDirectoryMode = "0700";
            StateDirectory = "noctalia-voxtype-vm";
            CacheDirectory = "noctalia-voxtype-vm";
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
      import json
      import pathlib
      import shlex

      journal = "journalctl -u noctalia-voxtype-vm-session.service -b --no-pager"

      def wait_log(text: str):
          machine.wait_until_succeeds(
              f"{journal} | grep -F -- {shlex.quote(text)}"
          )

      def emit_status(value):
          line = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
          machine.succeed(
              "runuser -u ${testUser} -- sh -c "
              + shlex.quote("printf '%s\\n' " + shlex.quote(line) + " >> /tmp/voxtype-vm-status-events")
          )

      def follower_count(expected: int):
          machine.wait_until_succeeds(
              "alive=0; "
              "while read -r pid; do "
              "  if kill -0 \"$pid\" 2>/dev/null; then alive=$((alive + 1)); fi; "
              "done < /tmp/voxtype-vm-followers.log; "
              f"test \"$alive\" -eq {expected}"
          )

      def calls():
          result = []
          for line in machine.succeed("cat /tmp/voxtype-vm-calls.log").splitlines():
              fields = shlex.split(line)
              result.append(fields[1:])
          return result

      probe_number = [0]
      def wait_state(state: str, raw: str | None = None, malformed: int | None = None):
          probe_number[0] += 1
          token = f"probe-{probe_number[0]}"
          expected = f"VOXTYPE_VM_PROBE {token} state={state}"
          if raw is not None:
              expected += f" raw={raw}"
          if malformed is not None:
              expected += f" malformed={malformed}"
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-probe {token}")
              + " >/dev/null && "
              + f"{journal} | grep -F -- {shlex.quote(expected)}"
          )

      def wait_diagnostics(pending: bool, error: str):
          probe_number[0] += 1
          token = f"diagnostics-{probe_number[0]}"
          expected_token = f"VOXTYPE_VM_PROBE {token}"
          expected_diagnostics = (
              f"diagnostics_pending={str(pending).lower()} diagnostics_error={error}"
          )
          machine.wait_until_succeeds(
              noctalia_command(f"plugin ${serviceId} all vm-probe {token}")
              + " >/dev/null && "
              + f"{journal} | grep -F -- {shlex.quote(expected_token)} "
              + f"| grep -F -- {shlex.quote(expected_diagnostics)}"
          )

      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("voxtype-daemon-sentinel.service")
      machine.wait_for_unit("noctalia-voxtype-vm-session.service")
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
          "${lib.getExe noctaliaPackage} plugins lint ${guestSourceRoot}/voxtype-suite"
      )
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{clean_environment} "
          "${lib.getExe noctaliaPackage} config validate "
          "/etc/noctalia-voxtype-vm/noctalia/config.toml"
      )

      assert noctalia_msg(
          "plugins source add ${sourceName} git ${sourceUrl}"
      ).strip() == "ok"
      assert noctalia_msg("plugins enable ${pluginId}").strip().startswith("ok")
      wait_log("started service '${serviceId}'")
      wait_log('creating #0 "voxtype-test"')
      follower_count(1)

      # Install bounded test probes and ensure service hot reload replaces—not
      # duplicates—the sole long-lived status follower.
      machine.succeed(
          "cat ${materializedRoot}/service.luau ${vmProbe} "
          "> ${materializedRoot}/service.luau.new; "
          "mv ${materializedRoot}/service.luau.new ${materializedRoot}/service.luau"
      )
      wait_log("hot reload: reloaded service '${serviceId}'")
      follower_count(1)
      wait_state("idle", "idle", 0)

      # State-aware toggle and cancel behavior.
      assert noctalia_msg("plugin ${serviceId} all toggle").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds("grep -F $'\\trecord\\tstart' /tmp/voxtype-vm-calls.log")

      emit_status({"alt": "recording", "model": "parakeet", "device": "default", "backend": "cpu"})
      wait_state("recording", "recording", 0)
      assert noctalia_msg("plugin ${serviceId} all toggle").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds("grep -F $'\\trecord\\tstop' /tmp/voxtype-vm-calls.log")

      emit_status({"alt": "streaming"})
      wait_state("streaming", "streaming", 0)
      assert noctalia_msg("plugin ${serviceId} all cancel").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds("grep -F $'\\trecord\\tcancel' /tmp/voxtype-vm-calls.log")

      control_count = len([call for call in calls() if call and call[0] == "record"])
      emit_status({"alt": "transcribing"})
      wait_state("transcribing", "transcribing", 0)
      noctalia_msg("plugin ${serviceId} all toggle")
      machine.sleep(1)
      assert len([call for call in calls() if call and call[0] == "record"]) == control_count

      # Malformed and future status values are bounded and recover on the next
      # valid event without crashing the Luau runtime.
      emit_status("not-json")
      wait_state("transcribing", "transcribing", 1)
      emit_status({"alt": "future-state", "tooltip": "untrusted\\ntext"})
      wait_state("unknown", "future-state", 1)
      emit_status({"alt": "idle", "model": "safe\\nmodel", "device": "default", "backend": "cpu"})
      wait_state("idle", "idle", 1)

      # Diagnostics are explicit and exactly one pair of subprocesses is issued.
      assert noctalia_msg("plugin ${serviceId} all diagnose").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds(
          "test $(grep -Fc $'\\t--version' /tmp/voxtype-vm-calls.log) -eq 1 && "
          "test $(grep -Fc $'\\tinfo\\tvariants\\t--json' /tmp/voxtype-vm-calls.log) -eq 1"
      )
      wait_diagnostics(False, "")

      # Hot reload cancels in-flight diagnostics and repairs the shared pending
      # state so the panel remains retryable rather than spinning forever.
      machine.succeed("touch /tmp/voxtype-vm-hold-diagnostics")
      assert noctalia_msg("plugin ${serviceId} all diagnose").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds(
          "test $(grep -Fc $'\\t--version' /tmp/voxtype-vm-calls.log) -eq 2 && "
          "test $(grep -Fc $'\\tinfo\\tvariants\\t--json' /tmp/voxtype-vm-calls.log) -eq 2"
      )
      wait_diagnostics(True, "")
      machine.succeed("printf '\\n-- vm diagnostics reload\\n' >> ${materializedRoot}/service.luau")
      machine.wait_until_succeeds(
          f"test $({journal} | grep -Fc -- "
          + shlex.quote("hot reload: reloaded service '${serviceId}'")
          + ") -ge 2"
      )
      wait_diagnostics(False, "Diagnostics were interrupted by a plugin reload; run them again.")
      machine.succeed("rm /tmp/voxtype-vm-hold-diagnostics")
      follower_count(1)

      # Shell quoting must preserve the optional --file argument as one token.
      assert noctalia_msg("plugin ${serviceId} all vm-file-override").strip() == "ok: dispatched 1"
      machine.wait_until_succeeds(
          "grep -F -- \"--file=/tmp/voice\\ notes/o\\'clock.txt\" "
          "/tmp/voxtype-vm-calls.log"
      )
      file_calls = [
          call for call in calls()
          if call[:2] == ["record", "start"]
          and "--file=/tmp/voice notes/o'clock.txt" in call
      ]
      assert len(file_calls) == 1, file_calls
      assert "--auto-submit" in file_calls[0]
      assert "--no-shift-enter-newlines" in file_calls[0]

      # Invalid dynamic values fail closed and do not reach VoxType.
      emit_status({"alt": "idle"})
      wait_state("idle", "idle", 1)
      before_invalid = len([call for call in calls() if call and call[0] == "record"])
      noctalia_msg("plugin ${serviceId} all vm-invalid-override")
      machine.sleep(1)
      assert len([call for call in calls() if call and call[0] == "record"]) == before_invalid
      machine.fail("test -e /tmp/touch-pwned")

      # A command failure is surfaced without losing the follower.
      machine.succeed("touch /tmp/voxtype-vm-fail-start")
      noctalia_msg("plugin ${serviceId} all start")
      wait_log("fixture failure: start")
      follower_count(1)

      # Panel creation is a bounded rendering smoke test.
      assert noctalia_msg("panel-toggle ${pluginId}:details").strip().startswith("ok")
      wait_log("panel.luau")
      machine.sleep(1)
      screenshot = "/tmp/noctalia-voxtype-suite-vm.png"
      machine.succeed(
          "runuser -u ${testUser} -- env -i "
          f"{ipc_environment} ${lib.getExe pkgs.grim} -o HEADLESS-1 {screenshot}"
      )
      machine.succeed(f"test $(stat -c %s {screenshot}) -gt 1000")
      machine.copy_from_machine(screenshot)

      logs = machine.succeed(journal)
      for forbidden in (
          "ignoring plugin '${pluginId}'",
          "[luau] ERR",
          "[glyph] missing glyph",
          "undeclared setting",
          "hot reload: failed",
      ):
          assert forbidden not in logs, f"unexpected log marker: {forbidden}"

      # Disabling the plugin kills its follower process group but never the
      # externally owned daemon sentinel.
      assert noctalia_msg("plugins disable ${pluginId}").strip().startswith("ok")
      follower_count(0)
      machine.succeed("systemctl is-active --quiet voxtype-daemon-sentinel.service")

      machine.succeed("systemctl stop noctalia-voxtype-vm-session.service")
      machine.wait_until_fails("pgrep -x noctalia")
    '';
  }
)
