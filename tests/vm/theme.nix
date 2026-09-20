{ pkgs, noctaliaPackage, pluginRoot }:
let
  inherit (pkgs) lib;
  testUser = "vmtester";
  runtimeRoot = "/run/noctalia-theme-vm";
  stateRoot = "/var/lib/noctalia-theme-vm";
  guestRoot = "${stateRoot}/plugins";
  source = lib.fileset.toSource {
    root = pluginRoot;
    fileset = lib.fileset.unions [
      (pluginRoot + "/catalog.toml")
      (pluginRoot + "/hydra-update-examiner")
      (pluginRoot + "/wall-in-one")
    ];
  };
  fakeCurl = pkgs.writeShellScriptBin "curl" ''
    for argument in "$@"; do
      case "$argument" in https://*) url="$argument" ;; esac
    done
    case "$url" in
      */git-revision) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      */evals) printf '%s\n' '<a href="/eval/4242">latest</a>' ;;
      */eval/4242)
        printf '%s\n' '<span>nixos-unstable.aaaaaaaaaaaa</span>' \
          '<ul class="nav nav-tabs">' '<li>Still Succeeding Jobs (1)</li>' \
          '<div class="tab-content">'
        ;;
      *) exit 22 ;;
    esac
  '';
  fakeWall = pkgs.writeShellScriptBin "wall-in-one" ''
    if [[ "$*" != "ctl status" ]]; then exit 64; fi
    printf '%s\n' '{"status_version":2,"playlist":"Theme fixture","source":"manual","playback_state":"playing","playlists":[],"schedule":{},"schedules":[],"displays":[],"taboo_entries":[]}'
  '';
  runtimePackages = [
    fakeCurl fakeWall pkgs.bash pkgs.coreutils pkgs.jq
    pkgs.perl pkgs.gnugrep pkgs.gawk pkgs.gnused pkgs.util-linux
  ];
  config = pkgs.writeText "noctalia-theme-vm-config.toml" ''
    [shell]
    offline_mode = true
    telemetry_enabled = false
    setup_wizard_enabled = false
    clipboard_enabled = false

    [plugins]
    enabled = []
    auto_update = "none"
    source = []

    [widget.hue]
    type = "goober/hydra-update-examiner:hydra"
    display_mode = "always"
    launched_color = "primary"
    launched_glyph = "circle-filled"

    [widget.wall]
    type = "goober/wall-in-one:wall-in-one"
    display_mode = "always"
    color = "primary"
    glyph = "circle-filled"

    [bar.theme-test]
    start = ["hue"]
    center = []
    end = ["wall"]
    reserve_space = false
    hover_highlight = false
  '';
  runner = pkgs.writeShellApplication {
    name = "noctalia-theme-vm-run";
    runtimeInputs = runtimePackages ++ [ pkgs.git ];
    text = ''
      mkdir -p "${guestRoot}" "${stateRoot}/state/noctalia" "${stateRoot}/data/noctalia"
      cp -R --no-preserve=ownership "${source}/." "${guestRoot}/"
      chmod -R u+w "${guestRoot}"
      git -C "${guestRoot}" init --initial-branch=main
      git -C "${guestRoot}" config user.name 'Theme VM'
      git -C "${guestRoot}" config user.email 'theme-vm@example.invalid'
      git -C "${guestRoot}" add .
      git -C "${guestRoot}" commit -m 'Isolated theme fixture'
      touch "${stateRoot}/state/noctalia/.setup-complete"
      export NOCTALIA_CONFIG_HOME=/etc/noctalia-theme-vm
      export NOCTALIA_STATE_HOME="${stateRoot}/state"
      export NOCTALIA_DATA_HOME="${stateRoot}/data"
      export XDG_CACHE_HOME="${stateRoot}/cache"
      export NOCTALIA_LOG_LEVEL=debug
      exec ${lib.getExe noctaliaPackage}
    '';
  };
  swayConfig = pkgs.writeText "noctalia-theme-vm-sway.conf" ''
    xwayland disable
    output HEADLESS-1 mode 1600x1000
    exec ${lib.getExe runner}
  '';
  testPython = pkgs.python3.withPackages (p: [ p.pillow ]);
  checkPixels = pkgs.writeText "noctalia-theme-pixels.py" ''
    from PIL import Image
    import sys
    image = Image.open(sys.argv[1]).convert("RGB")
    expected = tuple(bytes.fromhex(sys.argv[2]))
    regions = [(0, 0, 533, 50), (1067, 0, 1600, 50)]
    regions.append((0, 50, 1600, 1000))
    for name, region in zip(("HUE widget", "Wall widget", "open panel"), regions):
        count = sum(max(abs(a-b) for a,b in zip(pixel, expected)) <= 2
                    for pixel in image.crop(region).get_flattened_data())
        assert count > 8, f"{name}: expected live primary {expected}, found only {count} pixels"
    print("All widgets and the open panel use the current primary color")
  '';
in
pkgs.testers.runNixOSTest {
  name = "noctalia-plugin-theme-vm";
  nodes.machine = { pkgs, ... }: {
    users.users.${testUser} = { isNormalUser = true; uid = 1000; home = "/home/${testUser}"; };
    services.dbus.enable = true;
    hardware.graphics.enable = true;
    fonts.packages = [ pkgs.dejavu_fonts ];
    environment.etc."noctalia-theme-vm/noctalia/config.toml".source = config;
    environment.systemPackages = [ noctaliaPackage pkgs.grim pkgs.jq ];
    systemd.services.noctalia-theme-vm-session = {
      wantedBy = [ "multi-user.target" ];
      after = [ "dbus.service" "systemd-user-sessions.service" ];
      requires = [ "dbus.service" ];
      path = [ pkgs.dbus pkgs.bash ];
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
        RuntimeDirectory = "noctalia-theme-vm";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "noctalia-theme-vm";
        ExecStart = "${pkgs.dbus}/bin/dbus-run-session -- ${lib.getExe pkgs.sway} --unsupported-gpu --config ${swayConfig}";
        KillMode = "control-group";
        TimeoutStopSec = 5;
      };
    };
    virtualisation = { cores = 2; memorySize = 2048; };
  };
  testScript = ''
    import json
    import os
    import pathlib
    import shlex

    start_all()
    machine.wait_for_unit("noctalia-theme-vm-session.service")
    machine.wait_until_succeeds("find ${runtimeRoot} -maxdepth 1 -name 'noctalia-wayland-*.sock' | grep -q .")
    socket = machine.succeed("find ${runtimeRoot} -maxdepth 1 -name 'noctalia-wayland-*.sock' -print -quit").strip()
    display = pathlib.Path(socket).name.removeprefix("noctalia-").removesuffix(".sock")
    environment = "HOME=/home/${testUser} PATH=/run/current-system/sw/bin XDG_RUNTIME_DIR=${runtimeRoot} " + "WAYLAND_DISPLAY=" + shlex.quote(display)
    command = "runuser -u ${testUser} -- env -i " + environment
    def msg(arguments):
        return machine.succeed(command + " ${lib.getExe noctaliaPackage} msg " + arguments).strip()
    reconciled_commands = []
    def ok(arguments, readback, expected, settle=0):
        response = msg(arguments)
        # The pinned CLI returns exit 0 with an empty reply on its 2s read
        # timeout. Treat that as unknown outcome, never replay a mutator.
        assert not response or response.startswith("ok"), f"{arguments}: {response!r}"
        if settle:
            machine.sleep(settle)
        observed = readback()
        assert observed == expected, f"{arguments}: expected {expected!r}, observed {observed!r}"
        if not response:
            reconciled_commands.append(arguments)
            print(f"{arguments}: empty IPC acknowledgment; one read-only query confirmed state")

    assert msg("plugins source add theme-vm git file://${guestRoot}") == "ok"
    for plugin in ("hydra-update-examiner", "wall-in-one"):
        assert msg("plugins enable goober/" + plugin).startswith("ok")
    journal = "journalctl -u noctalia-theme-vm-session.service -b --no-pager"
    for entry in ("hydra-update-examiner:status", "wall-in-one:control"):
        machine.wait_until_succeeds(journal + " | grep -F " + shlex.quote("started service 'goober/" + entry + "'"))
    machine.sleep(2)

    # These primary RGB values come from the pinned host's builtin palettes.
    # Check foreground pixels, not just a background/screenshot hash change.
    phases = (("Noctalia", "dark", "fff59b"), ("Dracula", "dark", "bd93f9"),
              ("Noctalia", "light", "5d65f5"), ("Noctalia", "dark", "fff59b"))
    panels = ("goober/hydra-update-examiner:actions", "goober/wall-in-one:controls")
    for index, panel in enumerate(panels):
        ok("panel-open " + panel, lambda: json.loads(msg("status"))["activePanelId"], panel)
        machine.sleep(1)
        assert json.loads(msg("status"))["activePanelId"] == panel
        for phase, (scheme, mode, primary) in enumerate(phases):
            if msg("color-scheme-get") != "builtin " + scheme:
                ok("color-scheme-set builtin " + scheme, lambda: msg("color-scheme-get"), "builtin " + scheme)
                machine.sleep(1)
            if msg("theme-mode-get") != mode:
                ok("theme-mode-set " + mode, lambda: msg("theme-mode-get"), mode)
            machine.sleep(1)
            assert msg("color-scheme-get") == "builtin " + scheme
            assert msg("theme-mode-get") == mode
            assert json.loads(msg("status"))["activePanelId"] == panel, "theme switch closed the existing panel"
            screenshot = f"/tmp/plugin-theme-{index}-{phase}.png"
            machine.succeed(command + " ${lib.getExe pkgs.grim} -o HEADLESS-1 " + screenshot)
            machine.copy_from_machine(screenshot)
            machine.succeed("${testPython}/bin/python ${checkPixels} " + screenshot + " " + primary)
        # The host clears activePanelId only after its normal close animation.
        ok("panel-close", lambda: json.loads(msg("status"))["activePanelId"], None, settle=1)

    pathlib.Path(os.environ["out"], "ipc-reconciliation.json").write_text(
        json.dumps({"empty_acknowledgment_commands": reconciled_commands}, indent=2) + "\n"
    )

    logs = machine.succeed(journal)
    for forbidden in ("ignoring plugin 'goober/", "[luau] ERR",
                      "[glyph] missing glyph", "undeclared setting"):
        assert forbidden not in logs, f"unexpected log marker: {forbidden}"
    assert "hot reload:" not in logs, "scheme changes must not rely on plugin hot reload"
  '';
}
