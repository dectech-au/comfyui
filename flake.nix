{
  description = "ComfyUI (CUDA, low-VRAM) with a zero-compile PyTorch wheel";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/release-24.05";
    flake-utils.url = "github:numtide/flake-utils";

    src = {
      url   = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, src }:
    let
  # ----------------------------------------------------------------------------
  # 1.  Overlay that replaces *all* PyTorch names with the CUDA wheel
  # ----------------------------------------------------------------------------
  torchOverlay = final: prev:
    let
      py = prev.python311;
      torchWheel = py.buildPythonPackage rec {
        pname   = "torch";
        version = "2.7.1+cu121";
        format  = "wheel";
        src = prev.fetchurl {
          url  = "https://download.pytorch.org/whl/cu121/torch-2.7.1%2Bcu121-cp311-cp311-linux_x86_64.whl";
          hash = "sha256-Vf+uL6bDS60AhbUlRi1eEM57x8rXnD96/7l2PG0w8Kw=";
        };
        nativeBuildInputs      = [ py.pkgs.setuptools ];
        propagatedBuildInputs  = [ prev.cudaPackages.cudatoolkit ];
      };
    in {
      python311Packages = prev.python311Packages // {
        torch            = torchWheel;   # import torch
        pytorch          = torchWheel;   # nixpkgs name used by diffusers
        "torch-bin"      = torchWheel;   # keep explicit alias
        pytorchWithCuda  = torchWheel;   # belt-and-suspenders
      };
    };


      # ----------------------------------------------------------------------------
      # 2.  NixOS module
      # ----------------------------------------------------------------------------
      nixosMod = { pkgs, ... }: {
        environment.systemPackages =
          [ self.packages.${pkgs.system}.default ];
      };
    in

    # ----------------------------------------------------------------------------
    # 3.  Per-system outputs
    # ----------------------------------------------------------------------------
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ torchOverlay ];
        config   = { allowUnfree = true; cudaSupport = true; };
      };

      pyEnv = pkgs.python311.withPackages (ps: with ps; [
        torch     # resolves to wheel we just injected
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
        pname = "comfyui-icon";
        version = "1";
        src = ./comfyui.png;
        dontUnpack = true;
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
