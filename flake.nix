{
  description = "Native ComfyUI package (CUDA, low-VRAM flags) + desktop entry";

  inputs = {
    nixpkgs     .url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils .url = "github:numtide/flake-utils";

    # Upstream source – plain git, not a flake
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
        config = { allowUnfree = true; cudaSupport = true; };
      };

      # Python env — stay on 3.11 until CUDA wheels land for 3.12
      pyEnv = pkgs.python311.withPackages (ps: [
        ps.pytorch-bin               # CUDA-enabled wheel
        ps.diffusers
        ps.safetensors
        ps.opencv-python-headless
        ps.setuptools ps.pip
      ]);

      # Runtime wrapper
      runComfy = pkgs.writeShellScriptBin "run-comfy" ''
        set -euo pipefail
        # Flip GPU to exclusive mode if NVIDIA is present
        if command -v nvidia-smi >/dev/null 2>&1; then
          if ! nvidia-smi -q | grep -q Exclusive; then
            sudo nvidia-smi -i 0 -c EXCLUSIVE_PROCESS || true
          fi
        fi

        export WINIT_UNIX_NO_PORTAL=1
        export __GL_FRAMEBUFFER_SRGB_CAPABLE=1
        export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:64
        export COMFYUI_PORT=8188

        # Ensure CUDA libs show up at runtime
        export LD_LIBRARY_PATH="${pkgs.cudaPackages.cudatoolkit}/lib64:$LD_LIBRARY_PATH"

        cd ${src}
        exec ${pyEnv}/bin/python main.py \
          --lowvram --dont-upcast-attention --force-fp16 \
          --use-split-cross-attention --preview-method auto \
          --reserve-vram 512 --disable-smart-memory
      '';

      # Icon (expects comfyui.png next to this flake)
      iconPkg = pkgs.stdenv.mkDerivation {
        pname   = "comfyui-icon";
        version = "1";
        src     = ./comfyui.png;

        dontUnpack = true;
        dontBuild  = true;

        installPhase = ''
          install -Dm644 "$src" \
            "$out/share/icons/hicolor/512x512/apps/comfyui.png"
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
        comfyui  = comfyPkg;   # alias
        runComfy = runComfy;
      };

      apps.default = flake-utils.lib.mkApp { drv = runComfy; };

      nixosModules.default = { pkgs, ... }: {
        environment.systemPackages = [ self.packages.${pkgs.system}.default ];
      };
    });
}
