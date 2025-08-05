{
  description = "Native ComfyUI package (CUDA, low-VRAM flags) + desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";
    src = {
      url   = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, src }:
    let
      # overlay: alias torch → torch-bin
      torchBinOverlay = final: prev: {
        python311Packages = prev.python311Packages // {
          torch        = prev.python311Packages."torch-bin";
          # keep the CUDA-enabled variant visible under both names
          "pytorch-bin" = prev.python311Packages."torch-bin";
        };
      };

      nixosMod = { pkgs, ... }: {
        environment.systemPackages = [ self.packages.${pkgs.system}.default ];
      };
    in

    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ torchBinOverlay ];
        config = { allowUnfree = true; cudaSupport = true; };
      };

      pyEnv = pkgs.python311.withPackages (ps: with ps; [
        (ps."torch-bin")  # binary wheel provides import torch
        diffusers safetensors opencv-python-headless
        setuptools pip
      ]);

      runComfy = pkgs.writeShellScriptBin "run-comfy" ''
        set -euo pipefail
        if command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi -i 0 -c EXCLUSIVE_PROCESS || true
          export LD_LIBRARY_PATH="${pkgs.cudaPackages.cudatoolkit}/lib64:$LD_LIBRARY_PATH"
        fi
        export WINIT_UNIX_NO_PORTAL=1
        export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
        export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
        export COMFYUI_PORT=8188
        cd ${src}
        exec ${pyEnv}/bin/python main.py \
          --lowvram --dont-upcast-attention --force-fp16 \
          --use-split-cross-attention --preview-method auto \
          --reserve-vram 512 --disable-smart-memory
      '';

      iconPkg = pkgs.stdenv.mkDerivation {
        pname   = "comfyui-icon";
        version = "1";
        src     = ./comfyui.png;
        dontUnpack = true;
        dontBuild  = true;
        installPhase = ''
          install -Dm644 "$src" "$out/share/icons/hicolor/512x512/apps/comfyui.png"
        '';
      };

      desktop = pkgs.makeDesktopItem {
        name        = "comfyui";
        desktopName = "ComfyUI";
        exec        = "${runComfy}/bin/run-comfy";
        icon        = "comfyui";
        comment     = "Launch ComfyUI (CUDA, low-VRAM)";
        categories  = [ "Graphics" "Utility" ];
        terminal    = false;
      };

      comfyPkg = pkgs.symlinkJoin {
        name  = "comfyui";
        paths = [ runComfy desktop iconPkg ];
      };
    in
    {
      packages = rec {
        default  = comfyPkg;
        comfyui  = comfyPkg;
        runComfy = runComfy;
      };

      apps.default = flake-utils.lib.mkApp { drv = runComfy; };
    })
    // {
      nixosModules.default = nixosMod;
    };
}
