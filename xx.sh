#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
NIXPKGS_BRANCH="nixos-24.05" 
HM_STATE_VERSION="24.05"
HOME_MANAGER_RELEASE_TAG="release-${HM_STATE_VERSION}"

# --- Global variable to hold the username ---
CONFIGURED_USERNAME=""
BACKUP_SUFFIX="hm-script-bak" # Define a global backup suffix

# --- Helper Functions ---
log_info() { echo "INFO: $1" >&2; }
log_warn() { echo "WARN: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; exit 1; }

# --- 0. Initial Nix Version Check ---
check_initial_nix_version() {
    log_info "NIX VERSION AT SCRIPT START: $(nix --version || echo 'Nix not found (this is okay if installing now)')"
}

# --- 1. Ensure Nix is Installed (Single-User) ---
ensure_nix_installed() {
    if command -v nix &>/dev/null; then
        log_info "Nix is already installed (version: $(nix --version)). Skipping Nix installation."
        NIX_PROFILE_SCRIPT_PATHS=(
            "$HOME/.nix-profile/etc/profile.d/nix-daemon.sh"
            "$HOME/.local/state/nix/profile/etc/profile.d/nix-daemon.sh"
            "$HOME/.nix-profile/etc/profile.d/nix.sh"
            "/etc/profile.d/nix.sh"
        )
        SOURCED_NIX=false
        for NIX_PROFILE_SCRIPT in "${NIX_PROFILE_SCRIPT_PATHS[@]}"; do
            if [ -f "$NIX_PROFILE_SCRIPT" ]; then
                log_info "Sourcing existing Nix profile script: $NIX_PROFILE_SCRIPT"
                # shellcheck source=/dev/null
                . "$NIX_PROFILE_SCRIPT"; SOURCED_NIX=true; break
            fi
        done
        if [ "$SOURCED_NIX" = false ]; then
             log_warn "Could not find a standard Nix profile script to source for the current session. Nix commands might not be available if PATH is not already set."
        fi
        return
    fi

    log_info "Nix not found. Attempting single-user Nix installation."
    echo "--------------------------------------------------------------------------------" >&2
    echo "Nix works best if its store is at /nix. This requires creating /nix and" >&2
    echo "giving your user ownership *once* using sudo:" >&2
    echo "  sudo mkdir -m 0755 /nix" >&2
    echo "  sudo chown $(whoami) /nix" >&2
    echo "--------------------------------------------------------------------------------" >&2
    read -rp "Do you want to attempt creating /nix with sudo (recommended, one-time)? [y/N]: " choice
    if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
        log_info "Attempting to create and chown /nix for user $(whoami)."
        if sudo mkdir -m 0755 /nix && sudo chown "$(whoami)" /nix; then
            log_info "/nix directory created and ownership set."
        else
            log_warn "/nix directory creation/chown failed. Nix installer will likely use ~/.nix or ~/.local/state/nix."
        fi
    else
        log_info "Skipping sudo /nix creation. Nix installer will choose the path."
    fi

    log_info "Starting Nix single-user installer (using --no-daemon)..."
    curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

    log_info "Nix installation script finished."
    echo "IMPORTANT: The Nix installer should have modified your shell configuration file (e.g., ~/.bashrc, ~/.zshrc)." >&2
    echo "           You will need to RE-LOGIN or source it (e.g., 'source ~/.bashrc') in ALL new terminals for 'nix' to be found." >&2
    echo "           The installer usually suggests a line like: '. $HOME/.nix-profile/etc/profile.d/nix.sh' or '. $HOME/.nix-profile/etc/profile.d/nix-daemon.sh'" >&2
    echo "           Please ensure such a line is present and active in your shell's startup file." >&2

    echo "INFO: Sourcing Nix environment for the *current script session*..." >&2
    NIX_PROFILE_SCRIPT_NEW_INSTALLER_DAEMON="$HOME/.nix-profile/etc/profile.d/nix-daemon.sh"
    NIX_PROFILE_SCRIPT_NEW_INSTALLER_NO_NIX_DAEMON="$HOME/.local/state/nix/profile/etc/profile.d/nix-daemon.sh"
    NIX_PROFILE_SCRIPT_LEGACY="$HOME/.nix-profile/etc/profile.d/nix.sh" 

    SOURCED_NIX=false
    if [ -f "$NIX_PROFILE_SCRIPT_NEW_INSTALLER_DAEMON" ]; then
        # shellcheck source=/dev/null
        . "$NIX_PROFILE_SCRIPT_NEW_INSTALLER_DAEMON"; SOURCED_NIX=true
        log_info "Sourced Nix (daemon-style profile) for script: $NIX_PROFILE_SCRIPT_NEW_INSTALLER_DAEMON"
    elif [ -f "$NIX_PROFILE_SCRIPT_NEW_INSTALLER_NO_NIX_DAEMON" ]; then
        # shellcheck source=/dev/null
        . "$NIX_PROFILE_SCRIPT_NEW_INSTALLER_NO_NIX_DAEMON"; SOURCED_NIX=true
        log_info "Sourced Nix (daemon-style profile, no /nix dir) for script: $NIX_PROFILE_SCRIPT_NEW_INSTALLER_NO_NIX_DAEMON"
    elif [ -f "$NIX_PROFILE_SCRIPT_LEGACY" ]; then
        # shellcheck source=/dev/null
        . "$NIX_PROFILE_SCRIPT_LEGACY"; SOURCED_NIX=true
        log_info "Sourced Nix (legacy profile) for script: $NIX_PROFILE_SCRIPT_LEGACY"
    fi
    
    if [ "$SOURCED_NIX" = false ]; then
        log_error "Nix profile script not found after installation attempt for the current script session."
    fi

    if ! command -v nix &>/dev/null; then log_error "Nix command not found for script session. A shell restart is likely required."; fi
    log_info "Nix successfully installed/sourced for this script (version: $(nix --version))."
}

# --- 2. Ensure Nix Flakes & New Command are Enabled (for future global use) ---

# --- 2. Ensure Nix Flakes & New Command are Enabled (for future global use) ---
ensure_flakes_enabled() {
    log_info "Ensuring Nix experimental features (nix-command flakes) are enabled in ~/.config/nix/nix.conf for future sessions..."
    local NIX_CONF_DIR="$HOME/.config/nix"
    local NIX_CONF_PATH="$NIX_CONF_DIR/nix.conf"
    local DESIRED_FEATURE_NIX_COMMAND="experimental-features = nix-command"
    local DESIRED_FEATURE_FLAKES="experimental-features = flakes" 
    
    # Ensure the directory exists
    if ! mkdir -p "$NIX_CONF_DIR"; then
        log_error "Failed to create directory $NIX_CONF_DIR. Please check permissions."
        return 1 # Or exit 1 if you prefer immediate script termination
    fi
    log_info "Ensured directory $NIX_CONF_DIR exists."

    # Ensure the file exists before trying to sed it (especially for sed -i)
    if ! touch "$NIX_CONF_PATH"; then
        log_error "Failed to touch/create $NIX_CONF_PATH. Please check permissions."
        return 1
    fi
    log_info "Ensured file $NIX_CONF_PATH exists (may be empty)."
    
    # Remove old experimental-features lines to avoid duplicates or conflicts
    # This ensures a clean state if the script is re-run
    # The check `if [ -f "$NIX_CONF_PATH" ]` is technically redundant now after `touch`,
    # but sed might behave differently on an empty file vs a non-existent one for some versions.
    # Keeping it for clarity or removing it should be fine. Let's be explicit.
    if [ -f "$NIX_CONF_PATH" ]; then
        log_info "Removing existing 'experimental-features' lines from $NIX_CONF_PATH (if any)..."
        # Use a temporary file for sed to avoid issues with some sed -i implementations on empty files
        local TEMP_SED_FILE
        TEMP_SED_FILE=$(mktemp)
        if sed '/^experimental-features\s*=/d' "$NIX_CONF_PATH" > "$TEMP_SED_FILE"; then
            if ! mv "$TEMP_SED_FILE" "$NIX_CONF_PATH"; then
                log_error "Failed to move temp sed output back to $NIX_CONF_PATH."
                rm -f "$TEMP_SED_FILE"
                return 1
            fi
            log_info "Cleaned 'experimental-features' from $NIX_CONF_PATH."
        else
            log_warn "sed command failed while trying to clean $NIX_CONF_PATH. Proceeding to append."
            rm -f "$TEMP_SED_FILE" # Clean up temp file on sed failure
        fi
    else
        # This case should not be reached if `touch` succeeded.
        log_warn "$NIX_CONF_PATH does not exist even after touch. This is unexpected. Proceeding to append."
    fi

    log_info "Appending desired experimental features to $NIX_CONF_PATH..."
    if ! (echo "$DESIRED_FEATURE_NIX_COMMAND" >> "$NIX_CONF_PATH" && \
          echo "$DESIRED_FEATURE_FLAKES" >> "$NIX_CONF_PATH"); then
        log_error "Failed to append features to $NIX_CONF_PATH. Please check permissions."
        return 1
    fi
    log_info "Set in $NIX_CONF_PATH: nix-command and flakes experimental features."

    # Test flake evaluation
    log_info "Testing flake evaluation with 'nix eval --extra-experimental-features nix-command --extra-experimental-features flakes nixpkgs#hello'..."
    if nix eval --raw --extra-experimental-features nix-command --extra-experimental-features flakes nixpkgs#hello > /dev/null 2>&1; then
       log_info "Flakes/nix-command seem active for the current Nix client when flags are passed explicitly."
    else
       log_warn "Flake evaluation test failed even with explicit flags. This is unexpected."
    fi
}




# --- 3. Setup Home Manager Configuration ---
setup_home_manager_config() {
    log_info "DEBUG: Entering setup_home_manager_config."
    local DETECTED_USERNAME_RAW; DETECTED_USERNAME_RAW=$(whoami);
    local DETECTED_USERNAME; DETECTED_USERNAME=$(echo "$DETECTED_USERNAME_RAW" | tr -d '[:space:]\r\n');
    if [ -z "$DETECTED_USERNAME" ]; then log_error "FATAL: Sanitized DETECTED_USERNAME empty."; fi

    read -rp "Please enter your Ubuntu username (default: $DETECTED_USERNAME): " INPUT_USERNAME;
    if [ -z "$INPUT_USERNAME" ]; then CONFIGURED_USERNAME="$DETECTED_USERNAME";
    else CONFIGURED_USERNAME="$INPUT_USERNAME"; fi
    log_info "Using username: '$CONFIGURED_USERNAME'"

    if [ -z "$CONFIGURED_USERNAME" ]; then log_error "FATAL: CONFIGURED_USERNAME is empty."; fi

    local HM_CONFIG_DIR="$HOME/.config/home-manager"; mkdir -p "$HM_CONFIG_DIR"

    log_info "Creating Home Manager flake: '$HM_CONFIG_DIR/flake.nix' for user '$CONFIGURED_USERNAME'"
    cat <<EOF > "$HM_CONFIG_DIR/flake.nix"
{
  description = "Home Manager configuration for $CONFIGURED_USERNAME";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/$NIXPKGS_BRANCH";
    home-manager = {
      url = "github:nix-community/home-manager/$HOME_MANAGER_RELEASE_TAG";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, home-manager, ... }@inputs:
  let system = "x86_64-linux";
  in {
    homeConfigurations."$CONFIGURED_USERNAME" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.\${system};
      extraSpecialArgs = { inherit system; USERNAME = "$CONFIGURED_USERNAME"; };
      modules = [ ./home.nix ];
    };
  };
}
EOF

    log_info "Creating Home Manager home.nix: '$HM_CONFIG_DIR/home.nix' for user '$CONFIGURED_USERNAME'"
    cat <<EOF > "$HM_CONFIG_DIR/home.nix"
{ config, pkgs, lib, USERNAME, ... }:
let
  # pkgs.php is usually an alias to the default PHP version in the Nixpkgs channel (e.g., php82 for 24.05)
  phpEnv = pkgs.php; 
  # If you need a specific PHP version, uncomment and use one of these:
  # phpEnv = pkgs.php82; # For PHP 8.2
  # phpEnv = pkgs.php83; # For PHP 8.3
in
{
  home.username = USERNAME;
  home.homeDirectory = "/home/\${USERNAME}"; # Uses shell-style variable expansion for USERNAME
  home.stateVersion = "$HM_STATE_VERSION";

  programs.home-manager.enable = true;

  nix = {
    package = pkgs.nix; # Manage nix itself via home-manager
    settings = {
      show-trace = true;
      # experimental-features = "nix-command flakes"; # This is managed by ensure_flakes_enabled in ~/.config/nix/nix.conf
                                                     # If you want HM to strictly enforce it, uncomment.
    };
  };

  home.packages = [ 
    phpEnv                   # PHP interpreter
    phpEnv.packages.composer # Composer for the selected PHP
    pkgs.nnn                 # nnn file manager
    pkgs.nodejs              # Node.js (latest stable/LTS from this Nixpkgs branch)
    # pkgs.yarn              # Optional: if you use Yarn
    # pkgs.pnpm              # Optional: if you use PNPM
  ];

  # Example: managing shell configuration
  programs.bash.enable = true; # If you use bash
  # programs.zsh.enable = true;  # If you use zsh, uncomment this and comment out bash
  # programs.fish.enable = true; # If you use fish

  # You can also manage dotfiles:
  # home.file.".config/mytool/config.toml".text = ''
  #   setting = "my value"
  # '';
}
EOF
    log_info "Home Manager config files created in '$HM_CONFIG_DIR'"
}

# --- 4. Apply Home Manager Configuration ---
apply_home_manager_config() {
    log_info "NIX VERSION IN APPLY_HOME_MANAGER (initial check): $(nix --version || echo 'Nix cmd not found in apply_home_manager_config function start')"
    if [ -z "$CONFIGURED_USERNAME" ]; then log_error "Username not set. Cannot apply Home Manager configuration."; return 1; fi

    local HM_CONFIG_DIR_ABS="$HOME/.config/home-manager"
    local FLAKE_TARGET="${HM_CONFIG_DIR_ABS}#${CONFIGURED_USERNAME}"

    local NIX_EXECUTABLE
    if command -v nix &>/dev/null; then
        NIX_EXECUTABLE=$(command -v nix)
        log_info "Using Nix executable found in PATH for apply_home_manager_config: $NIX_EXECUTABLE"
    elif [ -x "$HOME/.nix-profile/bin/nix" ]; then
        NIX_EXECUTABLE="$HOME/.nix-profile/bin/nix"
        log_warn "Nix command not found in PATH within apply_home_manager_config, using direct path: $NIX_EXECUTABLE"
    else
        log_error "Nix executable not found by any means. Cannot proceed with Home Manager application."
        return 1
    fi
    
    log_info "NIX VERSION VIA RESOLVED EXECUTABLE ($NIX_EXECUTABLE) in apply_home_manager_config: $($NIX_EXECUTABLE --version || echo 'Failed to get version from direct path')"

    log_info "Attempting to apply Home Manager config for user '$CONFIGURED_USERNAME' using flake target '$FLAKE_TARGET'."
    echo "This might take a while, especially on the first run..." >&2

    local temp_nix_config_content="experimental-features = nix-command flakes"

    if ! NIX_CONFIG="$temp_nix_config_content" \
        "$NIX_EXECUTABLE" \
        --extra-experimental-features nix-command \
        --extra-experimental-features flakes \
        run "github:nix-community/home-manager/${HOME_MANAGER_RELEASE_TAG}" \
        -- \
        switch --flake "$FLAKE_TARGET" -b "$BACKUP_SUFFIX" --show-trace; then 
        log_warn "Initial '$NIX_EXECUTABLE run home-manager ... switch' command failed."
        return 1
    fi
    log_info "Home Manager configuration applied successfully. Existing conflicting files were backed up with suffix '.${BACKUP_SUFFIX}'."
}

# --- Main Script Execution ---
main() {
    check_initial_nix_version
    ensure_nix_installed 
    ensure_flakes_enabled 
    
    if ! setup_home_manager_config; then
        log_error "Failed to setup Home Manager configuration files. Aborting."
    fi
    
    log_info "DEBUG: Back in main, global CONFIGURED_USERNAME is '$CONFIGURED_USERNAME'"
    if [ -z "$CONFIGURED_USERNAME" ]; then
        log_error "CRITICAL: Username was not configured. Cannot proceed."
    fi

    if ! apply_home_manager_config; then
        log_warn "Home Manager application reported an issue. See messages above."
        echo "" >&2
        echo "--------------------------------------------------------------------------------" >&2
        echo "🔴 Home Manager switch FAILED within the script." >&2
        echo "" >&2
        echo "➡️ NEXT STEPS:" >&2
        echo "" >&2
        echo "1. ENSURE NIX IS IN PATH FOR NEW TERMINALS:" >&2
        echo "   The Nix installer should add a line to your shell's startup file (e.g., ~/.bashrc, ~/.zshrc)." >&2
        echo "   Look for a line like: '. \"\$HOME/.nix-profile/etc/profile.d/nix-daemon.sh\"' (or nix.sh)." >&2
        echo "   If missing, add it. Then, CLOSE AND REOPEN YOUR TERMINAL or run 'source ~/.your_shell_rc_file'." >&2
        echo "   Verify by typing: nix --version (it MUST work)." >&2
        echo "" >&2
        echo "2. MANUALLY APPLY HOME MANAGER (Once 'nix --version' works):" >&2
        echo "   In a NEW terminal, run:" >&2
        echo "   home-manager --extra-experimental-features nix-command --extra-experimental-features flakes switch --flake \"$HOME/.config/home-manager#$CONFIGURED_USERNAME\" --show-trace -b \"$BACKUP_SUFFIX\"" >&2
        echo "" >&2
        echo "   (The '-b $BACKUP_SUFFIX' will backup conflicting files like ~/.bashrc to ~/.bashrc.$BACKUP_SUFFIX)." >&2
        echo "--------------------------------------------------------------------------------" >&2
        exit 1
    fi

    echo "" >&2; log_info "🎉 Script finished! Home Manager configuration applied. 🎉"; echo "" >&2
    echo "Packages (PHP, Composer, nnn, Node.js) should be available after you OPEN A NEW TERMINAL or re-login." >&2
    echo "Your original ~/.bashrc, ~/.profile, and ~/.config/nix/nix.conf (if they existed and conflicted)" >&2
    echo "have been backed up with the suffix '.${BACKUP_SUFFIX}' in your home directory/subdirectories." >&2
    echo "Verify by typing in a new terminal:" >&2
    echo "  composer --version" >&2
    echo "  php --version" >&2
    echo "  nnn -V" >&2
    echo "  node --version" >&2
    echo "  npm --version" >&2
}

# --- Run Main ---
main


