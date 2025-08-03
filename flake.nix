{
  description = "Native ComfyUI package (CUDA, low-VRAM flags) + desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";

    # Upstream source – **plain git**, not a flake
    src = {
      url   = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, src }:
    let
      # 1.  Per-system build
      perSystem = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;   # NVIDIA blobs, cuDNN…
          };

          # Python env ComfyUI wants
          pyEnv = pkgs.python312.withPackages (ps: [
            ps.pytorchWithCuda
            ps.diffusers
            ps.safetensors
            ps.opencv-python-headless
            ps.setuptools ps.pip
          ]);

          # Launcher (no nix-shell)
          runComfy = pkgs.writeShellScriptBin "run-comfy" ''
            set -euo pipefail
            if ! nvidia-smi -q | grep -q Exclusive; then
              sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS
            fi
            export WINIT_UNIX_NO_PORTAL=1
            export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
            export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
            export COMFYUI_PORT=8188
            if [ -d /run/opengl-driver/lib ]; then
              export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:$LD_LIBRARY_PATH"
            fi
            cd ${src}
            exec ${pyEnv}/bin/python main.py \
              --lowvram --dont-upcast-attention --force-fp16 \
              --use-split-cross-attention --preview-method auto \
              --reserve-vram 512 --disable-smart-memory
          '';

          # Icon (comfyui.png lives next to this flake)
          iconPkg = pkgs.stdenv.mkDerivation {
            pname = "comfyui-icon"; version = "1";
            src   = ./comfyui.png;
            dontBuild = true;
            installPhase = ''
              install -Dm644 $src \
                $out/share/icons/hicolor/512x512/apps/comfyui.png
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
            comfyui  = comfyPkg;   # convenience alias
            runComfy = runComfy;
          };

          apps.default = flake-utils.lib.mkApp { drv = runComfy; };
        };

      # 2.  Top-level NixOS module (must NOT be inside per-system block)
      nixosMod = { pkgs, ... }: {
        # Pull the package that matches the host’s system:
        environment.systemPackages =
          let flakePkgs = self.packages.${pkgs.system}; in
          [ flakePkgs.default ];
      };
    in
    # Merge the per-system attr-sets with the top-level module
    flake-utils.lib.eachDefaultSystem perSystem
    // {
      nixosModules = { default = nixosMod; };
    };
}
