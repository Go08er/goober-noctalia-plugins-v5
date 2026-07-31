{
  description = "Noctalia v5 plugin source and isolated VM tests";

  inputs = {
    # Match the Nixpkgs snapshot used by the tagged beta.7 host.
    nixpkgs.url =
      "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1040357.e2587caef70c/nixexprs.tar.xz";

    noctalia = {
      url = "github:noctalia-dev/noctalia/c366a35ffc30b011d03fcd122bbe7d22f932fc57";
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
      voxtypeVmTest = import ./tests/vm/voxtype.nix {
        inherit pkgs;
        pluginRoot = ./.;
        noctaliaPackage = noctalia.packages.${system}.default;
      };
      wallpaperVmTest = import ./tests/vm/wallpaper.nix {
        inherit pkgs;
        pluginRoot = ./.;
        noctaliaPackage = noctalia.packages.${system}.default;
      };
    in
    {
      checks.${system} = {
        noctalia-vm = hydraVmTest;
        voxtype-vm = voxtypeVmTest;
        wallpaper-vm = wallpaperVmTest;
      };

      packages.${system} = {
        vm-test = hydraVmTest;
        vm-test-driver = hydraVmTest.driverInteractive;
        vm-test-voxtype = voxtypeVmTest;
        vm-test-voxtype-driver = voxtypeVmTest.driverInteractive;
        vm-test-wallpaper = wallpaperVmTest;
        vm-test-wallpaper-driver = wallpaperVmTest.driverInteractive;
      };
    };
}
