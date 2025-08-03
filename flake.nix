{
  description = "Native ComfyUI package (CUDA, low-VRAM flags) with desktop entry";

  inputs = {
    # Core stuff
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";

    # Upstream ComfyUI source – plain git checkout, *not* a flake
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
          config.allowUnfree = true;  # NVIDIA bits, cudnn, etc.
        };

        # ── Python environment ComfyUI needs ───────────────────────────
        pythonEnv = pkgs.python312.withPackages (ps: [
          ps.diffusers
          ps.safetensors
          ps.setuptools
          ps.pip
          ps.opencv-python-headless
          pkgs.pytorchWithCuda                # 2.2 + CUDA 12.1 on 24.05
        ]);

        # ── Launcher (no nix-shell at runtime) ─────────────────────────
        runComfy = pkgs.writeShellScriptBin "run-comfy" ''
          set -euo pipefail

          # One-time GPU switch
          if ! nvidia-smi -q | grep -q "Exclusive"; then
            echo "[run-comfy] Enabling EXCLUSIVE_PROCESS on GPU 0…"
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
          fi

          export WINIT_UNIX_NO_PORTAL=1
          export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
          export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
          export COMFYUI_PORT=8188

          # NixOS quirk: add driver libs
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

        # ── Icon from comfyui.png in repo root ─────────────────────────
        iconPkg = pkgs.stdenv.mkDerivation {
          pname   = "comfyui-icon";
          version = "1";
          src     = ./comfyui.png;                 # ensure the PNG is here
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/icons/hicolor/512x512/apps
            cp $src $out/share/icons/hicolor/512x512/apps/comfyui.png
          '';
        };

        # ── Desktop entry ──────────────────────────────────────────────
        desktopItem = pkgs.makeDesktopItem {
          name        = "comfyui";
          desktopName = "ComfyUI";
          exec        = "${runComfy}/bin/run-comfy";
          icon        = "comfyui";
          comment     = "Launch ComfyUI with CUDA low-VRAM flags";
          categories  = [ "Graphics" "Utility" ];
          terminal    = false;
        };

        # ── Final package bundle ───────────────────────────────────────
        comfyPkg = pkgs.symlinkJoin {
          name  = "comfyui";
          paths = [ runComfy desktopItem iconPkg ];
        };
      in
      {
        # nix build .   → result is ./result/bin/run-comfy
        packages = {
          default  = comfyPkg;
          runComfy = runComfy;
        };

        # nix run .     → launches ComfyUI
        apps.default = flake-utils.lib.mkApp { drv = runComfy; };

        # Tiny NixOS module so other flakes can `imports = [ comfyui.nixosModules.comfyui ];`
        nixosModules.comfyui = { pkgs, ... }: {
          environment.systemPackages = [ self.packages.${pkgs.system}.default ];
        };
      });
}
