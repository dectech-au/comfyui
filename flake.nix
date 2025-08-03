{
  description = "Native ComfyUI package + desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";

    # ← plain git checkout, **NOT** a flake
    comfySrc = {
      url   = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, comfySrc }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        pythonEnv = pkgs.python312.withPackages (ps: [
          ps.diffusers ps.safetensors ps.setuptools ps.pip
          pkgs.pytorchWithCuda
          ps.opencv-python-headless
        ]);

        runComfy = pkgs.writeShellScriptBin "run-comfy" ''
          set -euo pipefail
          if ! nvidia-smi -q | grep -q "Exclusive"; then
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
          fi
          export WINIT_UNIX_NO_PORTAL=1
          export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
          export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
          export COMFYUI_PORT=8188
          cd ${comfySrc}
          exec ${pythonEnv}/bin/python main.py \
               --lowvram --dont-upcast-attention --force-fp16 \
               --use-split-cross-attention --preview-method auto \
               --reserve-vram 512 --disable-smart-memory
        '';

        iconPkg = pkgs.stdenv.mkDerivation {
          pname = "comfyui-icon"; version = "1";
          src   = ./comfyui.png;           # PNG lives beside this flake
          dontBuild     = true;
          installPhase  = ''
            mkdir -p $out/share/icons/hicolor/512x512/apps
            cp $src $out/share/icons/hicolor/512x512/apps/comfyui.png
          '';
        };

        desktopItem = pkgs.makeDesktopItem {
          name        = "comfyui";
          desktopName = "ComfyUI";
          exec        = "${runComfy}/bin/run-comfy";
          icon        = "comfyui";
          comment     = "Launch ComfyUI with CUDA low-VRAM flags";
          categories  = [ "Graphics" "Utility" ];
          terminal    = false;
        };

        comfyPkg = pkgs.symlinkJoin {
          name  = "comfyui";
          paths = [ runComfy desktopItem iconPkg ];
        };
      in
      {
        packages = {
          default  = comfyPkg;
          runComfy = runComfy;
        };

        apps.default = flake-utils.lib.mkApp { drv = runComfy; };

        # tiny NixOS module so your top-level flake can just import it
        nixosModules.comfyui = { pkgs, ... }: {
          environment.systemPackages = [ self.packages.${pkgs.system}.default ];
        };
      });
}
