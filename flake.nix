{
  description = "OpenCircle: circle anything on screen to search, read, translate or ask about it";

  # Linux (X11 and Wayland) only: the flake builds the same single binary that the
  # release ships for Linux. Windows builds stay on the Windows host (cargo xwin,
  # see AGENTS.md); there is no mingw cross build here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    # What the binary links against, plus what winit, iced, the tray and the
    # X11 helpers open by name at runtime (gtk3, appindicator, xkbcommon,
    # Wayland, X11, D-Bus). NixOS has no /usr/lib, so the package wrapper and
    # the dev shell put these on LD_LIBRARY_PATH, and pkg-config finds their
    # -dev outputs at build time.
    runtimeLibs = pkgs:
      with pkgs; [
        gtk3
        glib
        gdk-pixbuf
        libayatana-appindicator # tray icon (dlopen: libayatana-appindicator3.so.1)
        dbus # appindicator's D-Bus menu (dlopen: libdbus-1.so.3)
        libxkbcommon # keyboard (dlopen)
        wayland # Wayland client (dlopen)
        libx11 # X11 client (dlopen)
        libxcb # X11 capture, shape, the live layer (linked)
        libxcursor
        libxi
        libxrandr
        # nixpkgs' cargo setup hook links oniguruma and sqlite3 from the
        # system (RUSTONIG_SYSTEM_LIBONIG, LIBSQLITE3_SYS_USE_PKG_CONFIG)
        # instead of building the crates' vendored copies.
        oniguruma
        sqlite
      ];

    perSystem = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
  in {
    packages = perSystem (
      system: pkgs: let
        opencircle = pkgs.rustPlatform.buildRustPackage {
          pname = "opencircle";
          # Cargo.toml stays at 0.0.0 in git; releases stamp the tag's version.
          version = (lib.importTOML ./Cargo.toml).package.version;

          src = lib.cleanSource ./.;

          # No network in the build: the locked crates come in as one
          # fixed-output derivation. The three patched crates under vendor/
          # are path dependencies and stay part of src.
          cargoLock.lockFile = ./Cargo.lock;
          useFetchCargoVendor = true;

          nativeBuildInputs = [
            pkgs.pkg-config
            # Points GTK at the right GSettings schemas and pixbuf loaders.
            pkgs.wrapGAppsHook3
          ];
          buildInputs = runtimeLibs pkgs;

          # The suite wants empty app data/config dirs and openssl + curl (the
          # install.sh test); CI runs it that way (AGENTS.md). `nix build`
          # stays quick: turn this on to run it in the sandbox as well.
          doCheck = false;

          # wrapGAppsHook3 already wraps the binary; add the dlopen()ed libs.
          preFixup = ''
            gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath (runtimeLibs pkgs)}")
          '';

          # The same app-menu entry and icons the release packages install
          # (packaging/com.opencircle.app.desktop, app id com.opencircle.app).
          postInstall = ''
            install -Dm644 packaging/com.opencircle.app.desktop \
              $out/share/applications/com.opencircle.app.desktop
            for size in 32 64 128 256 512; do
              install -Dm644 "assets/icons/''${size}x''${size}.png" \
                "$out/share/icons/hicolor/''${size}x''${size}/apps/com.opencircle.app.png"
            done
          '';

          meta = {
            description = "Circle anything on screen to search, read, translate or ask about it";
            longDescription = ''
              Circle to Search for the desktop: press a shortcut, circle or drag
              over anything, then search it, read its text, translate it in
              place, or ask an AI about it. A second mode snips and annotates
              screenshots. One native Rust binary, no browser engine inside.
            '';
            homepage = "https://github.com/AmerAlreyahi/OpenCircle";
            license = lib.licenses.mit;
            mainProgram = "opencircle";
            platforms = lib.platforms.linux;
          };
        };
      in {
        inherit opencircle;
        default = opencircle;
      }
    );

    apps = perSystem (system: _: {
      default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/opencircle";
        meta.description = "Circle anything on screen to search, read, translate or ask about it";
      };
    });

    devShells = perSystem (
      system: pkgs: let
        # The package's build inputs (pkg-config, gtk3 and the rest) plus the
        # GTK setup hooks that set GDK_PIXBUF_MODULE_FILE and
        # GSETTINGS_SCHEMAS_PATH for a build and a run from the shell.
        shell = pkgs.mkShell {
          inputsFrom = [self.packages.${system}.default];
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer
            gdk-pixbuf
            gsettings-desktop-schemas
          ];

          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

          shellHook = ''
            # Run `cargo run` / `target/release/opencircle` straight from the shell.
            export LD_LIBRARY_PATH="${lib.makeLibraryPath (runtimeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            echo "OpenCircle dev shell: cargo build --release (tests need empty XDG dirs, see AGENTS.md)"
          '';
        };
      in {
        inherit shell;
        default = shell;
      }
    );

    formatter = perSystem (system: pkgs: pkgs.alejandra);
  };
}
