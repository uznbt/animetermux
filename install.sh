#!/bin/bash
set -e

# ANSI escape codes for styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${CYAN}===================================================${RESET}"
echo -e "${BLUE}         AnimeTermux One-Click Installer           ${RESET}"
echo -e "${CYAN}===================================================${RESET}"

# Detect OS
OS_TYPE=""
if [ -f "/etc/steamos-release" ]; then
    OS_TYPE="SteamOS (Steam Deck)"
elif [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
    OS_TYPE="Android (Termux)"
elif [[ "$(uname)" == "Darwin" ]]; then
    OS_TYPE="macOS"
elif [[ "$(uname)" == "FreeBSD" ]]; then
    OS_TYPE="FreeBSD"
elif [ -f "/etc/alpine-release" ] || command -v apk &>/dev/null; then
    OS_TYPE="Alpine Linux (iSH Shell)"
elif [ -f "/etc/os-release" ]; then
    OS_TYPE=$(grep -w "NAME" /etc/os-release | cut -d= -f2 | tr -d '"')
else
    OS_TYPE=$(uname)
fi

echo -e "${CYAN}[*] Mendeteksi Sistem Operasi: ${GREEN}$OS_TYPE${RESET}"
echo -e ""

# Ensure local user binaries are in PATH (crucial for rootless installations like SteamOS)
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Check for git
GIT_INSTALLED_BY_SCRIPT=false
if ! command -v git &> /dev/null; then
    GIT_INSTALLED_BY_SCRIPT=true
    echo -e "${YELLOW}[*] Git belum terinstal. Mencoba memasang git terlebih dahulu...${RESET}"
    if [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
        pkg install -y git
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git
    elif command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y git
    elif command -v pacman &> /dev/null; then
        # Check if SteamOS
        if [ -f "/etc/steamos-release" ]; then
            echo -e "${CYAN}[*] Mendeteksi SteamOS (Steam Deck). Menginstal Git portabel secara lokal...${RESET}"
            mkdir -p "$HOME/.local/opt/git"
            echo -e "${CYAN}[*] Mengunduh & mengekstrak paket Git Arch Linux...${RESET}"
            if curl -L "https://archlinux.org/packages/extra/x86_64/git/download/" | tar -xI zstd -C "$HOME/.local/opt/git" --strip-components=1 usr/bin/git usr/lib/git-core usr/share/git-core; then
                # Create a wrapper script in ~/.local/bin/git
                mkdir -p "$HOME/.local/bin"
                cat << 'EOF' > "$HOME/.local/bin/git"
#!/bin/bash
export GIT_EXEC_PATH="$HOME/.local/opt/git/lib/git-core"
export GIT_TEMPLATE_DIR="$HOME/.local/opt/git/share/git-core/templates"
exec "$HOME/.local/opt/git/bin/git" "$@"
EOF
                chmod +x "$HOME/.local/bin/git"
                export PATH="$HOME/.local/bin:$PATH"
                echo -e "${GREEN}[+] Git portabel berhasil dipasang!${RESET}"
            else
                echo -e "${RED}[-] Gagal mengunduh atau mengekstrak Git portabel.${RESET}"
                exit 1
            fi
        else
            sudo pacman -S --noconfirm git
        fi
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y git
    elif command -v apk &> /dev/null; then
        if [ "$(id -u)" -ne 0 ]; then
            sudo apk add --no-cache git
        else
            apk add --no-cache git
        fi
    elif command -v pkg &> /dev/null; then
        if [[ "$(uname)" == "FreeBSD" ]]; then
            if [ "$(id -u)" -ne 0 ]; then
                sudo pkg install -y git
            else
                pkg install -y git
            fi
        else
            pkg install git -y
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo -e "${YELLOW}[*] Git belum terinstal di macOS.${RESET}"
        echo -e "${YELLOW}[*] Memicu instalasi Xcode Command Line Tools untuk mendapatkan Git...${RESET}"
        xcode-select --install 2>/dev/null || true
        echo -e "${YELLOW}[!] Silakan ikuti dialog instalasi di layar Anda.${RESET}"
        echo -e "${YELLOW}[!] Setelah instalasi Xcode Command Line Tools selesai, jalankan kembali script ini.${RESET}"
        exit 1
    else
        echo -e "${RED}[-] Package manager tidak dikenali. Silakan pasang Git secara manual.${RESET}"
        exit 1
    fi
fi

# Clone repository
if [ -f "run.sh" ] && [ -d ".git" ] && git remote -v 2>/dev/null | grep -q "animetermux"; then
    INSTALL_DIR="$(pwd)"
else
    INSTALL_DIR="$(pwd)/animetermux"
fi

if [ -d "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != "$(pwd)" ]; then
    echo -e "${YELLOW}[*] Folder $INSTALL_DIR sudah ada. Melakukan sinkronisasi (git pull)...${RESET}"
    cd "$INSTALL_DIR"
    git pull origin main
elif [ "$INSTALL_DIR" = "$(pwd)" ]; then
    echo -e "${YELLOW}[*] Menjalankan installer langsung di dalam folder proyek...${RESET}"
    git pull origin main || true
else
    echo -e "${GREEN}[*] Mengkloning AnimeTermux ke $INSTALL_DIR...${RESET}"
    git clone https://github.com/uznbt/animetermux.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Record git if installed by this script
if [ "$GIT_INSTALLED_BY_SCRIPT" = "true" ]; then
    if [ ! -f ".installed_packages.json" ] || [ ! -s ".installed_packages.json" ]; then
        echo '["git"]' > .installed_packages.json
    else
        if ! grep -q '"git"' .installed_packages.json; then
            content=$(cat .installed_packages.json)
            content=${content%\]}
            echo "$content, \"git\"]" > .installed_packages.json
        fi
    fi
fi

# Run the main launcher script
echo -e "${GREEN}[+] Sukses mengunduh AnimeTermux! Memulai launcher...${RESET}"
chmod +x run.sh
./run.sh
