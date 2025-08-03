{
  description = "Native ComfyUI package (CUDA, low-VRAM flags) plus desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";

    # Upstream ComfyUI source – NOT a flake
    src = {
      url   = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;     # NVIDIA blobs, cuDNN, etc.
        };

        # Python environment pre-built in the store
        pythonEnv = pkgs.python312.withPackages (ps: [
          pkgs.pytorchWithCuda
          ps.diffusers
          ps.safetensors
          ps.opencv-python-headless
          ps.setuptools ps.pip
        ]);

        # ── launcher ─────────────────────────────────────────────
        runComfy = pkgs.writeShellScriptBin "run-comfy" ''
          set -euo pipefail

          if ! nvidia-smi -q | grep -q "Exclusive"; then
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
          fi

          export WINIT_UNIX_NO_PORTAL=1
          export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
          export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
          export COMFYUI_PORT=8188

          # NixOS driver libs
          if [ -d /run/opengl-driver/lib ]; then
            export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:$LD_LIBRARY_PATH"
          fi

          cd ${src}
          exec ${pythonEnv}/bin/python main.py \
               --lowvram \
               --dont-upcast-attention \
               --force-fp16 \
               --use-split-cross-attention \
               --preview-method auto \
               --reserve-vram 512 \
               --disable-smart-memory
        '';

        # ── icon (repo contains comfyui.png) ─────────────────────
        iconPkg = pkgs.stdenv.mkDerivation {
          pname   = "comfyui-icon";
          version = "1";
          src     = ./comfyui.png;
          dontBuild = true;
          installPhase = ''
            install -Dm644 $src $out/share/icons/hicolor/512x512/apps/comfyui.png
          '';
        };

        # ── .desktop file ───────────────────────────────────────
        desktopItem = pkgs.makeDesktopItem {
          name        = "comfyui";
          desktopName = "ComfyUI";
          exec        = "${runComfy}/bin/run-comfy";
          icon        = "comfyui";
          comment     = "Launch ComfyUI (CUDA, low-VRAM)";
          categories  = [ "Graphics" "Utility" ];
          terminal    = false;
        };

        # bundle everything
        comfyPkg = pkgs.symlinkJoin {
          name  = "comfyui";
          paths = [ runComfy desktopItem iconPkg ];
        };
      in
      {
        # nix build .               → ./result/bin/run-comfy
        packages.default = comfyPkg;
        packages.runComfy = runComfy;

        # nix run .                 → launches ComfyUI
        apps.default = flake-utils.lib.mkApp { drv = runComfy; };

        # importable NixOS module
        nixosModules.default = { pkgs, ... }: {
          environment.systemPackages = [ comfyPkg ];
        };
      });
}
