{
  description = "Noctalia v5 plugin source and isolated VM tests";

  inputs = {
    # Track the supported package set; flake.lock records the tested snapshot.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    noctalia = {
      url = "github:noctalia-dev/noctalia/v5.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      noctalia,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hydraVmTest = import ./tests/vm {
        inherit pkgs;
        pluginRoot = ./.;
        noctaliaPackage = noctalia.packages.${system}.default;
      };
      themeVmTest = import ./tests/vm/theme.nix {
        inherit pkgs;
        pluginRoot = ./.;
        noctaliaPackage = noctalia.packages.${system}.default;
      };
    in
    {
      checks.${system} = {
        noctalia-vm = hydraVmTest;
        plugin-theme-vm = themeVmTest;
      };

      packages.${system} = {
        vm-test = hydraVmTest;
        vm-test-driver = hydraVmTest.driverInteractive;
        vm-test-theme = themeVmTest;
        vm-test-theme-driver = themeVmTest.driverInteractive;
      };
    };
}
