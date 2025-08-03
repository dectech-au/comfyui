{
  description = "Native ComfyUI package with desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";
    comfyui    .url = "github:comfyanonymous/ComfyUI";   # upstream code
  };

  outputs = { self, nixpkgs, flake-utils, comfyui }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;        # NVIDIA blobs, cudnn, etc.
        };

        # ── Python env (build-time) ─────────────────────────────
        pythonEnv = pkgs.python312.withPackages (ps: [
          ps.diffusers
          ps.safetensors
          ps.setuptools ps.pip
          pkgs.pytorchWithCuda            # 2.2-cuda-12.1 in 24.05
          ps.opencv-python-headless
        ]);

        # Frozen copy of upstream repo
        comfySrc = pkgs.stdenv.mkDerivation {
          pname = "comfyui-src";
          version = "git";
          src = comfyui;
          dontBuild = true;
          installPhase = ''cp -r $src $out'';
        };

        # Launcher – no nix-shell
        runComfy = pkgs.writeShellScriptBin "run-comfy" ''
          set -euo pipefail

          # one-time GPU switch
          if ! nvidia-smi -q | grep -q "Exclusive"; then
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
          fi

          export WINIT_UNIX_NO_PORTAL=1
          export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
          export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
          export COMFYUI_PORT=8188

          # driver libs (NixOS quirk)
          if [ -d /run/opengl-driver/lib ]; then
            export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:$LD_LIBRARY_PATH"
          fi

          cd ${comfySrc}
          exec ${pythonEnv}/bin/python main.py \
            --lowvram \
            --dont-upcast-attention \
            --force-fp16 \
            --use-split-cross-attention \
            --preview-method auto \
            --reserve-vram 512 \
            --disable-smart-memory
        '';

        # ── Icon (your PNG in repo root) ────────────────────────
        iconPkg = pkgs.stdenv.mkDerivation {
          pname = "comfyui-icon";
          version = "1";
          src = ./comfyui.png;             # ← must exist
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/icons/hicolor/512x512/apps
            cp $src $out/share/icons/hicolor/512x512/apps/comfyui.png
          '';
        };

        # ── .desktop file ───────────────────────────────────────
        desktopItem = pkgs.makeDesktopItem {
          name         = "comfyui";
          desktopName  = "ComfyUI";
          exec         = "${runComfy}/bin/run-comfy";
          icon         = "comfyui";
          comment      = "Launch ComfyUI with CUDA low-VRAM flags";
          categories   = [ "Graphics" "Utility" ];
          terminal     = false;
        };

        # Bundle everything into one installable package
        comfyPkg = pkgs.symlinkJoin {
          name  = "comfyui";
          paths = [ runComfy desktopItem iconPkg ];
        };
      in
      {
        packages = {
          default  = comfyPkg;   # `nix profile install .` gives you launcher+icon+desktop
          runComfy = runComfy;
        };

        apps.default = flake-utils.lib.mkApp { drv = runComfy; };
      });
}
