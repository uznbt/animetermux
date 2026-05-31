#!/bin/bash

# Ensure script runs in its own directory
cd "$(dirname "$0")" || exit

# Clear screen
clear

# ANSI Color Codes
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
BLUE="\033[94m"
CYAN="\033[96m"
RESET="\033[0m"
BOLD="\033[1m"

RUN_PRELOADER_ON_START=false
PRELOADER_COMMAND=()

# Base Directories (Dynamic Portability)
ANIMETERMUX_DIR="$(pwd)"
PARENT_DIR="$(cd .. && pwd)"

# Ensure local user binaries are in PATH (crucial for rootless installations like SteamOS)
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Check for Git Updates on Startup
check_git_updates() {
    if [ -d ".git" ] && command -v git &>/dev/null; then
        echo -e "${CYAN}[*] Memeriksa pembaruan dari repositori Git...${RESET}"
        
        # Check network connectivity by pinging or checking remote HEAD
        if ! git ls-remote origin HEAD &>/dev/null; then
            echo -e "${YELLOW}[!] Koneksi internet tidak tersedia atau server Git tidak terjangkau. Melewati pengecekan pembaruan...${RESET}"
            return
        fi

        # Fetch remote changes
        git fetch origin &>/dev/null
        
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse @{u})
        
        if [ "$LOCAL" != "$REMOTE" ]; then
            echo -e "${YELLOW}[!] Menemukan pembaruan kode baru di Git!${RESET}"
            echo -e "${CYAN}[*] Menghentikan semua layanan lama yang sedang berjalan...${RESET}"
            
            # Stop existing processes
            pkill -f gunicorn &>/dev/null
            pkill -f nginx &>/dev/null
            pkill -f cloudflared &>/dev/null
            pkill -f ngrok &>/dev/null
            sleep 1
            
            echo -e "${CYAN}[*] Mengunduh pembaruan (git pull)...${RESET}"
            git pull
            
            echo -e "${GREEN}[+] Pembaruan berhasil diterapkan! Memulai ulang script...${RESET}"
            echo -e "${CYAN}-------------------------------------------------------${RESET}"
            exec "$0" "$@"
        else
            echo -e "${GREEN}[+] Kode Anda sudah versi terbaru.${RESET}"
        fi
    fi
}

if [ "$1" != "--uninstall" ]; then
    check_git_updates
fi

# Global HTTP port and user directive based on root privileges
HTTP_PORT=8080
NGINX_USER_DIRECTIVE=""
if [ "$(id -u)" -eq 0 ]; then
    HTTP_PORT=80
    NGINX_USER_DIRECTIVE="user root;"
fi

# Parse --uninstall flag
if [ "$1" == "--uninstall" ]; then
    echo -e "${YELLOW}[*] Menghapus paket yang diinstal oleh run.sh...${RESET}"
    if [ -f ".installed_packages.json" ]; then
        PKGS=$(grep -o '"[^"]*"' .installed_packages.json | tr -d '"')
        for PKG in $PKGS; do
            echo -e "${CYAN}[*] Menghapus paket: $PKG${RESET}"
            
            # Hapus paket portabel jika ada
            if [ "$PKG" == "git" ] && [ -d "$HOME/.local/opt/git" ]; then
                rm -rf "$HOME/.local/opt/git"
                rm -f "$HOME/.local/bin/git"
            elif [ "$PKG" == "python" ] || [ "$PKG" == "python3" ]; then
                if [ -d "$HOME/.local/opt/python" ]; then
                    rm -rf "$HOME/.local/opt/python"
                    rm -f "$HOME/.local/bin/python" "$HOME/.local/bin/python3"
                fi
            elif [ "$PKG" == "nginx" ] && [ -d "$HOME/.local/opt/nginx" ]; then
                rm -rf "$HOME/.local/opt/nginx"
                rm -f "$HOME/.local/bin/nginx"
            elif [ "$PKG" == "fzf" ] && [ -f "$HOME/.local/bin/fzf" ]; then
                rm -f "$HOME/.local/bin/fzf"
            elif [[ "$PKG" == "node" || "$PKG" == "nodejs" || "$PKG" == "npm" ]]; then
                rm -rf "$HOME"/.local/opt/node-* 2>/dev/null
                rm -f "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx"
            else
                # Jika bukan paket portabel lokal, hapus dengan package manager
                if command -v pkg &> /dev/null; then pkg remove -y "$PKG"
                elif command -v pacman &> /dev/null; then sudo pacman -Rns --noconfirm "$PKG"
                elif command -v yay &> /dev/null; then yay -Rns --noconfirm "$PKG"
                elif command -v dnf &> /dev/null; then sudo dnf remove -y "$PKG"
                elif command -v apt-get &> /dev/null; then sudo apt-get remove -y "$PKG"
                elif command -v apt &> /dev/null; then sudo apt remove -y "$PKG"
                elif command -v brew &> /dev/null; then brew uninstall "$PKG"
                fi
            fi
        done
        rm -f .installed_packages.json
        echo -e "${GREEN}[+] Penghapusan paket selesai!${RESET}"
    else
        echo -e "${GREEN}[+] Tidak ada paket yang tercatat untuk dihapus (semua dependensi adalah bawaan OS Anda).${RESET}"
    fi

    # Delete the directory itself
    echo -e "${CYAN}[*] Menghapus direktori aplikasi ($ANIMETERMUX_DIR)...${RESET}"
    cd "$PARENT_DIR" || exit
    rm -rf "$ANIMETERMUX_DIR"
    echo -e "${GREEN}[+] Uninstall selesai! Seluruh folder aplikasi telah dihapus.${RESET}"
    exit 0
fi

# Load environment variables from .env if present (check both directories)
if [ -f "$BOT_TELE_DIR/.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
            export "$line"
        fi
    done < "$BOT_TELE_DIR/.env"
fi

if [ -f ".env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
            export "$line"
        fi
    done < .env
fi

# Parse --settings flag
FOR_SETTINGS=false
for arg in "$@"; do
    if [ "$arg" == "--settings" ]; then
        FOR_SETTINGS=true
        break
    fi
done

if [ "$FOR_SETTINGS" = true ]; then
    if command -v fzf &>/dev/null; then
        options=(
            "1) Atur ulang Mode Penyimpanan Gambar (CDN Telegram / Hotlink)"
            "2) Atur ulang Akses Online / Tunnel (Ngrok / Cloudflare)"
            "3) Atur ulang Mode Berjalan (Foreground / Background)"
            "4) Atur ulang Token Bot Telegram & Chat ID"
            "5) Atur ulang Ngrok Domain"
            "6) Konfigurasi Cloudflare Tunnel Custom Domain (Token & Domain)"
            "7) Reset Semua Konfigurasi ke Awal"
            "8) Setup Termux Background Service (Anti-Mati / Phantom Killer / Tmux)"
            "9) Atur Pilihan Jalankan Otomatis (Auto-Run / Tanpa Enter)"
            "10) Batal / Keluar"
        )
        selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 15 --layout=reverse --border --prompt="Pilih opsi pengaturan: " --header="PENGATURAN & KONFIGURASI SISTEM")
        if [ $? -eq 130 ]; then
            echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
            exit 130
        fi
        if [ -z "$selected_option" ]; then
            setting_choice="10"
        else
            setting_choice=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
        fi
    else
        echo -e "\n${BLUE}${BOLD}=======================================================${RESET}"
        echo -e "${GREEN}${BOLD}             PENGATURAN & KONFIGURASI SISTEM           ${RESET}"
        echo -e "${BLUE}${BOLD}=======================================================${RESET}"
        echo -e "Apa yang ingin Anda lakukan?"
        echo -e "1) Atur ulang Mode Penyimpanan Gambar (CDN Telegram / Hotlink)"
        echo -e "2) Atur ulang Akses Online / Tunnel (Ngrok / Cloudflare)"
        echo -e "3) Atur ulang Mode Berjalan (Foreground / Background)"
        echo -e "4) Atur ulang Token Bot Telegram & Chat ID"
        echo -e "5) Atur ulang Ngrok Domain"
        echo -e "6) Konfigurasi Cloudflare Tunnel Custom Domain (Token & Domain)"
        echo -e "7) Reset Semua Konfigurasi ke Awal"
        echo -e "8) Setup Termux Background Service (Anti-Mati / Phantom Killer / Tmux)"
        echo -e "9) Atur Pilihan Jalankan Otomatis (Auto-Run / Tanpa Enter)"
        echo -e "10) Batal / Keluar"
        echo -e ""
        read -p "Masukkan pilihan Anda (1-10): " setting_choice
    fi
    
    if [ "$setting_choice" == "1" ]; then
        if [ -f ".env" ]; then
            grep -v "SKIP_TELEGRAM" .env > .env.tmp && mv .env.tmp .env
        fi
        echo -e "${GREEN}[+] Konfigurasi Penyimpanan Gambar berhasil dihapus! Silakan jalankan ulang untuk memilih metode baru.${RESET}"
    elif [ "$setting_choice" == "2" ]; then
        if [ -f ".env" ]; then
            grep -v "DEFAULT_TUNNEL" .env > .env.tmp && mv .env.tmp .env
        fi
        echo -e "${GREEN}[+] Konfigurasi Tunnel berhasil dihapus! Silakan jalankan ulang untuk setup baru.${RESET}"
    elif [ "$setting_choice" == "3" ]; then
        if [ -f ".env" ]; then
            grep -v "DEFAULT_MODE" .env > .env.tmp && mv .env.tmp .env
        fi
        echo -e "${GREEN}[+] Konfigurasi Mode Berjalan berhasil dihapus! Silakan jalankan ulang untuk setup baru.${RESET}"
    elif [ "$setting_choice" == "4" ]; then
        if [ -f ".env" ]; then
            grep -v "BOT_TOKEN" .env > .env.tmp && mv .env.tmp .env
            grep -v "BOT_TOKENS" .env > .env.tmp && mv .env.tmp .env
        fi
        if [ -f "$BOT_TELE_DIR/.env" ]; then
            grep -v "BOT_TOKEN" "$BOT_TELE_DIR/.env" > "$BOT_TELE_DIR/.env.tmp" && mv "$BOT_TELE_DIR/.env.tmp" "$BOT_TELE_DIR/.env"
            grep -v "BOT_TOKENS" "$BOT_TELE_DIR/.env" > "$BOT_TELE_DIR/.env.tmp" && mv "$BOT_TELE_DIR/.env.tmp" "$BOT_TELE_DIR/.env"
        fi
        rm -f ".chat_ids" "backend/.chat_ids" "$BOT_TELE_DIR/.chat_ids" &>/dev/null
        echo -e "${GREEN}[+] Token Bot Telegram & Chat ID berhasil diset ulang!${RESET}"
    elif [ "$setting_choice" == "5" ]; then
        if [ -f ".env" ]; then
            grep -v "NGROK_DOMAIN" .env > .env.tmp && mv .env.tmp .env
        fi
        echo -e "${GREEN}[+] Ngrok Domain berhasil diset ulang!${RESET}"
    elif [ "$setting_choice" == "6" ]; then
        echo -e "\n${YELLOW}[!] Konfigurasi Custom Domain Cloudflare Tunnel.${RESET}"
        read -p "Masukkan Cloudflare Tunnel Token Anda: " cf_token_input
        read -p "Masukkan Custom Domain Anda (contoh: anime.saya.com): " cf_domain_input
        
        if [ -n "$cf_token_input" ]; then
            if [ -f ".env" ]; then
                grep -v "CLOUDFLARE_TUNNEL_TOKEN" .env > .env.tmp && mv .env.tmp .env
                grep -v "CLOUDFLARE_DOMAIN" .env > .env.tmp && mv .env.tmp .env
            fi
            echo "CLOUDFLARE_TUNNEL_TOKEN=$cf_token_input" >> .env
            echo "CLOUDFLARE_DOMAIN=$cf_domain_input" >> .env
            export CLOUDFLARE_TUNNEL_TOKEN="$cf_token_input"
            export CLOUDFLARE_DOMAIN="$cf_domain_input"
            echo -e "${GREEN}[+] Token & Domain Cloudflare berhasil disimpan!${RESET}"
        else
            echo -e "${RED}[-] Token kosong. Batal.${RESET}"
        fi
    elif [ "$setting_choice" == "7" ]; then
        if [ -f ".env" ]; then
            grep -v "SKIP_TELEGRAM" .env > .env.tmp && mv .env.tmp .env
            grep -v "DEFAULT_TUNNEL" .env > .env.tmp && mv .env.tmp .env
            grep -v "DEFAULT_MODE" .env > .env.tmp && mv .env.tmp .env
            grep -v "BOT_TOKEN" .env > .env.tmp && mv .env.tmp .env
            grep -v "BOT_TOKENS" .env > .env.tmp && mv .env.tmp .env
            grep -v "NGROK_DOMAIN" .env > .env.tmp && mv .env.tmp .env
            grep -v "CLOUDFLARE_TUNNEL_TOKEN" .env > .env.tmp && mv .env.tmp .env
            grep -v "CLOUDFLARE_DOMAIN" .env > .env.tmp && mv .env.tmp .env
            grep -v "AUTO_RUN" .env > .env.tmp && mv .env.tmp .env
        fi
        if [ -f "$BOT_TELE_DIR/.env" ]; then
            grep -v "BOT_TOKEN" "$BOT_TELE_DIR/.env" > "$BOT_TELE_DIR/.env.tmp" && mv "$BOT_TELE_DIR/.env.tmp" "$BOT_TELE_DIR/.env"
            grep -v "BOT_TOKENS" "$BOT_TELE_DIR/.env" > "$BOT_TELE_DIR/.env.tmp" && mv "$BOT_TELE_DIR/.env.tmp" "$BOT_TELE_DIR/.env"
        fi
        rm -f ".chat_ids" "backend/.chat_ids" "$BOT_TELE_DIR/.chat_ids" &>/dev/null
        echo -e "${GREEN}[+] Seluruh konfigurasi telah di-reset ke awal!${RESET}"
    elif [ "$setting_choice" == "8" ]; then
        echo -e "\n${BLUE}${BOLD}=======================================================${RESET}"
        echo -e "${GREEN}${BOLD}      SETUP TERMUX BACKGROUND SERVICE (ANTI-MATI)       ${RESET}"
        echo -e "${BLUE}${BOLD}=======================================================${RESET}"
        # Check Termux environment
        IS_ACTUAL_TERMUX=false
        if [[ "$(pwd)" == /data/data/com.termux/* ]] || [ -n "$TERMUX_VERSION" ]; then
            IS_ACTUAL_TERMUX=true
        fi
        
        if [ "$IS_ACTUAL_TERMUX" = false ]; then
            echo -e "${YELLOW}[!] Pengaturan ini dirancang khusus untuk aplikasi Termux di Android.${RESET}"
        fi
        
        echo -e "${CYAN}[1] Memeriksa & Menginstal tmux...${RESET}"
        if ! command -v tmux &>/dev/null; then
            echo -e "${YELLOW}[*] tmux belum terinstal. Menginstal tmux otomatis...${RESET}"
            if command -v pkg &>/dev/null; then
                pkg install tmux -y
                record_installed_package "tmux"
            else
                echo -e "${RED}[-] Gagal menginstal tmux otomatis. Silakan jalankan 'pkg install tmux' manual.${RESET}"
            fi
        else
            echo -e "${GREEN}[+] tmux sudah terinstal.${RESET}"
        fi
        
        echo -e "\n${CYAN}[2] Menonaktifkan Android 12+ Phantom Process Killer...${RESET}"
        echo -e "Sistem Android 12 ke atas sering membunuh background server Termux."
        echo -e "Apakah HP Anda sudah dalam keadaan ROOT?"
        if command -v fzf &>/dev/null; then
            options=(
                "y) Ya (Sudah Root)"
                "n) Tidak / Non-Root"
            )
            selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Apakah HP Anda sudah ROOT?: ")
            if [ $? -eq 130 ]; then
                echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
                exit 130
            fi
            if [ -z "$selected_option" ]; then
                is_rooted="n"
            else
                is_rooted=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
            fi
        else
            read -p "[y/N]: " is_rooted
        fi
        
        if [[ "$is_rooted" =~ ^[yY]$ ]]; then
            echo -e "${YELLOW}[*] Menjalankan perintah root untuk menonaktifkan pembatasan...${RESET}"
            if su -c "settings put global settings_enable_monitor_phantom_procs false" &>/dev/null; then
                echo -e "${GREEN}[+] Phantom Process Killer berhasil dinonaktifkan!${RESET}"
            else
                echo -e "${RED}[-] Gagal menjalankan su. Pastikan izin root diberikan.${RESET}"
            fi
        else
            echo -e "${YELLOW}[*] Instruksi Non-Root:${RESET}"
            echo -e "Jalankan perintah berikut di LADB (HP) atau ADB (PC):"
            echo -e "${BOLD}adb shell settings put global settings_enable_monitor_phantom_procs false${RESET}"
        fi
        
        echo -e "\n${CYAN}[3] PANDUAN PENTING RUNNING PERSISTENT:${RESET}"
        echo -e " agar program selalu berjalan di latar belakang walaupun aplikasi Termux ditutup:"
        echo -e " 1. Pastikan ${YELLOW}Optimasi Baterai${RESET} untuk aplikasi Termux diubah ke ${GREEN}Tidak Dibatasi (Unrestricted)${RESET}."
        echo -e " 2. Jalankan script ini di dalam sesi tmux:"
        echo -e "    ${BOLD}tmux new -s animetermux${RESET}"
        echo -e "    ${BOLD}./run.sh${RESET}"
        echo -e " 3. Setelah script berjalan, keluar dari sesi tmux dengan menekan:"
        echo -e "    ${BOLD}Ctrl + B, lalu tekan D${RESET}"
        echo -e " 4. Selesai! Anda bisa menutup Termux. Untuk masuk kembali ke sesi, ketik:"
        echo -e "    ${BOLD}tmux attach -t animetermux${RESET}"
        echo -e ""
        read -p "Tekan Enter untuk kembali ke menu..." temp_read
    elif [ "$setting_choice" == "9" ]; then
        if [ "$AUTO_RUN" == "true" ]; then
            CURRENT_STATUS="Aktif"
        else
            CURRENT_STATUS="Nonaktif"
        fi
        echo -e "\nMode Jalankan Otomatis (Auto-Run) saat ini: ${GREEN}$CURRENT_STATUS${RESET}"
        echo -e "Jika diaktifkan, script akan berjalan langsung tanpa meminta input/Enter di awal."
        
        if command -v fzf &>/dev/null; then
            options=(
                "1) Aktifkan"
                "2) Nonaktifkan"
            )
            selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Pilih opsi Auto-Run: ")
            if [ $? -eq 130 ]; then
                echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
                exit 130
            fi
            if [ -z "$selected_option" ]; then
                autorun_choice=""
            else
                autorun_choice=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
            fi
        else
            echo -e "1) Aktifkan"
            echo -e "2) Nonaktifkan"
            read -p "Pilih opsi (1-2): " autorun_choice
        fi
        
        if [ "$autorun_choice" == "1" ]; then
            if [ -f ".env" ]; then
                grep -v "AUTO_RUN" .env > .env.tmp && mv .env.tmp .env
            fi
            echo "AUTO_RUN=true" >> .env
            echo -e "${GREEN}[+] Mode Jalankan Otomatis (Auto-Run) diaktifkan!${RESET}"
        elif [ "$autorun_choice" == "2" ]; then
            if [ -f ".env" ]; then
                grep -v "AUTO_RUN" .env > .env.tmp && mv .env.tmp .env
            fi
            echo "AUTO_RUN=false" >> .env
            echo -e "${GREEN}[+] Mode Jalankan Otomatis (Auto-Run) dinonaktifkan!${RESET}"
        else
            echo -e "${YELLOW}[*] Tidak ada perubahan.${RESET}"
        fi
    else
        echo -e "${YELLOW}[*] Dibatalkan.${RESET}"
    fi
    exit 0
fi

# Check if running in Termux
IS_TERMUX=false
if [[ "$(pwd)" == /data/data/com.termux/* ]] || [ -n "$TERMUX_VERSION" ]; then
    IS_TERMUX=true
fi

# Auto-persistent background session using Tmux when running on Termux
if [ "$IS_TERMUX" = true ] && [ -z "$TMUX" ]; then
    # Disable Phantom Process Killer automatically if ROOT
    if command -v su &>/dev/null; then
        su -c "settings put global settings_enable_monitor_phantom_procs false" &>/dev/null
    else
        echo -e "${YELLOW}[!] HP Non-Root: Proteksi latar belakang diaktifkan via Tmux & Wake-Lock.${RESET}"
        echo -e "${YELLOW}[!] PENTING: Pastikan 'Optimasi Baterai' Termux sudah diatur ke 'Tidak Dibatasi' agar tidak mati saat HP Standby.${RESET}"
        sleep 2
    fi
    
    # Enable wake lock automatically
    if command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
    fi

    # Install tmux if missing
    if ! command -v tmux &>/dev/null; then
        echo -e "${YELLOW}[*] Menginstal tmux agar sesi web server stabil di latar belakang...${RESET}"
        pkg install tmux -y
        record_installed_package "tmux"
    fi

    if command -v tmux &>/dev/null; then
        echo -e "${GREEN}[*] Mengaktifkan proteksi latar belakang via Tmux...${RESET}"
        sleep 1
        # Kill any stale/zombie sessions cleanly (suppress all output)
        tmux kill-session -t animetermux &>/dev/null
        # Create a session running the script directly (so it closes automatically on exit)
        tmux new-session -d -s animetermux "cd '$ANIMETERMUX_DIR' && bash run.sh $*"
        # Attach to the live session
        exec tmux attach-session -t animetermux
    fi
fi

# Parse all arguments to find if -f is active
HAS_FLAGS=""
if [ -n "$1" ]; then
    HAS_FLAGS="true"
fi

for arg in "$@"; do
    if [ "$arg" == "-f" ]; then
        FORCE_REVERSE="-f"
        break
    fi
done

# Parse --detail or -d flag
FORCE_DETAIL=""
for arg in "$@"; do
    if [ "$arg" == "--detail" ] || [ "$arg" == "-d" ]; then
        FORCE_DETAIL="--detail"
        break
    fi
done

# Parse status -ongoing or -complete
FORCE_STATUS=""
for arg in "$@"; do
    if [ "$arg" == "-ongoing" ]; then
        FORCE_STATUS="-ongoing"
        break
    elif [ "$arg" == "-complete" ]; then
        FORCE_STATUS="-complete"
        break
    fi
done

if [ -n "$1" ]; then
    if [ "$1" == "--downloadgenre" ]; then
        if [ "$FORCE_STATUS" == "-ongoing" ]; then
            PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --downloadgenre -ongoing)
            [ -n "$FORCE_REVERSE" ] && PRELOADER_COMMAND+=("$FORCE_REVERSE")
            PRELOAD_TITLE="Ongoing Anime (Detail Lengkap + Thumbnail)"
            PRELOAD_MODE_NAME="MODE PRA-UNDUH ONGOING ANIME"
        elif [ "$FORCE_STATUS" == "-complete" ]; then
            PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --downloadgenre -complete)
            [ -n "$FORCE_REVERSE" ] && PRELOADER_COMMAND+=("$FORCE_REVERSE")
            PRELOAD_TITLE="Completed Anime (Detail Lengkap + Thumbnail)"
            PRELOAD_MODE_NAME="MODE PRA-UNDUH COMPLETED ANIME"
        else
            PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --all)
            [ -n "$FORCE_REVERSE" ] && PRELOADER_COMMAND+=("$FORCE_REVERSE")
            [ -n "$FORCE_DETAIL" ] && PRELOADER_COMMAND+=("$FORCE_DETAIL")
            PRELOAD_TITLE="SELURUH genre anime"
            PRELOAD_MODE_NAME="MODE PRA-UNDUH CACHE GENRE ANIME"
        fi
    elif [ "$1" == "--genre" ]; then
        if [ -z "$2" ]; then
            echo -e "${RED}[-] Harap masukkan nama genre setelah flag --genre.${RESET}"
            exit 1
        fi
        GENRE_NAME="$2"
        GENRE_PRINT=$(echo "$GENRE_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
        IS_GENRE=true
        PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --genre "$GENRE_NAME")
        [ -n "$FORCE_REVERSE" ] && PRELOADER_COMMAND+=("$FORCE_REVERSE")
        [ -n "$FORCE_DETAIL" ] && PRELOADER_COMMAND+=("$FORCE_DETAIL")
        PRELOAD_TITLE="genre $GENRE_PRINT"
        PRELOAD_MODE_NAME="MODE PRA-UNDUH CACHE GENRE ANIME"
    elif [ "$1" == "--anime" ]; then
        if [ -z "$2" ]; then
            echo -e "${RED}[-] Harap masukkan slug anime setelah flag --anime.${RESET}"
            exit 1
        fi
        GENRE_NAME="$2"
        GENRE_PRINT=$(echo "$GENRE_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
        IS_GENRE=false
        PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --anime "$GENRE_NAME")
        PRELOAD_TITLE="anime $GENRE_PRINT"
        PRELOAD_MODE_NAME="MODE FAST CACHE: DETAIL ANIME"
    elif [ "$1" == "--chapter" ]; then
        echo -e "${RED}[-] Mode --chapter tidak didukung di AnimeTermux.${RESET}"
        exit 1
    elif [[ "$1" == --* ]]; then
        GENRE_NAME="${1#--}"
        GENRE_PRINT=$(echo "$GENRE_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
        
        # Check if the argument is one of the anime genres
        IS_GENRE=false
        GENRE_LOWER=$(echo "$GENRE_NAME" | tr '[:upper:]' '[:lower:]')
        GENRES=("action" "adventure" "comedy" "drama" "fantasy" "historical" "horror" "martial-arts" "mystery" "psychological" "romance" "school-life" "sci-fi" "slice-of-life" "supernatural" "tragedy" "academy" "adult" "gender-bender" "harem" "josei" "mecha" "ecchi" "smut" "doujinshi" "yuri" "yaoi" "shounen" "shoujo" "seinen" "isekai" "magic" "super-power" "thriller" "sports")
        
        for g in "${GENRES[@]}"; do
            if [ "$g" == "$GENRE_LOWER" ]; then
                IS_GENRE=true
                break
            fi
        done
        
        if [ "$IS_GENRE" == "true" ]; then
            PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --genre "$GENRE_NAME")
            [ -n "$FORCE_REVERSE" ] && PRELOADER_COMMAND+=("$FORCE_REVERSE")
            [ -n "$FORCE_DETAIL" ] && PRELOADER_COMMAND+=("$FORCE_DETAIL")
            PRELOAD_TITLE="genre $GENRE_PRINT"
            PRELOAD_MODE_NAME="MODE PRA-UNDUH CACHE GENRE ANIME"
        else
            PRELOADER_COMMAND=("$ANIMETERMUX_DIR/backend/venv/bin/python" "$ANIMETERMUX_DIR/backend/preloader.py" --anime "$GENRE_NAME")
            PRELOAD_TITLE="anime $GENRE_PRINT"
            PRELOAD_MODE_NAME="MODE FAST CACHE: DETAIL ANIME"
        fi
    fi
    
    # Override mode name jika --detail aktif
    if [ -n "$FORCE_DETAIL" ] && [ ${#PRELOADER_COMMAND[@]} -gt 0 ]; then
        PRELOAD_MODE_NAME="MODE FAST CACHE: DETAIL ANIME SAJA"
    fi
    
    if [ -n "$FORCE_REVERSE" -a "$IS_GENRE" == "true" -o "$1" == "--downloadgenre" ]; then
        PRELOAD_TITLE="$PRELOAD_TITLE (Mulai Mundur dari Halaman Terakhir)"
    fi
    
    if [ -n "$FORCE_DETAIL" ]; then
        PRELOAD_TITLE="$PRELOAD_TITLE (Hanya Detail - Tanpa Upload Cover)"
    fi
    
    if [ ${#PRELOADER_COMMAND[@]} -gt 0 ]; then
        if [ "$AUTO_RUN" == "true" ]; then
            PILIHAN_MODE="2"
            echo -e "${GREEN}[*] Auto-Run Aktif: Memilih mode Web + Pra-Unduh simultan secara otomatis.${RESET}"
        else
            if command -v fzf &>/dev/null; then
                options=(
                    "1) Download Langsung (Hanya jalankan Bot & Upload)"
                    "2) Jalankan Web dan Download Langsung (Bisa Sambil Baca)"
                )
                selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Pilih mode eksekusi [default: 2]: " --header="$PRELOAD_MODE_NAME - Target: $PRELOAD_TITLE")
                if [ $? -eq 130 ]; then
                    echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
                    exit 130
                fi
                if [ -z "$selected_option" ]; then
                    PILIHAN_MODE="2"
                else
                    PILIHAN_MODE=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
                fi
            else
                clear
                echo -e "${BLUE}${BOLD}=======================================================${RESET}"
                echo -e "${BLUE}${BOLD}        $PRELOAD_MODE_NAME               ${RESET}"
                echo -e "${BLUE}${BOLD}=======================================================${RESET}"
                echo -e "Target Caching: ${YELLOW}${BOLD}$PRELOAD_TITLE${RESET}"
                echo -e ""
                echo -e "${CYAN}${BOLD}Pilih mode eksekusi:${RESET}"
                echo -e "  ${GREEN}1)${RESET} Download Langsung (Hanya jalankan Bot & Upload)"
                echo -e "  ${GREEN}2)${RESET} Jalankan Web dan Download Langsung (Bisa Sambil Baca)"
                echo -e "${CYAN}-------------------------------------------------------${RESET}"
                read -p "Masukkan pilihan Anda [1 atau 2, default: 2]: " PILIHAN_MODE
                
                if [ -z "$PILIHAN_MODE" ]; then
                    PILIHAN_MODE="2"
                fi
            fi
        fi
        
        if [ "$PILIHAN_MODE" == "1" ]; then
            echo -e "\n${CYAN}[*] Memulai pra-unduh langsung...${RESET}"
            "${PRELOADER_COMMAND[@]}"
            exit 0
        elif [ "$PILIHAN_MODE" == "2" ]; then
            echo -e "\n${GREEN}[*] Mengaktifkan Web Server + Pra-Unduh simultan...${RESET}"
            RUN_PRELOADER_ON_START=true
            SERVICES_TYPE="both"
        else
            echo -e "\n${GREEN}[*] Mengaktifkan Web Server + Pra-Unduh simultan (Default)...${RESET}"
            RUN_PRELOADER_ON_START=true
            SERVICES_TYPE="both"
        fi
    fi
fi

echo -e "${BLUE}${BOLD}=======================================================${RESET}"
echo -e "${BLUE}${BOLD}      TELEGRAM BOT & ANIME WEB SERVER LAUNCHER         ${RESET}"
echo -e "${BLUE}${BOLD}=======================================================${RESET}"

# IS_TERMUX is already defined at the top of the script

activate_wake_lock() {
    if [ "$IS_TERMUX" = true ] && command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
        echo -e "${GREEN}[*] Termux Wake-Lock diaktifkan (mencegah CPU sleep)${RESET}"
    fi
}

release_wake_lock() {
    if [ "$IS_TERMUX" = true ] && command -v termux-wake-unlock &>/dev/null; then
        termux-wake-unlock
        echo -e "${YELLOW}[*] Termux Wake-Lock dilepas${RESET}"
    fi
}

prompt_autorun_mode() {
    if [ "$AUTO_RUN" != "true" ] && [ ! -f "$ANIMETERMUX_DIR/.autorun_prompted" ]; then
        local autostart_choice=""
        if command -v fzf &>/dev/null; then
            local options=("1) Ya" "2) Tidak")
            local selected_option
            selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Apakah Anda mau menjalankan skrip ini secara otomatis (tanpa menu awal) untuk seterusnya? " --header="PENGATURAN AUTO-RUN")
            if [ $? -eq 130 ]; then
                autostart_choice="n"
            else
                local choice_num=$(echo "$selected_option" | cut -d')' -f1)
                if [ "$choice_num" == "1" ]; then
                    autostart_choice="y"
                else
                    autostart_choice="n"
                fi
            fi
        else
            echo -e "\n${YELLOW}[?] Apakah Anda mau menjalankan skrip ini secara otomatis (tanpa menu awal) untuk seterusnya? (y/n): ${RESET}\c"
            read -n 1 -r autostart_choice
            echo ""
        fi

        if [[ $autostart_choice =~ ^[Yy]$ ]]; then
            if [ -f ".env" ]; then
                grep -v "AUTO_RUN" .env > .env.tmp && mv .env.tmp .env
            fi
            echo "AUTO_RUN=true" >> .env
            echo -e "${GREEN}[+] Mode Auto-Run diaktifkan! Untuk mengubahnya nanti, jalankan: ./run.sh --settings${RESET}"
        else
            echo -e "${CYAN}[*] Mode Auto-Run dibiarkan nonaktif.${RESET}"
        fi
        touch "$ANIMETERMUX_DIR/.autorun_prompted"
    fi
}

select_and_open_link() {
    local options=()
    options+=("1) Lokal (http://localhost:$HTTP_PORT)")
    options+=("2) Lokal Jaringan (http://$LOCAL_IP:$HTTP_PORT)")
    if [ -n "$PUBLIC_URL" ]; then
        options+=("3) Online Tunnel ($PUBLIC_URL)")
    fi
    options+=("x) Jangan Buka Browser / Batal")

    local selected_option
    if command -v fzf &>/dev/null; then
        selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 10 --layout=reverse --border --prompt="Pilih URL yang ingin dibuka di browser: " --header="PILIH URL AKSES WEB")
        if [ $? -eq 130 ] || [ -z "$selected_option" ]; then
            echo -e "${YELLOW}[*] Batal membuka browser.${RESET}"
            return
        fi
    else
        echo -e "\nPilih URL untuk dibuka di browser:"
        for opt in "${options[@]}"; do
            echo -e "  $opt"
        done
        read -p "Masukkan pilihan (1/2/3/x, default: x): " selected_option
        if [ -z "$selected_option" ]; then
            selected_option="x"
        fi
    fi

    # Extract target URL
    local target_url=""
    if [[ "$selected_option" == *"1)"* ]] || [[ "$selected_option" == "1" ]]; then
        target_url="http://localhost:$HTTP_PORT"
    elif [[ "$selected_option" == *"2)"* ]] || [[ "$selected_option" == "2" ]]; then
        target_url="http://$LOCAL_IP:$HTTP_PORT"
    elif { [[ "$selected_option" == *"3)"* ]] || [[ "$selected_option" == "3" ]]; }; then
        if [ -n "$PUBLIC_URL" ]; then
            target_url="$PUBLIC_URL"
        fi
    fi

    if [ -n "$target_url" ]; then
        echo -e "${GREEN}[*] Membuka: $target_url${RESET}"
        if command -v termux-open &>/dev/null; then
            termux-open "$target_url" >/dev/null 2>&1
        elif command -v xdg-open &>/dev/null; then
            xdg-open "$target_url" >/dev/null 2>&1
        elif command -v open &>/dev/null; then
            open "$target_url" >/dev/null 2>&1
        else
            am start -a android.intent.action.VIEW -d "$target_url" >/dev/null 2>&1
        fi
    else
        echo -e "${YELLOW}[*] Batal membuka browser.${RESET}"
    fi
}


# Termux DNS Repair (Fixes DNS lookup issue for Ngrok and Cloudflare Tunnels)
if [ "$IS_TERMUX" = true ] && [ -n "$PREFIX" ]; then
    mkdir -p "$PREFIX/etc"
    if [ ! -f "$PREFIX/etc/resolv.conf" ] || ! grep -q "8.8.8.8" "$PREFIX/etc/resolv.conf"; then
        echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > "$PREFIX/etc/resolv.conf"
        echo -e "${GREEN}[*] Konfigurasi DNS Termux diperbaiki untuk Ngrok/Cloudflare${RESET}"
    fi
fi

# Setup termux-chroot prefix for Go DNS fix
CHROOT_PREFIX=""
if [ "$IS_TERMUX" = true ]; then
    if ! command -v termux-chroot &>/dev/null; then
        echo -e "${YELLOW}[*] Mendeteksi Termux: Menginstal paket proot dan resolv-conf untuk perbaikan DNS...${RESET}"
        pkg install proot resolv-conf -y
        record_installed_package "proot"
        record_installed_package "resolv-conf"
    fi
    if command -v termux-chroot &>/dev/null; then
        CHROOT_PREFIX="termux-chroot"
    fi
fi

# 0. Termux & Storage Check
CURRENT_DIR=$(pwd)
if [[ "$CURRENT_DIR" == /storage/emulated/0/* ]]; then
    echo -e "\n${RED}[-] PERHATIAN: Memori Internal Android Terdeteksi!${RESET}"
    echo -e "${YELLOW}[*] Sistem file Android tidak mendukung 'symlink' NPM.${RESET}"
    echo -e "${CYAN}[*] Sedang memindahkan proyek secara otomatis ke Home Termux...${RESET}"
    
    TARGET_DIR="$HOME/$(basename "$CURRENT_DIR")"
    cp -r "$CURRENT_DIR" "$TARGET_DIR"
    
    echo -e "${GREEN}[+] Proyek berhasil dipindahkan ke: $TARGET_DIR${RESET}"
    echo -e "${YELLOW}[!] HARAP JALANKAN PERINTAH BERIKUT MANUAL UNTUK MELANJUTKAN:${RESET}"
    echo -e "${BOLD}cd \"$TARGET_DIR\" && ./run.sh${RESET}\n"
    exit 1
fi

# 1. Dependency Checks & Auto-Install
echo -e "${CYAN}[*] Memeriksa dependensi sistem...${RESET}"

record_installed_package() {
    local pkg_name=$1
    if [ ! -f ".installed_packages.json" ] || [ ! -s ".installed_packages.json" ]; then
        echo "[\"$pkg_name\"]" > .installed_packages.json
    else
        if ! grep -q "\"$pkg_name\"" .installed_packages.json; then
            local content
            content=$(cat .installed_packages.json)
            content=${content%\]}
            echo "$content, \"$pkg_name\"]" > .installed_packages.json
        fi
    fi
}

install_pkg() {
    PKG_NAME=$1
    local is_steamos_locked=false
    if [ -f "/etc/steamos-release" ]; then
        if findmnt -n -o OPTIONS / | grep -Eq '\bro\b'; then
            is_steamos_locked=true
        fi
    fi
    # Special alias checks if command-v doesn't match package name exactly
    local test_cmd="$PKG_NAME"
    if [ "$PKG_NAME" == "python-pip" ] || [ "$PKG_NAME" == "python3-pip" ] || [ "$PKG_NAME" == "py-pip" ] || [ "$PKG_NAME" == "py3-pip" ]; then
        test_cmd="pip"
    elif [ "$PKG_NAME" == "nodejs" ]; then
        test_cmd="node"
    fi

    if ! command -v $test_cmd &> /dev/null; then
        echo -e "${YELLOW}[*] $PKG_NAME belum terinstal. Menginstal otomatis...${RESET}"
        WAS_AUTO_INSTALLED=false
        
        # 1. macOS (Darwin) or locked SteamOS (Steam Deck) local/rootless path
        if [[ "$(uname)" == "Darwin" ]] || [ "$is_steamos_locked" = true ]; then
            # Ensure ~/.local/bin is in PATH
            mkdir -p "$HOME/.local/bin"
            if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
                export PATH="$HOME/.local/bin:$PATH"
                local SHELL_RC=".$(basename "${SHELL:-bash}")rc"
                [ -f "$HOME/$SHELL_RC" ] && echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/$SHELL_RC"
            fi

            if [ "$PKG_NAME" == "python-pip" ] || [ "$PKG_NAME" == "python3-pip" ] || [ "$PKG_NAME" == "py-pip" ] || [ "$PKG_NAME" == "py3-pip" ]; then
                echo -e "${GREEN}[+] pip akan terpasang secara otomatis di dalam virtual environment Python.${RESET}"
                WAS_AUTO_INSTALLED=true
                return 0
            elif [ "$PKG_NAME" == "nginx" ]; then
                if [ "$is_steamos_locked" = true ]; then
                    echo -e "${CYAN}[*] Mendeteksi SteamOS (Locked). Menginstal Nginx portabel secara lokal...${RESET}"
                    mkdir -p "$HOME/.local/opt/nginx"
                    echo -e "${CYAN}[*] Mengunduh & mengekstrak paket Nginx Arch Linux...${RESET}"
                    if curl -L "https://archlinux.org/packages/extra/x86_64/nginx/download/" | tar -xI zstd -C "$HOME/.local/opt/nginx" --strip-components=1 usr/bin/nginx usr/share/nginx; then
                        mkdir -p "$HOME/.local/bin"
                        ln -sf "$HOME/.local/opt/nginx/bin/nginx" "$HOME/.local/bin/nginx"
                        export PATH="$HOME/.local/bin:$PATH"
                        WAS_AUTO_INSTALLED=true
                        return 0
                    else
                        echo -e "${RED}[-] Gagal mengunduh atau mengekstrak Nginx portabel.${RESET}"
                    fi
                elif [[ "$(uname)" == "Darwin" ]]; then
                    if command -v brew &>/dev/null; then
                        echo -e "${CYAN}[*] Menginstal Nginx menggunakan Homebrew...${RESET}"
                        brew install nginx && WAS_AUTO_INSTALLED=true
                        return 0
                    else
                        echo -e "${YELLOW}[!] Homebrew tidak ditemukan. Silakan pasang Nginx secara manual menggunakan: brew install nginx${RESET}"
                        return 1
                    fi
                fi
            elif [ "$PKG_NAME" == "fzf" ]; then
                local ARCH_TYPE=$(uname -m)
                local FZF_ARCH="amd64"
                local OS_NAME="linux"
                
                if [[ "$(uname)" == "Darwin" ]]; then
                    OS_NAME="darwin"
                fi
                if [[ "$ARCH_TYPE" == "arm64" ]] || [[ "$ARCH_TYPE" == "aarch64" ]]; then
                    FZF_ARCH="arm64"
                fi
                
                echo -e "${CYAN}[*] Menginstal fzf secara lokal di ~/.local/bin...${RESET}"
                local FZF_VER="0.48.0"
                local FZF_URL="https://github.com/junegunn/fzf/releases/download/v${FZF_VER}/fzf-${FZF_VER}-${OS_NAME}_${FZF_ARCH}.tar.gz"
                if curl -fsSL "$FZF_URL" | tar -xz -C "$HOME/.local/bin" fzf; then
                    chmod +x "$HOME/.local/bin/fzf"
                    WAS_AUTO_INSTALLED=true
                    return 0
                fi
            elif [ "$PKG_NAME" == "node" ] || [ "$PKG_NAME" == "npm" ] || [ "$PKG_NAME" == "nodejs" ]; then
                if command -v node &>/dev/null && command -v npm &>/dev/null; then
                    WAS_AUTO_INSTALLED=true
                    return 0
                fi
                
                local ARCH_TYPE=$(uname -m)
                local NODE_ARCH="x64"
                local OS_NAME="linux"
                
                if [[ "$(uname)" == "Darwin" ]]; then
                    OS_NAME="darwin"
                fi
                if [[ "$ARCH_TYPE" == "arm64" ]] || [[ "$ARCH_TYPE" == "aarch64" ]]; then
                    NODE_ARCH="arm64"
                fi
                
                echo -e "${CYAN}[*] Menginstal Node.js secara lokal di ~/.local/opt...${RESET}"
                local NODE_VER="v20.11.1"
                local NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-${OS_NAME}-${NODE_ARCH}.tar.gz"
                if [[ "$OS_NAME" == "linux" ]]; then
                    NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-${OS_NAME}-${NODE_ARCH}.tar.xz"
                fi
                
                mkdir -p "$HOME/.local/opt"
                local TAR_FLAG="-xz"
                if [[ "$OS_NAME" == "linux" ]]; then
                    TAR_FLAG="-xJ"
                fi
                
                if curl -fsSL "$NODE_URL" | tar $TAR_FLAG -C "$HOME/.local/opt"; then
                    ln -sf "$HOME/.local/opt/node-${NODE_VER}-${OS_NAME}-${NODE_ARCH}/bin/node" "$HOME/.local/bin/node"
                    ln -sf "$HOME/.local/opt/node-${NODE_VER}-${OS_NAME}-${NODE_ARCH}/bin/npm" "$HOME/.local/bin/npm"
                    ln -sf "$HOME/.local/opt/node-${NODE_VER}-${NODE_ARCH}/bin/npx" "$HOME/.local/bin/npx"
                    export PATH="$HOME/.local/bin:$PATH"
                    WAS_AUTO_INSTALLED=true
                    return 0
                fi
            elif [ "$PKG_NAME" == "git" ] || [ "$PKG_NAME" == "python" ] || [ "$PKG_NAME" == "python3" ]; then
                if [ "$is_steamos_locked" = true ]; then
                    if [ "$PKG_NAME" == "git" ]; then
                        echo -e "${CYAN}[*] Mendeteksi SteamOS (Locked). Menginstal Git portabel secara lokal...${RESET}"
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
                            WAS_AUTO_INSTALLED=true
                            return 0
                        else
                            echo -e "${RED}[-] Gagal mengunduh atau mengekstrak Git portabel.${RESET}"
                        fi
                    elif [ "$PKG_NAME" == "python" ] || [ "$PKG_NAME" == "python3" ]; then
                        echo -e "${CYAN}[*] Mendeteksi SteamOS (Locked). Menginstal Python portabel secara lokal...${RESET}"
                        mkdir -p "$HOME/.local/opt/python"
                        echo -e "${CYAN}[*] Mengunduh & mengekstrak paket Python Arch Linux...${RESET}"
                        if curl -L "https://archlinux.org/packages/core/x86_64/python/download/" | tar -xI zstd -C "$HOME/.local/opt/python" --strip-components=1 usr/bin usr/lib; then
                            mkdir -p "$HOME/.local/bin"
                            # Create wrapper or symlink
                            ln -sf "$HOME/.local/opt/python/bin/python3" "$HOME/.local/bin/python3"
                            ln -sf "$HOME/.local/opt/python/bin/python3" "$HOME/.local/bin/python"
                            export PATH="$HOME/.local/bin:$PATH"
                            WAS_AUTO_INSTALLED=true
                            return 0
                        else
                            echo -e "${RED}[-] Gagal mengunduh atau mengekstrak Python portabel.${RESET}"
                        fi
                    fi
                elif [[ "$(uname)" == "Darwin" ]]; then
                    echo -e "${YELLOW}[!] Git atau Python tidak ditemukan.${RESET}"
                    echo -e "${YELLOW}[!] Memicu instalasi Xcode Command Line Tools. Silakan setujui dialog yang muncul.${RESET}"
                    xcode-select --install 2>/dev/null || true
                    echo -e "${YELLOW}[!] Tekan Enter setelah instalasi Xcode Command Line Tools selesai untuk melanjutkan...${RESET}"
                    read -p ""
                    if command -v $PKG_NAME &>/dev/null; then
                        WAS_AUTO_INSTALLED=true
                        return 0
                    fi
                fi
            fi
        else
            # 2. General Linux/FreeBSD/Termux path
            # Map package names for specific package managers
            local actual_pkg="$PKG_NAME"
            if command -v apk &>/dev/null; then
                if [ "$PKG_NAME" == "python" ]; then
                    actual_pkg="python3"
                elif [ "$PKG_NAME" == "python-pip" ] || [ "$PKG_NAME" == "python3-pip" ] || [ "$PKG_NAME" == "py3-pip" ]; then
                    actual_pkg="py3-pip"
                fi
            elif [[ "$(uname)" == "FreeBSD" ]]; then
                if [ "$PKG_NAME" == "python" ]; then
                    actual_pkg="python3"
                elif [ "$PKG_NAME" == "python-pip" ] || [ "$PKG_NAME" == "python3-pip" ] || [ "$PKG_NAME" == "py3-pip" ]; then
                    actual_pkg="py-pip"
                elif [ "$PKG_NAME" == "nodejs" ]; then
                    actual_pkg="node"
                fi
            fi

            if [ -n "$actual_pkg" ]; then
                if command -v pkg &>/dev/null; then
                    if [[ "$(uname)" == "FreeBSD" ]]; then
                        if [ "$(id -u)" -ne 0 ]; then
                            sudo pkg install -y $actual_pkg && WAS_AUTO_INSTALLED=true
                        else
                            pkg install -y $actual_pkg && WAS_AUTO_INSTALLED=true
                        fi
                    else
                        pkg install $actual_pkg -y && WAS_AUTO_INSTALLED=true
                    fi
                elif command -v apk &>/dev/null; then
                    if [ "$(id -u)" -ne 0 ]; then
                        sudo apk add --no-cache $actual_pkg && WAS_AUTO_INSTALLED=true
                    else
                        apk add --no-cache $actual_pkg && WAS_AUTO_INSTALLED=true
                    fi
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --noconfirm $actual_pkg && WAS_AUTO_INSTALLED=true
                elif command -v yay &>/dev/null; then
                    yay -S --noconfirm $actual_pkg && WAS_AUTO_INSTALLED=true
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y $actual_pkg && WAS_AUTO_INSTALLED=true
                elif command -v apt-get &>/dev/null; then
                    sudo apt-get update && sudo apt-get install -y $actual_pkg && WAS_AUTO_INSTALLED=true
                elif command -v apt &>/dev/null; then
                    sudo apt update && sudo apt install -y $actual_pkg && WAS_AUTO_INSTALLED=true
                fi
            fi
        fi

        if [ "$WAS_AUTO_INSTALLED" = false ]; then
            echo -e "${RED}[-] Gagal menginstal $PKG_NAME secara otomatis.${RESET}"
            echo -e "${YELLOW}[!] Silakan instal $PKG_NAME secara manual dan jalankan kembali script ini.${RESET}"
            exit 1
        else
            echo -e "${GREEN}[+] $PKG_NAME berhasil dipasang!${RESET}"
        fi
        
        # Save installed package to history ONLY if we auto-installed it
        if [ "$WAS_AUTO_INSTALLED" = true ]; then
            if [ ! -f ".installed_packages.json" ] || [ ! -s ".installed_packages.json" ]; then
                echo "[\"$PKG_NAME\"]" > .installed_packages.json
            else
                local content
                content=$(cat .installed_packages.json)
                content=${content%\]}
                echo "$content, \"$PKG_NAME\"]" > .installed_packages.json
            fi
        fi
    fi
}

# Ensure git is installed
if ! command -v git &> /dev/null; then
    install_pkg git
fi

# Ensure fzf is installed
if ! command -v fzf &> /dev/null; then
    install_pkg fzf
fi

# Ensure nginx is installed
export NO_NGINX=false
if ! command -v nginx &> /dev/null; then
    install_pkg nginx
fi

# Ensure python, pip, and nodejs/npm are installed
if ! command -v python &> /dev/null && ! command -v python3 &> /dev/null; then
    install_pkg python
fi

if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
    if command -v pacman &> /dev/null || command -v yay &> /dev/null; then
        install_pkg python-pip
    elif command -v dnf &> /dev/null; then
        install_pkg python3-pip
    elif command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
        install_pkg python3-pip
    elif command -v apk &> /dev/null; then
        install_pkg py3-pip
    elif [[ "$(uname)" == "FreeBSD" ]]; then
        install_pkg py-pip
    fi
fi

# Setup Virtual Environment if missing, otherwise check dependencies
VENV_DIR="backend/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}[*] Python virtual environment tidak ditemukan. Membuat venv...${RESET}"
    python3 -m venv --system-site-packages "$VENV_DIR"
fi
# Python dependencies will be installed after Telegram setup

if [ ! -d "frontend/dist" ] || [ ! -f "frontend/dist/index.html" ]; then
    echo -e "${RED}[-] Folder kompilasi frontend (frontend/dist/index.html) tidak ditemukan!${RESET}"
    echo -e "${RED}[-] Pastikan folder dist telah diunggah secara utuh.${RESET}"
    exit 1
fi



# Create logs directory
mkdir -p backend/logs

# 2. Token & Chat ID Configuration (For Image Caching API)
if [ "$SKIP_TELEGRAM" == "true" ]; then
    echo -e "${YELLOW}[*] Mode Hotlink Gambar (Tanpa CDN Telegram) Aktif.${RESET}"
else
    # Upgraded Bot Token input: support multiple tokens separated by commas
    if [ -z "$BOT_TOKEN" ] && [ -z "$BOT_TOKENS" ]; then
        if [ "$AUTO_RUN" == "true" ]; then
            echo -e "${YELLOW}[*] Auto-Run Aktif: Token Bot kosong, otomatis mengaktifkan Mode Hotlink Gambar.${RESET}"
            echo "SKIP_TELEGRAM=true" >> .env
            export SKIP_TELEGRAM="true"
        else
            if command -v fzf &>/dev/null; then
                options=(
                    "1) Hotlink Langsung dari Web Asli (Lebih lambat & berisiko gambar mati)"
                    "2) Gunakan Bot Telegram sebagai CDN (Gratis, Sangat Cepat & Anti-Banned)"
                )
                selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Pilih metode penyimpanan gambar: " --header="KONFIGURASI PENYIMPANAN GAMBAR")
                if [ $? -eq 130 ]; then
                    echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
                    exit 130
                fi
                if [ -z "$selected_option" ]; then
                    IMG_METHOD="1"
                else
                    IMG_METHOD=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
                fi
            else
                echo -e "\n${BLUE}${BOLD}=======================================================${RESET}"
                echo -e "${GREEN}${BOLD}           KONFIGURASI PENYIMPANAN GAMBAR              ${RESET}"
                echo -e "${BLUE}${BOLD}=======================================================${RESET}"
                echo -e "Aplikasi membutuhkan cara untuk memuat gambar thumbnail."
                echo -e "1) Hotlink Langsung dari Web Asli (Lebih lambat & berisiko gambar mati)"
                echo -e "2) Gunakan Bot Telegram sebagai CDN (Gratis, Sangat Cepat & Anti-Banned)"
                echo -e ""
                read -p "Pilih metode (1 atau 2, default: 1): " IMG_METHOD
            fi
            
            if [ "$IMG_METHOD" == "1" ]; then
                echo -e "${YELLOW}[*] Mode Hotlink diaktifkan. Anda bisa mengaturnya nanti via --settings.${RESET}"
                echo "SKIP_TELEGRAM=true" >> .env
                export SKIP_TELEGRAM="true"
            else
                echo -e "\n${YELLOW}[!] Token Bot Telegram tidak ditemukan. Mari konfigurasi bot Anda.${RESET}"
                read -p "Masukkan Token Bot Telegram Anda (bisa banyak, dipisahkan koma): " BOT_TOKENS_INPUT
                
                if [ -z "$BOT_TOKENS_INPUT" ]; then
                    echo -e "${RED}[-] Token tidak boleh kosong! Dibatalkan.${RESET}"
                    exit 1
                fi
                
                # Parse the first token as BOT_TOKEN for legacy compatibility, and BOT_TOKENS as full list
                FIRST_BOT_TOKEN=$(echo "$BOT_TOKENS_INPUT" | cut -d',' -f1 | tr -d ' ')
                
                # Save to main .env
                if [ -f ".env" ]; then
                    grep -v "BOT_TOKEN" .env > .env.tmp && mv .env.tmp .env
                    grep -v "BOT_TOKENS" .env > .env.tmp && mv .env.tmp .env
                fi
                echo "BOT_TOKEN=$FIRST_BOT_TOKEN" >> .env
                echo "BOT_TOKENS=$BOT_TOKENS_INPUT" >> .env
                export BOT_TOKEN="$FIRST_BOT_TOKEN"
                export BOT_TOKENS="$BOT_TOKENS_INPUT"
                
                echo -e "${GREEN}[+] Token berhasil disimpan!${RESET}\n"
            fi
        fi
    fi

    # Chat IDs Configuration: Only prompt if SKIP_TELEGRAM is not true
    if [ "$SKIP_TELEGRAM" != "true" ]; then
        CHAT_IDS_EXIST=false
        if [ -f ".chat_ids" ] && [ -s ".chat_ids" ]; then
            CHAT_IDS_EXIST=true
        elif [ -f "backend/.chat_ids" ] && [ -s "backend/.chat_ids" ]; then
            CHAT_IDS_EXIST=true
        fi

        if [ "$CHAT_IDS_EXIST" = false ]; then
            if [ "$AUTO_RUN" == "true" ]; then
                echo -e "${YELLOW}[*] Auto-Run Aktif: Mengisi Chat ID bawaan (0).${RESET}"
                CLEANED_CHAT_IDS="0"
                echo "$CLEANED_CHAT_IDS" > ".chat_ids"
                echo "$CLEANED_CHAT_IDS" > "backend/.chat_ids"
            else
                echo -e "${YELLOW}[!] File .chat_ids tidak ditemukan. Mari konfigurasikan Chat ID penerima.${RESET}"
                read -p "Masukkan Chat ID / ID Grup Anda (bisa banyak, dipisahkan koma): " CHAT_IDS_INPUT
                if [ -z "$CHAT_IDS_INPUT" ]; then
                    echo -e "${RED}[-] Chat ID tidak boleh kosong! Dibatalkan.${RESET}"
                    exit 1
                fi
                
                # Convert comma-separated string to newlines
                CLEANED_CHAT_IDS=$(echo "$CHAT_IDS_INPUT" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$')
                
                # Save to all locations
                echo "$CLEANED_CHAT_IDS" > ".chat_ids"
                echo "$CLEANED_CHAT_IDS" > "backend/.chat_ids"
                
                echo -e "${GREEN}[+] Chat ID berhasil disimpan ke file .chat_ids!${RESET}\n"
            fi
        fi
    fi
fi

# ==========================================
# Install Python Dependencies Based on Mode
# ==========================================
if [ "$SKIP_TELEGRAM" == "true" ]; then
    PY_DEPS="flask flask-cors requests beautifulsoup4 python-dotenv gunicorn"
    PY_IMPORT_CHECK="import flask, flask_cors, requests, bs4, dotenv, gunicorn"
else
    PY_DEPS="flask flask-cors requests beautifulsoup4 python-telegram-bot python-dotenv gunicorn"
    PY_IMPORT_CHECK="import flask, flask_cors, requests, bs4, telegram, dotenv, gunicorn"
fi

# Check Python dependencies inside the virtualenv
if ! $VENV_DIR/bin/python -c "$PY_IMPORT_CHECK" &> /dev/null; then
    echo -e "${YELLOW}[*] Dependensi Python belum lengkap. Menginstal...${RESET}"
    
    # Khusus Alpine / iSH (agar tidak melakukan kompilasi cryptography dari source)
    if command -v apk &>/dev/null; then
        echo -e "${CYAN}[*] Mendeteksi Alpine/iSH. Menginstal py3-cryptography precompiled agar tidak kompilasi...${RESET}"
        if [ "$(id -u)" -ne 0 ]; then
            sudo apk add --no-cache py3-cryptography
        else
            apk add --no-cache py3-cryptography
        fi
    fi
    
    $VENV_DIR/bin/pip install $PY_DEPS
fi

# 3. Tunnel Configuration (Ngrok / Cloudflare)
TUNNEL_TYPE="none"
PUBLIC_URL=""
CF_PID=""
NG_PID=""

DEF_TUNNEL=${DEFAULT_TUNNEL:-1}
if [ "$DEF_TUNNEL" == "1" ]; then
    PROMPT_TUNNEL="1 (Tidak)"
elif [ "$DEF_TUNNEL" == "2" ]; then
    PROMPT_TUNNEL="2 (Cloudflare)"
elif [ "$DEF_TUNNEL" == "3" ]; then
    PROMPT_TUNNEL="3 (Ngrok)"
fi

if [ "$AUTO_RUN" == "true" ]; then
    tunnel_pilihan="$DEF_TUNNEL"
    echo -e "${GREEN}[*] Auto-Run Aktif: Memilih Tunnel $PROMPT_TUNNEL secara otomatis.${RESET}"
else
    if command -v fzf &>/dev/null; then
        options=(
            "1) Tidak (Hanya lokal wifi/HP)"
            "2) Gunakan Cloudflare Tunnel (Gratis, Tanpa Daftar, Paling Mudah!)"
            "3) Gunakan Ngrok (Butuh Authtoken dari ngrok.com)"
        )
        selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 9 --layout=reverse --border --prompt="Pilih akses online / tunneling [default: $PROMPT_TUNNEL]: " --header="AKSES BEDA JARINGAN (ONLINE / TUNNELING) CONFIG")
        if [ $? -eq 130 ]; then
            echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
            exit 130
        fi
        if [ -z "$selected_option" ]; then
            tunnel_pilihan="$DEF_TUNNEL"
        else
            tunnel_pilihan=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
        fi
    else
        echo -e "\n${BLUE}${BOLD}=======================================================${RESET}"
        echo -e "${GREEN}${BOLD}   AKSES BEDA JARINGAN (ONLINE / TUNNELING) CONFIG   ${RESET}"
        echo -e "${BLUE}${BOLD}=======================================================${RESET}"
        echo -e "Apakah Anda ingin membuat web ini online agar bisa diakses dari"
        echo -e "luar rumah / beda jaringan?"
        echo -e "1) Tidak (Hanya lokal wifi/HP)"
        echo -e "2) Gunakan Cloudflare Tunnel (Gratis, Tanpa Daftar, Paling Mudah!)"
        echo -e "3) Gunakan Ngrok (Butuh Authtoken dari ngrok.com)"
        echo -e ""
        read -p "Masukkan pilihan Anda (1, 2, atau 3, atau Enter untuk $PROMPT_TUNNEL): " tunnel_pilihan
        
        if [ -z "$tunnel_pilihan" ]; then
            tunnel_pilihan="$DEF_TUNNEL"
        fi
    fi
    
    if [ "$tunnel_pilihan" != "$DEFAULT_TUNNEL" ]; then
        if [ -f ".env" ]; then
            grep -v "DEFAULT_TUNNEL" .env > .env.tmp && mv .env.tmp .env
        fi
        echo "DEFAULT_TUNNEL=$tunnel_pilihan" >> .env
    fi
fi

if [ "$tunnel_pilihan" == "2" ]; then
    TUNNEL_TYPE="cloudflare"
elif [ "$tunnel_pilihan" == "3" ]; then
    TUNNEL_TYPE="ngrok"
fi

# Setup Cloudflare Tunnel
if [ "$TUNNEL_TYPE" == "cloudflare" ]; then
    echo -e "${CYAN}[*] Mempersiapkan Cloudflare Tunnel...${RESET}"
    if ! command -v cloudflared &>/dev/null; then
        if [ "$IS_TERMUX" = true ] && command -v pkg &>/dev/null; then
            echo -e "${YELLOW}[*] Mendeteksi Termux: Mencoba menginstal cloudflared secara native dari repositori...${RESET}"
            pkg install cloudflared -y
            record_installed_package "cloudflared"
        fi
        
        if command -v cloudflared &>/dev/null; then
            CF_COMMAND="cloudflared"
        elif [ -f "./cloudflared" ] && [ $(wc -c < "./cloudflared") -gt 100000 ] && $CHROOT_PREFIX ./cloudflared --version &>/dev/null; then
            CF_COMMAND="./cloudflared"
        else
            rm -f "./cloudflared"
            echo -e "${YELLOW}[*] cloudflared belum terinstal. Mengunduh versi mandiri...${RESET}"
            ARCH=$(uname -m)
            CF_URL=""
            if [[ "$ARCH" == "aarch64" ]]; then
                CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            elif [[ "$ARCH" == "arm"* ]]; then
                CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            elif [[ "$ARCH" == "x86_64" ]]; then
                CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            fi
            
            if [ -n "$CF_URL" ]; then
                curl -L -o cloudflared "$CF_URL"
                chmod +x cloudflared
                CF_COMMAND="./cloudflared"
            else
                echo -e "${RED}[-] Arsitektur tidak didukung untuk auto-download Cloudflare Tunnel.${RESET}"
                TUNNEL_TYPE="none"
            fi
        fi
    else
        CF_COMMAND="cloudflared"
    fi
fi

# Setup Ngrok
if [ "$TUNNEL_TYPE" == "ngrok" ]; then
    echo -e "${CYAN}[*] Mempersiapkan Ngrok...${RESET}"
    if ! command -v ngrok &>/dev/null; then
        if [ -f "./ngrok" ] && [ $(wc -c < "./ngrok") -gt 100000 ] && $CHROOT_PREFIX ./ngrok --version &>/dev/null; then
            NG_COMMAND="./ngrok"
        else
            rm -f "./ngrok"
            echo -e "${YELLOW}[*] ngrok belum terinstal. Mengunduh versi mandiri...${RESET}"
            ARCH=$(uname -m)
            NG_URL=""
            if [[ "$ARCH" == "aarch64" ]]; then
                NG_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz"
            elif [[ "$ARCH" == "arm"* ]]; then
                NG_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm.tgz"
            elif [[ "$ARCH" == "x86_64" ]]; then
                NG_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"
            fi
            
            if [ -n "$NG_URL" ]; then
                curl -L -o ngrok.tgz "$NG_URL"
                tar -xzf ngrok.tgz
                rm ngrok.tgz
                chmod +x ngrok
                NG_COMMAND="./ngrok"
            else
                echo -e "${RED}[-] Arsitektur tidak didukung untuk auto-download Ngrok.${RESET}"
                TUNNEL_TYPE="none"
            fi
        fi
    else
        NG_COMMAND="ngrok"
    fi
    
    if [ "$TUNNEL_TYPE" == "ngrok" ]; then
        if [ -z "$NGROK_AUTHTOKEN" ]; then
            if [ "$AUTO_RUN" == "true" ]; then
                echo -e "${RED}[-] Auto-Run Aktif: NGROK_AUTHTOKEN belum dikonfigurasi. Membatalkan tunnel.${RESET}"
                TUNNEL_TYPE="none"
            else
                echo -e "\n${YELLOW}[!] NGROK_AUTHTOKEN belum dikonfigurasi di file .env.${RESET}"
                read -p "Masukkan Ngrok Authtoken Anda: " ngrok_token
                if [ -n "$ngrok_token" ]; then
                    if [ -f ".env" ]; then
                        grep -v "NGROK_AUTHTOKEN" .env > .env.tmp && mv .env.tmp .env
                    fi
                    echo "NGROK_AUTHTOKEN=$ngrok_token" >> .env
                    export NGROK_AUTHTOKEN="$ngrok_token"
                    echo -e "${GREEN}[+] Authtoken disimpan ke .env!${RESET}"
                else
                    echo -e "${RED}[-] Token kosong. Pembatalan tunnel.${RESET}"
                    TUNNEL_TYPE="none"
                fi
            fi
        fi

        # Check and prompt for NGROK_DOMAIN
        if [ "$TUNNEL_TYPE" == "ngrok" ] && [ -z "$NGROK_DOMAIN" ]; then
            if [ "$AUTO_RUN" == "true" ]; then
                echo -e "${CYAN}[*] Auto-Run Aktif: NGROK_DOMAIN dibiarkan kosong (dinamis).${RESET}"
            else
                echo -e "\n${YELLOW}[!] NGROK_DOMAIN belum dikonfigurasi di file .env.${RESET}"
                read -p "Masukkan Ngrok Domain Anda (jika sudah punya). Tekan Enter jika ingin biarkan dinamis/kosong: " ngrok_domain_input
                if [ -n "$ngrok_domain_input" ]; then
                    if [ -f ".env" ]; then
                        grep -v "NGROK_DOMAIN" .env > .env.tmp && mv .env.tmp .env
                    fi
                    echo "NGROK_DOMAIN=$ngrok_domain_input" >> .env
                    export NGROK_DOMAIN="$ngrok_domain_input"
                    echo -e "${GREEN}[+] Domain berhasil disimpan ke .env!${RESET}"
                else
                    echo -e "${CYAN}[*] Domain dibiarkan kosong (Ngrok akan membuat subdomain acak secara dinamis).${RESET}"
                fi
            fi
        fi
    fi
fi

# Add termux-chroot prefix if available to resolve Go DNS resolution issues
if [ -n "$CHROOT_PREFIX" ]; then
    [ "$TUNNEL_TYPE" == "cloudflare" ] && [ -n "$CF_COMMAND" ] && CF_COMMAND="$CHROOT_PREFIX $CF_COMMAND"
    [ "$TUNNEL_TYPE" == "ngrok" ] && [ -n "$NG_COMMAND" ] && NG_COMMAND="$CHROOT_PREFIX $NG_COMMAND"
fi

# 3. Running the Services
echo -e "\n${YELLOW}[*] Memeriksa server yang sedang berjalan...${RESET}"

detected_any=false

kill_process_by_pattern() {
    local pattern="$1"
    local name="$2"
    # Find all PIDs matching the pattern, excluding our own run.sh PID ($$)
    local pids=$(pgrep -f "$pattern" | grep -v "$$")
    if [ -n "$pids" ]; then
        echo -e "    ${RED}[X] Mendeteksi ${name} aktif (PID: $(echo $pids | tr '\n' ' ')). Menghentikan...${RESET}"
        for pid in $pids; do
            kill -9 "$pid" &>/dev/null
        done
        detected_any=true
    fi
}

kill_process_by_pattern "play.py" "Bot Telegram (play.py)"
kill_process_by_pattern "web_server.py" "Web Server Anime (web_server.py)"
kill_process_by_pattern "cloudflared" "Cloudflare Tunnel"
kill_process_by_pattern "ngrok" "Ngrok Tunnel"

if [ "$detected_any" == "true" ]; then
    echo -e "    ${GREEN}[+] Semua server lama berhasil dihentikan.${RESET}"
else
    echo -e "    ${GREEN}[+] Tidak ada server aktif yang terdeteksi.${RESET}"
fi
sleep 1

DEF_MODE=${DEFAULT_MODE:-1}
if [ "$DEF_MODE" == "1" ]; then
    PROMPT_MODE="1 (Foreground)"
else
    PROMPT_MODE="2 (Background)"
fi

if [ "$AUTO_RUN" == "true" ]; then
    pilihan="$DEF_MODE"
    echo -e "${GREEN}[*] Auto-Run Aktif: Memilih Mode Berjalan $PROMPT_MODE secara otomatis.${RESET}"
else
    if command -v fzf &>/dev/null; then
        options=(
            "1) Foreground (Berjalan langsung di terminal, matikan dengan Ctrl+C)"
            "2) Background (Berjalan di latar belakang, tetap aktif meskipun Termux ditutup)"
        )
        selected_option=$(printf "%s\n" "${options[@]}" | fzf --height 8 --layout=reverse --border --prompt="Pilih mode untuk menjalankan sistem [default: $PROMPT_MODE]: ")
        if [ $? -eq 130 ]; then
            echo -e "\n${RED}[!] Dibatalkan. Keluar...${RESET}"
            exit 130
        fi
        if [ -z "$selected_option" ]; then
            pilihan="$DEF_MODE"
        else
            pilihan=$(echo "$selected_option" | cut -d')' -f1 | tr -d ' ')
        fi
    else
        echo -e "Pilih mode untuk menjalankan sistem:"
        echo -e "1) Foreground (Berjalan langsung di terminal, matikan dengan Ctrl+C)"
        echo -e "2) Background (Berjalan di latar belakang, tetap aktif meskipun Termux ditutup)"
        echo -e ""
        read -p "Masukkan pilihan Anda (1 atau 2, atau Enter untuk $PROMPT_MODE): " pilihan
        
        if [ -z "$pilihan" ]; then
            pilihan="$DEF_MODE"
        fi
    fi
    
    if [ "$pilihan" != "$DEFAULT_MODE" ]; then
        if [ -f ".env" ]; then
            grep -v "DEFAULT_MODE" .env > .env.tmp && mv .env.tmp .env
        fi
        echo "DEFAULT_MODE=$pilihan" >> .env
    fi
fi

# Function to get local IP
get_local_ip() {
    LOCAL_IP=$(python3 -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
    s.close()
except:
    print('')
" 2>/dev/null)
    [ -z "$LOCAL_IP" ] && LOCAL_IP=$(ip -4 addr 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '127.0.0.1' | head -1)
    [ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '127.0.0.1' | grep -v '^$' | head -1)
    [ -z "$LOCAL_IP" ] && LOCAL_IP="Tidak terdeteksi"
    echo "$LOCAL_IP"
}

generate_nginx_config() {
    echo -e "${CYAN}[*] Membuat konfigurasi Nginx lokal...${RESET}"
    mkdir -p "$ANIMETERMUX_DIR/backend/logs"
    mkdir -p "$ANIMETERMUX_DIR/backend/nginx_tmp"
    
    cat << EOF > "$ANIMETERMUX_DIR/backend/nginx.conf"
$NGINX_USER_DIRECTIVE
daemon off;
pid $ANIMETERMUX_DIR/backend/nginx.pid;
error_log $ANIMETERMUX_DIR/backend/logs/nginx_error.log;

events {
    worker_connections 1024;
}

http {
    default_type application/octet-stream;
    access_log off;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    gzip_comp_level 5;

    types {
        text/html                             html htm shtml;
        text/css                              css;
        application/javascript                js;
        image/gif                             gif;
        image/jpeg                            jpeg jpg;
        image/png                             png;
        image/svg+xml                         svg svgz;
        image/webp                            webp;
        application/json                      json;
    }

    client_body_temp_path $ANIMETERMUX_DIR/backend/nginx_tmp/client_body;
    proxy_temp_path $ANIMETERMUX_DIR/backend/nginx_tmp/proxy;
    fastcgi_temp_path $ANIMETERMUX_DIR/backend/nginx_tmp/fastcgi;
    uwsgi_temp_path $ANIMETERMUX_DIR/backend/nginx_tmp/uwsgi;
    scgi_temp_path $ANIMETERMUX_DIR/backend/nginx_tmp/scgi;

    server {
        listen $HTTP_PORT;
        server_name localhost animetermux.com;

        location / {
            proxy_pass http://127.0.0.1:5000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF
}

LOCAL_IP=$(get_local_ip)

if [ "$pilihan" == "2" ]; then
    echo -e "${CYAN}[*] Menjalankan layanan terpilih di latar belakang...${RESET}"
    activate_wake_lock
    
    # 1. Run Python startup jobs once
    echo -e "${CYAN}[*] Menjalankan startup jobs di latar belakang...${RESET}"
    nohup "$ANIMETERMUX_DIR/backend/venv/bin/python" -c "import sys; sys.path.append('backend'); import web_server; web_server.resume_pending_uploads(); web_server.upload_all_missing_covers()" > "$ANIMETERMUX_DIR/backend/logs/startup_jobs.log" 2>&1 &
    
    # 2. Run Gunicorn in background
    bind_address="127.0.0.1:5000"
    if [ "$NO_NGINX" == "true" ]; then
        bind_address="0.0.0.0:$HTTP_PORT"
    fi
    nohup "$ANIMETERMUX_DIR/backend/venv/bin/gunicorn" -w 2 --threads 12 -b "$bind_address" backend.web_server:app > backend/logs/web_server.log 2>&1 &
    
    # 3. Run Nginx in background
    if [ "$NO_NGINX" != "true" ]; then
        generate_nginx_config
        nohup nginx -c "$ANIMETERMUX_DIR/backend/nginx.conf" > backend/logs/nginx.log 2>&1 &
        echo -e "${GREEN}[+] Web Streaming Anime berjalan di latar belakang (Gunicorn & Nginx port $HTTP_PORT)${RESET}"
    else
        echo -e "${GREEN}[+] Web Streaming Anime berjalan di latar belakang (Gunicorn port $HTTP_PORT - Tanpa Nginx)${RESET}"
    fi
    
    # Start Tunnels in Background
    if [ "$TUNNEL_TYPE" == "cloudflare" ]; then
        if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
            nohup $CF_COMMAND tunnel --no-autoupdate run --token $CLOUDFLARE_TUNNEL_TOKEN > backend/logs/cf_tunnel.log 2>&1 &
            echo -e "${CYAN}[*] Menjalankan Cloudflare Tunnel via Token...${RESET}"
            sleep 4
            PUBLIC_URL=${CLOUDFLARE_DOMAIN:-"Domain Kustom (Aktif Melalui Token Cloudflare)"}
            if [[ ! "$PUBLIC_URL" =~ ^http ]]; then
                PUBLIC_URL="https://$PUBLIC_URL"
            fi
        else
            nohup $CF_COMMAND tunnel --url http://localhost:$HTTP_PORT > backend/logs/cf_tunnel.log 2>&1 &
            echo -e "${CYAN}[*] Menunggu URL publik dari Cloudflare...${RESET}"
            count=0
            while [ $count -lt 20 ]; do
                PUBLIC_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' backend/logs/cf_tunnel.log | grep -v 'api\.trycloudflare\.com' | head -n 1)
                if [ -n "$PUBLIC_URL" ]; then
                    break
                fi
                sleep 1
                count=$((count+1))
            done
        fi
    elif [ "$TUNNEL_TYPE" == "ngrok" ]; then
        NG_ARGS="http $HTTP_PORT --log=stdout"
        if [ -n "$NGROK_DOMAIN" ]; then
            NG_ARGS="http $HTTP_PORT --domain=$NGROK_DOMAIN --log=stdout"
        fi
        nohup $NG_COMMAND $NG_ARGS > backend/logs/ngrok.log 2>&1 &
        echo -e "${CYAN}[*] Menunggu URL publik dari Ngrok...${RESET}"
        sleep 6
        PUBLIC_URL=$(grep -oE 'url="?https://[a-zA-Z0-9.-]*' backend/logs/ngrok.log | head -n 1 | sed 's/url="*//')
    fi
    
    echo -e "\n${GREEN}[+] Layanan berhasil dijalankan!${RESET}"
    echo -e "${CYAN}-------------------------------------------------------${RESET}"
    echo -e "${BOLD}   AKSES WEB STREAMING ANIME DI SINI:${RESET}"
    echo -e "   Lokal Termux   : http://localhost:$HTTP_PORT"
    echo -e "   Lokal Jaringan : http://$LOCAL_IP:$HTTP_PORT"
    echo -e "   Domain Kustom  : http://animetermux.com:$HTTP_PORT"
    if [ -n "$PUBLIC_URL" ]; then
        echo -e "   ONLINE TUNNEL  : ${GREEN}${BOLD}$PUBLIC_URL${RESET}"
    fi
    echo -e "${CYAN}-------------------------------------------------------${RESET}"
    echo -e "${YELLOW}[*] Untuk mematikan, ketik: pkill -f gunicorn && pkill -f nginx && pkill -f cloudflared && pkill -f ngrok${RESET}"

    if [ "$HAS_FLAGS" != "true" ]; then
        prompt_autorun_mode
        select_and_open_link
    fi
else
    echo -e "${CYAN}[*] Menjalankan layanan terpilih...${RESET}"
    activate_wake_lock
    
    # Start Tunnels
    if [ "$TUNNEL_TYPE" == "cloudflare" ]; then
        rm -f backend/logs/cf_tunnel.log
        if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
            $CF_COMMAND tunnel --no-autoupdate run --token $CLOUDFLARE_TUNNEL_TOKEN > backend/logs/cf_tunnel.log 2>&1 &
            CF_PID=$!
            echo -e "${CYAN}[*] Menjalankan Cloudflare Tunnel via Token...${RESET}"
            sleep 4
            PUBLIC_URL=${CLOUDFLARE_DOMAIN:-"Domain Kustom (Aktif Melalui Token Cloudflare)"}
            if [[ ! "$PUBLIC_URL" =~ ^http ]]; then
                PUBLIC_URL="https://$PUBLIC_URL"
            fi
        else
            $CF_COMMAND tunnel --url http://localhost:$HTTP_PORT > backend/logs/cf_tunnel.log 2>&1 &
            CF_PID=$!
            echo -e "${CYAN}[*] Menunggu URL publik dari Cloudflare...${RESET}"
            count=0
            while [ $count -lt 20 ]; do
                PUBLIC_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' backend/logs/cf_tunnel.log | grep -v 'api\.trycloudflare\.com' | head -n 1)
                if [ -n "$PUBLIC_URL" ]; then
                    break
                fi
                sleep 1
                count=$((count+1))
            done
        fi
    elif [ "$TUNNEL_TYPE" == "ngrok" ]; then
        rm -f backend/logs/ngrok.log
        NG_ARGS="http $HTTP_PORT --log=stdout"
        if [ -n "$NGROK_DOMAIN" ]; then
            NG_ARGS="http $HTTP_PORT --domain=$NGROK_DOMAIN --log=stdout"
        fi
        $NG_COMMAND $NG_ARGS > backend/logs/ngrok.log 2>&1 &
        NG_PID=$!
        echo -e "${CYAN}[*] Menunggu URL publik dari Ngrok...${RESET}"
        sleep 6
        PUBLIC_URL=$(grep -oE 'url="?https://[a-zA-Z0-9.-]*' backend/logs/ngrok.log | head -n 1 | sed 's/url="*//')
    fi
    


    # Clean termination sequence
    cleanup_and_exit() {
        # Disable trap to avoid double calls
        trap - SIGINT SIGTERM
        
        echo -e "\n\n${RED}[!] Menghentikan seluruh layanan dan keluar...${RESET}"
        
        # Stop Nginx if pid exists
        if [ -f "$ANIMETERMUX_DIR/backend/nginx.pid" ]; then
            local nginx_pid=$(cat "$ANIMETERMUX_DIR/backend/nginx.pid")
            kill $nginx_pid &>/dev/null || true
        fi
        
        kill $WEB_PID $CF_PID $NG_PID &>/dev/null
        
        [ -n "$WEB_PID" ] && wait $WEB_PID 2>/dev/null
        
        # Kill remaining components to avoid UserWarning leaked semaphores
        pkill -9 -f gunicorn &>/dev/null
        pkill -9 -f nginx &>/dev/null
        pkill -9 -f cloudflared &>/dev/null
        pkill -9 -f ngrok &>/dev/null
        
        release_wake_lock
        echo -e "${GREEN}[*] Seluruh proses berhasil dihentikan. Sampai jumpa!${RESET}"
        exit 0
    }

    # 1. Run Python startup jobs once before loop in background
    echo -e "${CYAN}[*] Menjalankan startup jobs di latar belakang...${RESET}"
    nohup "$ANIMETERMUX_DIR/backend/venv/bin/python" -c "import sys; sys.path.append('backend'); import web_server; web_server.resume_pending_uploads(); web_server.upload_all_missing_covers()" > "$ANIMETERMUX_DIR/backend/logs/startup_jobs.log" 2>&1 &

    HAS_OPENED_BROWSER=false
    while true; do
        IS_RESTARTING=false
        WEB_PID=""
        
        # 2. Run Gunicorn in background
        bind_address="127.0.0.1:5000"
        if [ "$NO_NGINX" == "true" ]; then
            bind_address="0.0.0.0:$HTTP_PORT"
        fi
        "$ANIMETERMUX_DIR/backend/venv/bin/gunicorn" -w 2 --threads 12 -b "$bind_address" backend.web_server:app > backend/logs/web_server.log 2>&1 &
        WEB_PID=$!
        
        # 3. Run Nginx in background
        if [ "$NO_NGINX" != "true" ]; then
            generate_nginx_config
            nohup nginx -c "$ANIMETERMUX_DIR/backend/nginx.conf" > backend/logs/nginx.log 2>&1 &
        fi
        
        if [ "$RUN_PRELOADER_ON_START" == "true" ]; then
            echo -e "\n${GREEN}[*] Memulai preloader di latar depan...${RESET}"
            echo -e "${YELLOW}[*] Output Bot & Web Reader dialihkan ke log agar layar bersih.${RESET}\n"
            "${PRELOADER_COMMAND[@]}"
            RUN_PRELOADER_ON_START=false
        fi
        
        # Wait for Gunicorn/Nginx to initialize
        sleep 2
        
        echo -e "\n${CYAN}-------------------------------------------------------${RESET}"
        echo -e "${BOLD}   AKSES WEB STREAMING ANIME DI SINI:${RESET}"
        echo -e "   Lokal Termux   : http://localhost:$HTTP_PORT"
        echo -e "   Lokal Jaringan : http://$LOCAL_IP:$HTTP_PORT"
        echo -e "   Domain Kustom  : http://animetermux.com:$HTTP_PORT"
        if [ -n "$PUBLIC_URL" ]; then
            echo -e "   ONLINE TUNNEL  : ${GREEN}${BOLD}$PUBLIC_URL${RESET}"
        fi
        echo -e "${CYAN}-------------------------------------------------------${RESET}"

        if [ "$HAS_OPENED_BROWSER" == "false" ] && [ "$HAS_FLAGS" != "true" ]; then
            prompt_autorun_mode
            select_and_open_link
            HAS_OPENED_BROWSER=true
        fi
        
        # Cleanup trap
        trap cleanup_and_exit SIGINT SIGTERM
        
        echo -e "\n${YELLOW}[*] Tekan Ctrl+C atau 'q' untuk menghentikan seluruh layanan. Tekan 'c' untuk cek status.${RESET}\n"
        
        # Monitor
        while [ -n "$WEB_PID" ] && kill -0 $WEB_PID &>/dev/null; do
            read -t 1 -n 1 -r key
            if [ "$key" == "r" ] || [ "$key" == "R" ]; then
                echo -e "\n\n${CYAN}[*] Memeriksa pembaruan dari GitHub (git pull)...${RESET}"
                git pull origin main
                echo -e "\n${CYAN}[*] Merestart layanan secara instan...${RESET}\n"
                IS_RESTARTING=true
                
                # Stop Nginx before restart
                if [ -f "$ANIMETERMUX_DIR/backend/nginx.pid" ]; then
                    nginx_pid=$(cat "$ANIMETERMUX_DIR/backend/nginx.pid")
                    kill $nginx_pid &>/dev/null || true
                fi
                
                kill $WEB_PID &>/dev/null
                [ -n "$WEB_PID" ] && wait $WEB_PID 2>/dev/null
                sleep 1
                break
            elif [ "$key" == "c" ] || [ "$key" == "C" ]; then
                echo -e "\n\n${YELLOW}[*] Memeriksa status proses aktif saat ini...${RESET}"
                if [ -n "$WEB_PID" ] && kill -0 $WEB_PID &>/dev/null; then
                    echo -e "   - Web Server (Gunicorn) : ${GREEN}AKTIF${RESET} (PID: $WEB_PID)"
                else
                    echo -e "   - Web Server (Gunicorn) : ${RED}MATI${RESET}"
                fi
                if [ "$NO_NGINX" != "true" ]; then
                    if [ -f "$ANIMETERMUX_DIR/backend/nginx.pid" ] && kill -0 $(cat "$ANIMETERMUX_DIR/backend/nginx.pid") &>/dev/null; then
                        echo -e "   - Reverse Proxy (Nginx) : ${GREEN}AKTIF${RESET} (PID: $(cat "$ANIMETERMUX_DIR/backend/nginx.pid"))"
                    else
                        echo -e "   - Reverse Proxy (Nginx) : ${RED}MATI${RESET}"
                    fi
                fi
                echo ""
                echo -e "${CYAN}-------------------------------------------------------${RESET}"
                echo -e "${BOLD}   AKSES WEB STREAMING ANIME DI SINI:${RESET}"
                echo -e "   Lokal Termux   : http://localhost:$HTTP_PORT"
                echo -e "   Lokal Jaringan : http://$LOCAL_IP:$HTTP_PORT"
                echo -e "   Domain Kustom  : http://animetermux.com:$HTTP_PORT"
                if [ -n "$PUBLIC_URL" ]; then
                    echo -e "   ONLINE TUNNEL  : ${GREEN}${BOLD}$PUBLIC_URL${RESET}"
                fi
                echo -e "${CYAN}-------------------------------------------------------${RESET}"
                echo ""
            elif [ "$key" == "q" ] || [ "$key" == "Q" ]; then
                cleanup_and_exit
            fi
        done
        
        if [ "$IS_RESTARTING" = false ]; then
            # Stop Nginx before exit/manual reload loop
            if [ -f "$ANIMETERMUX_DIR/backend/nginx.pid" ]; then
                nginx_pid=$(cat "$ANIMETERMUX_DIR/backend/nginx.pid")
                kill $nginx_pid &>/dev/null || true
            fi
            
            kill $WEB_PID &>/dev/null
            echo -e "\n${RED}[-] Layanan berhenti.${RESET}"
            read -t 5 -p "Tekan [r] untuk merestart atau [q] untuk keluar: " key_pilihan
            if [ -z "$key_pilihan" ] || [ "$key_pilihan" == "q" ] || [ "$key_pilihan" == "Q" ]; then
                cleanup_and_exit
            fi
            echo -e "\n${CYAN}[*] Memeriksa pembaruan dari GitHub (git pull)...${RESET}"
            git pull origin main
            echo -e "\n${CYAN}[*] Memulai ulang layanan...${RESET}\n"
        fi
    done
fi
