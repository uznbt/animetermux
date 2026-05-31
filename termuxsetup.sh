#!/bin/bash

echo "[*] Memulai setup Termux..."

# 1. Update package dan install dependensi dasar
pkg update -y
pkg install -y fish git which termux-services gh curl python

# 2. Install thefuck via pip (dibutuhkan agar plugin-thefuck bisa jalan)
pip install thefuck

# 3. Ganti default shell ke fish
chsh -s fish

# 4. Install Oh My Fish (OMF)
# Menggunakan pipe | (bukan ||) agar output curl langsung dijalankan oleh fish
echo "[*] Menginstall Oh My Fish..."
curl -L https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install | fish

# 5. Install Fisher & Pluginnya
# Catatan: Perintah harus dibungkus dengan fish -c karena script ini berjalan di bash
# Link git.io/fisher sudah mati/ditutup oleh github, kita gunakan link raw github langsung
echo "[*] Menginstall Fisher & Plugin..."
fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"
fish -c "fisher install jethrokuan/z"
fish -c "fisher install edc/bass"
fish -c "fisher install oh-my-fish/plugin-thefuck"

# 6. Install tema bobthefish (penulisan omfinstall salah, yang benar omf install)
echo "[*] Menginstall tema bobthefish..."
fish -c "omf install bobthefish"

# 7. Login Github
echo "[*] Silakan login ke akun GitHub Anda:"
gh auth login

echo "[+] Setup selesai! Restart Termux atau ketik 'fish' untuk masuk ke shell baru."
