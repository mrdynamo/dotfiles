#!/usr/bin/env bash

set -euo pipefail

DOTFILES_REPO="mrdynamo/dotfiles"

log_info() {
    printf "\033[1;34m[INFO]\033[0m %s\n" "$1"
}

log_ok() {
    printf "\033[1;32m[OK]\033[0m %s\n" "$1"
}

log_warn() {
    printf "\033[1;33m[WARN]\033[0m %s\n" "$1"
}

log_error() {
    printf "\033[1;31m[ERROR]\033[0m %s\n" "$1" >&2
}

die() {
    log_error "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

setup_op_service_account_token() {
    local token_file="$HOME/.config/op/service-account-token.env"
    local token
    local token_quoted

    # Service-account flow is only needed on native Linux hosts.
    [[ "$OS" == "linux" ]] || return
    if is_wsl; then
        return
    fi

    if [[ -f "$token_file" ]]; then
        log_ok "1Password service account token file already exists"
        return
    fi

    # curl|bash bootstrap is non-interactive; avoid blocking for input.
    if [[ ! -t 0 || ! -t 1 ]]; then
        log_warn "Skipping OP service account prompt (non-interactive bootstrap)"
        log_warn "Create $token_file with: export OP_SERVICE_ACCOUNT_TOKEN=<token>"
        return
    fi

    log_info "Configure 1Password service account token for remote Linux auth"
    read -r -s -p "Paste OP_SERVICE_ACCOUNT_TOKEN (input hidden, leave empty to skip): " token
    printf "\n"

    if [[ -z "$token" ]]; then
        log_warn "No OP service account token provided; skipping"
        return
    fi

    mkdir -p "$HOME/.config/op"
    chmod 700 "$HOME/.config/op"

    printf -v token_quoted '%q' "$token"
    {
        printf "# Created by dotfiles bootstrap on %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf "export OP_SERVICE_ACCOUNT_TOKEN=%s\n" "$token_quoted"
    } >"$token_file"
    chmod 600 "$token_file"

    unset token token_quoted
    log_ok "Stored OP service account token in $token_file"
}

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*) echo "linux" ;;
        *) echo "unknown" ;;
    esac
}

is_wsl() {
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi

    if command_exists sudo; then
        sudo -v
        return 0
    fi

    die "sudo is required for package installation on this system"
}

install_apt_basics() {
    log_info "Installing Linux prerequisites with apt"
    ensure_sudo
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        gnupg \
        locales \
        procps
    log_ok "Linux prerequisites installed"
}

install_xcode_cli_if_needed() {
    if xcode-select -p >/dev/null 2>&1; then
        log_ok "Xcode Command Line Tools already installed"
        return
    fi

    log_warn "Xcode Command Line Tools are required for Homebrew"
    log_warn "Run: xcode-select --install"
    die "Install Xcode Command Line Tools and run this script again"
}

install_homebrew_if_needed() {
    if command_exists brew; then
        log_ok "Homebrew already installed"
        return
    fi

    log_info "Installing Homebrew"

    if [[ "$OS" == "macos" ]]; then
        install_xcode_cli_if_needed
    else
        install_apt_basics
    fi

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    log_ok "Homebrew installation finished"
}

resolve_brew_bin() {
    if command_exists brew; then
        command -v brew
        return 0
    fi

    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        echo /home/linuxbrew/.linuxbrew/bin/brew
        return 0
    fi

    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo /opt/homebrew/bin/brew
        return 0
    fi

    if [[ -x /usr/local/bin/brew ]]; then
        echo /usr/local/bin/brew
        return 0
    fi

    return 1
}

initialize_brew_env() {
    BREW_BIN="$(resolve_brew_bin)" || die "Could not resolve Homebrew binary after installation"

    # Make brew available immediately in this script process.
    eval "$(${BREW_BIN} shellenv)"
    log_ok "Homebrew environment initialized"
}

install_brew_packages() {
    log_info "Installing bootstrap tooling with Homebrew"

    # Keep this list to the absolute minimum required before mise can take over.
    # All other tooling is managed via ~/.config/mise/config.toml so that
    # Renovate can handle version updates in the repository.
    local packages=(
        age      # chezmoi secret decryption (needed before chezmoi apply)
        chezmoi  # dotfiles manager
        git      # required by chezmoi init
        gnupg    # GPG key operations / chezmoi decryption
        mise     # tool version manager (installs everything else)
        sops     # chezmoi secret decryption (needed before chezmoi apply)
        zsh      # target shell
    )

    brew update
    brew install "${packages[@]}"
    log_ok "Bootstrap brew packages installed"
}

ensure_shell_is_listed() {
    local shell_path="$1"

    if grep -Fqx "$shell_path" /etc/shells 2>/dev/null; then
        return 0
    fi

    log_info "Adding $shell_path to /etc/shells"

    if [[ -w /etc/shells ]]; then
        printf "%s\n" "$shell_path" >>/etc/shells
    else
        ensure_sudo
        printf "%s\n" "$shell_path" | sudo tee -a /etc/shells >/dev/null
    fi

    if grep -Fqx "$shell_path" /etc/shells 2>/dev/null; then
        log_ok "$shell_path added to /etc/shells"
        return 0
    fi

    log_warn "Could not verify $shell_path in /etc/shells"
    return 1
}

set_default_shell_to_zsh_if_possible() {
    local zsh_bin
    local current_user
    local current_shell
    zsh_bin="$(command -v zsh || true)"
    current_user="$(id -un)"

    if [[ -z "$zsh_bin" ]]; then
        log_warn "zsh not found on PATH; skipping default shell change"
        return
    fi

    # chsh should target only the active user session. If this script is run
    # via sudo, skip shell change to avoid mutating another account's shell.
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "$(id -un)" ]]; then
        log_warn "Script is running under sudo; skipping chsh. Re-run without sudo to set your own default shell."
        return
    fi

    if [[ "$SHELL" == "$zsh_bin" ]]; then
        log_ok "Default shell already set to $zsh_bin"
        return
    fi

    current_shell="$(getent passwd "$current_user" | cut -d: -f7 2>/dev/null || true)"
    if [[ "$current_shell" == "$zsh_bin" ]]; then
        log_ok "Login shell already set to $zsh_bin"
        return
    fi

    if ! ensure_shell_is_listed "$zsh_bin"; then
        log_warn "Cannot set default shell because $zsh_bin is not registered in /etc/shells"
        return
    fi

    log_info "Setting default shell to $zsh_bin for current user"

    if chsh -s "$zsh_bin"; then
        log_ok "Default shell updated with chsh"
        return
    fi

    if command_exists sudo; then
        log_warn "Direct chsh failed; retrying with sudo for current user only"
        if sudo chsh -s "$zsh_bin" "$current_user"; then
            log_ok "Default shell updated with sudo chsh"
            return
        fi
    fi

    log_warn "Could not change default shell automatically"
}

initialize_dotfiles() {
    log_info "Initializing dotfiles with chezmoi"

    local -a chezmoi_args=()
    # When bootstrap is piped (curl | bash), stdin is not a tty and chezmoi
    # prompts cannot read user input reliably.
    if [[ ! -t 0 || ! -t 1 ]]; then
        chezmoi_args+=(--no-tty --force)
    fi

    if [[ -d "$HOME/.local/share/chezmoi/.git" ]]; then
        chezmoi "${chezmoi_args[@]}" update
    else
        chezmoi "${chezmoi_args[@]}" init --apply "$DOTFILES_REPO"
    fi

    # Always apply again so new templates/scripts are enforced.
    chezmoi "${chezmoi_args[@]}" apply
    log_ok "Chezmoi configuration applied"
}

install_mise_tools() {
    log_info "Installing mise-managed tools from global config"

    local mise_bin
    mise_bin="$(command -v mise)" || die "mise not found on PATH after brew install"

    # Trust the global config so mise does not prompt in non-interactive mode.
    "$mise_bin" trust --all >/dev/null 2>&1 || true

    "$mise_bin" install --yes
    log_ok "mise tools installed"
}

print_post_install_notes() {
    log_info "Bootstrap complete"

    if is_wsl; then
        log_info "Detected WSL environment"
    fi

    cat <<'EOF'

Next steps:
    1. Open a new terminal session so shell changes take effect.
    2. If prompted by chezmoi templates, answer machine class/profile questions.
    3. Run `chezmoi apply` anytime you update this repo.

EOF
}

main() {
    OS="$(detect_os)"
    [[ "$OS" == "unknown" ]] && die "Unsupported operating system: $(uname -s)"

    log_info "Detected OS: $OS"

    install_homebrew_if_needed
    initialize_brew_env
    install_brew_packages
    set_default_shell_to_zsh_if_possible
    initialize_dotfiles
    install_mise_tools
    setup_op_service_account_token
    print_post_install_notes
}

main "$@"
