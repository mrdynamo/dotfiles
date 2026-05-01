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

append_line_if_missing() {
    local line="$1"
    local file="$2"

    touch "$file"
    grep -Fqx "$line" "$file" || printf "%s\n" "$line" >>"$file"
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

    # Persist shellenv for both common interactive shells.
    BREW_SHELLENV_LINE="eval \"\$(${BREW_BIN} shellenv)\""
    append_line_if_missing "$BREW_SHELLENV_LINE" "$HOME/.bashrc"
    append_line_if_missing "$BREW_SHELLENV_LINE" "$HOME/.zprofile"

    # Make brew available immediately in this script process.
    eval "$(${BREW_BIN} shellenv)"
    log_ok "Homebrew environment initialized"
}

install_brew_packages() {
    log_info "Installing core tooling with Homebrew"

    local packages=(
        age
        atuin
        bat
        chezmoi
        eza
        fd
        fzf
        gh
        git
        gnupg
        jq
        mise
        ripgrep
        sops
        starship
        yq
        zoxide
        zsh
    )

    brew update
    brew install "${packages[@]}"
    log_ok "Core brew packages installed"
}

install_oh_my_zsh_if_needed() {
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_ok "Oh My Zsh already installed"
        return
    fi

    if ! command_exists curl; then
        die "curl is required to install Oh My Zsh"
    fi

    log_info "Installing Oh My Zsh"
    # Keep user's existing ~/.zshrc and avoid entering an interactive zsh shell.
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    log_ok "Oh My Zsh installed"
}

set_default_shell_to_zsh_if_possible() {
    local zsh_bin
    zsh_bin="$(command -v zsh || true)"

    if [[ -z "$zsh_bin" ]]; then
        log_warn "zsh not found on PATH; skipping default shell change"
        return
    fi

    if [[ "$SHELL" == "$zsh_bin" ]]; then
        log_ok "Default shell already set to $zsh_bin"
        return
    fi

    if ! grep -Fqx "$zsh_bin" /etc/shells 2>/dev/null; then
        log_warn "$zsh_bin is not listed in /etc/shells; skipping chsh"
        return
    fi

    log_info "Setting default shell to $zsh_bin"
    chsh -s "$zsh_bin" || log_warn "Could not change default shell automatically"
}

initialize_dotfiles() {
    log_info "Initializing dotfiles with chezmoi"

    if [[ -d "$HOME/.local/share/chezmoi/.git" ]]; then
        chezmoi update
    else
        chezmoi init --apply "$DOTFILES_REPO"
    fi

    # Always apply again so new templates/scripts are enforced.
    chezmoi apply
    log_ok "Chezmoi configuration applied"
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
    install_oh_my_zsh_if_needed
    set_default_shell_to_zsh_if_possible
    initialize_dotfiles
    print_post_install_notes
}

main "$@"
