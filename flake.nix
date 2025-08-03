{
  description = "ComfyUI dev shell + launcher (low-VRAM, CUDA)";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;      # cuDNN, NVIDIA blobs, etc.
        };

        # ── Immutable ComfyUI launcher ─────────────────────────
        runComfy = pkgs.writeShellScriptBin "run-comfy" ''
          set -euo pipefail

          ## Enable exclusive-process on GPU 0 (asks for sudo once)
          if ! nvidia-smi -q | grep -q "Exclusive"; then
            echo "[run-comfy] Enabling EXCLUSIVE_PROCESS on GPU 0…"
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
          fi

          ## Environment tweaks
          export WINIT_UNIX_NO_PORTAL=1
          export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
          export NIXPKGS_ALLOW_UNFREE=1
          export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
          export COMFYUI_PORT=8188

          ## Update repo, then run
          workdir="$HOME/test-shell/ComfyUI"
          cd "$workdir"

          echo "[run-comfy] git pull…"
          git pull --ff-only || echo "[run-comfy] pull failed—running local copy."

          nix-shell ../shell.nix --run "
            python main.py \
              --lowvram \
              --dont-upcast-attention \
              --force-fp16 \
              --use-split-cross-attention \
              --preview-method auto \
              --reserve-vram 512 \
              --disable-smart-memory
          "
        '';

        # ── Dev shell (was shell.nix) ──────────────────────────
        devShell = pkgs.mkShell {
          name = "comfyui-dev-shell";

          buildInputs = with pkgs; [
            python312
            python312Packages.diffusers
            python312Packages.pip
            python312Packages.safetensors
            python312Packages.setuptools
            python312Packages.virtualenv

            git cudatoolkit gcc
            libGL libglvnd mesa opencv
            stdenv.cc.cc.lib zlib
          ];

          shellHook = ''
            export CUDA_HOME=${pkgs.cudatoolkit}

            # Host GPU driver libs (NixOS quirk)
            if [ -d /run/opengl-driver/lib ]; then
              export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:$LD_LIBRARY_PATH"
            fi

            # libstdc++.so.6
            export LD_LIBRARY_PATH="${pkgs.gcc.cc.lib}/lib:$LD_LIBRARY_PATH"

            # One-off venv bootstrap
            if [ ! -d .venv ]; then
              echo "[*] Creating virtualenv…"
              python -m venv .venv
            fi
            source .venv/bin/activate
            echo "[*] Virtualenv activated."

            echo "GPU Status: $(nvidia-smi --query-gpu=name --format=csv,noheader \
                                      || echo 'no GPU detected')"
          '';
        };
      in
      {
        packages    = { inherit runComfy; default = runComfy; };
        apps.default = flake-utils.lib.mkApp { drv = runComfy; };
        devShells.default = devShell;
      });
}
