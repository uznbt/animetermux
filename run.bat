@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
cd /d "%~dp0"
cls

:: =====================================================
::   TELEGRAM BOT & ANIME WEB SERVER LAUNCHER (WIN)
:: =====================================================

:: PARSING ARGUMEN COMMAND LINE
if "%~1"=="--uninstall" goto uninstall_mode

:: CEK PEMBARUAN GIT DI AWAL (KECUALI UNTUK UNINSTALL)
call :check_git_updates

if "%~1"=="--settings" goto settings_mode

set "IS_PRELOADER=0"
set "ARG1=%~1"
if defined ARG1 (
    if "!ARG1:~0,2!"=="--" (
        set IS_PRELOADER=1
    )
)

set "ANIMETERMUX_DIR=%CD%"
set "HTTP_PORT=8080"
set "NGINX_USER_DIRECTIVE="
net session >nul 2>&1
if not errorlevel 1 (
    set "HTTP_PORT=80"
)

echo ========================================================
echo       TELEGRAM BOT ^& ANIME WEB SERVER LAUNCHER
echo ========================================================
echo.

:: =====================================================
:: 1. CEK & INSTALL DEPENDENSI OTOMATIS
:: =====================================================
echo [*] Memeriksa dependensi sistem...

:: Fungsi install via winget
set USE_WINGET=0
winget --version >nul 2>&1
if not errorlevel 1 set USE_WINGET=1

:: ---- CEK PYTHON ----
python --version >nul 2>&1
if errorlevel 1 (
    if !USE_WINGET!==1 (
        winget list --id Python.Python.3.12 >nul 2>&1
        if not errorlevel 1 (
            echo [*] Python terdeteksi sudah terinstal di sistem, menyegarkan PATH...
            call :refresh_path
        )
    )
    python --version >nul 2>&1
)
if errorlevel 1 (
    echo [!] Python tidak ditemukan. Menginstal otomatis...
    if !USE_WINGET!==1 (
        echo [*] Menginstal Python via winget...
        winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        if not errorlevel 1 call :record_package Python.Python.3.12
    ) else (
        echo [*] winget tidak tersedia. Mengunduh Python installer...
        powershell -Command "Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe' -OutFile 'python_installer.exe'"
        echo [*] Menjalankan installer Python ^(ikuti wizard dan centang 'Add to PATH'^)...
        start /wait python_installer.exe /quiet InstallAllUsers=1 PrependPath=1
        del python_installer.exe 2>nul
    )
    rem Refresh PATH
    call :refresh_path
    python --version >nul 2>&1
    if errorlevel 1 (
        echo [-] Instalasi Python gagal atau PATH belum diperbarui.
        echo [-] Silakan restart CMD dan jalankan run.bat lagi.
        pause
        exit /b 1
    )
    echo [+] Python berhasil diinstal!
)

:: ---- CEK NGINX ----
if not exist "backend\nginx\nginx.exe" (
    echo [!] Nginx tidak ditemukan. Mengunduh Nginx portabel untuk Windows...
    if not exist "backend" mkdir backend
    powershell -Command "Invoke-WebRequest -Uri 'https://nginx.org/download/nginx-1.26.1.zip' -OutFile 'nginx.zip'; Expand-Archive -Path 'nginx.zip' -DestinationPath 'backend'; Rename-Item -Path 'backend\nginx-1.26.1' -NewName 'nginx'; Remove-Item 'nginx.zip'"
    if not exist "backend\nginx\nginx.exe" (
        echo [-] Gagal mengunduh/mengekstrak Nginx. Silakan install Nginx secara manual.
        pause
        exit /b 1
    )
    echo [+] Nginx berhasil diinstal secara portabel!
)

:: ---- CEK NODE.JS / NPM ----
if not exist "frontend\dist\index.html" (
    echo [-] Folder kompilasi frontend ^(frontend\dist\index.html^) tidak ditemukan!
    echo [-] Pastikan folder dist telah diunggah secara utuh.
    pause
    exit /b 1
)

:: ---- CEK GIT ----
git --version >nul 2>&1
if errorlevel 1 (
    if !USE_WINGET!==1 (
        winget list --id Git.Git >nul 2>&1
        if not errorlevel 1 (
            echo [*] Git terdeteksi sudah terinstal di sistem, menyegarkan PATH...
            call :refresh_path
        )
    )
    git --version >nul 2>&1
)
if errorlevel 1 (
    echo [!] Git tidak ditemukan. Menginstal otomatis...
    if !USE_WINGET!==1 (
        winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
        if not errorlevel 1 call :record_package Git.Git
    ) else (
        echo [*] Mengunduh Git installer...
        powershell -Command "Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe' -OutFile 'git_installer.exe'"
        start /wait git_installer.exe /VERYSILENT /NORESTART
        del git_installer.exe 2>nul
    )
    rem Refresh PATH
    call :refresh_path
    git --version >nul 2>&1
    if errorlevel 1 (
        echo [-] Instalasi Git gagal. Silakan restart CMD dan jalankan lagi.
        pause
        exit /b 1
    )
    echo [+] Git berhasil diinstal!
)

:: ---- VIRTUAL ENVIRONMENT & PYTHON DEPENDENCIES ----
if not exist "backend\venv" (
    echo [*] Membuat virtual environment Python...
    python -m venv backend\venv
)

set VENV_PYTHON=backend\venv\Scripts\python.exe
set VENV_PIP=backend\venv\Scripts\pip.exe

:: Python dependencies will be installed after Telegram setup


:: =====================================================
:: PRELOADER MODE EXECUTION
:: =====================================================
if "!IS_PRELOADER!"=="1" (
    echo.
    echo ========================================================
    echo         MENJALANKAN MODE PRELOADER CACHE ^(WINDOWS^)
    echo ========================================================
    echo.
    
    if "!AUTO_RUN!"=="true" (
        set PILIHAN_MODE=2
        echo [*] Auto-Run Aktif: Memilih mode Web + Pra-Unduh simultan.
    ) else (
        echo Pilih mode eksekusi:
        echo   1^) Download Langsung ^(Hanya jalankan Bot ^& Cache^)
        echo   2^) Jalankan Web dan Download Langsung ^(Bisa Sambil Baca^)
        echo -------------------------------------------------------
        set /p PILIHAN_MODE="Masukkan pilihan Anda [1 atau 2, default: 2]: "
        if "!PILIHAN_MODE!"=="" set PILIHAN_MODE=2
    )

    if "!PILIHAN_MODE!"=="1" (
        echo.
        echo [*] Memulai pra-unduh langsung...
        !VENV_PYTHON! backend\preloader.py %*
        echo.
        echo [+] Preloader selesai.
        pause
        exit /b 0
    ) else (
        echo.
        echo [*] Mengaktifkan Web Server + Pra-Unduh simultan...
        set RUN_PRELOADER_ON_START=1
    )
)

:: =====================================================
:: 2. KONFIGURASI PENYIMPANAN GAMBAR & TOKEN
:: =====================================================
:: Load .env first
if exist ".env" (
    for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
        set %%A=%%B
    )
)

if "!SKIP_TELEGRAM!"=="true" (
    echo [*] Mode Hotlink Gambar ^(Tanpa CDN Telegram^) Aktif.
) else (
    if "!BOT_TOKEN!"=="" (
        if "!AUTO_RUN!"=="true" (
            echo [*] Auto-Run Aktif: Token Bot kosong, otomatis mengaktifkan Mode Hotlink Gambar.
            echo SKIP_TELEGRAM=true>> .env
            set SKIP_TELEGRAM=true
        ) else (
            echo.
            echo ========================================================
            echo            KONFIGURASI PENYIMPANAN GAMBAR
            echo ========================================================
            echo Aplikasi membutuhkan cara untuk memuat gambar thumbnail.
            echo 1^) Hotlink Langsung dari Web Asli ^(Lebih lambat ^& berisiko gambar mati^)
            echo 2^) Gunakan Bot Telegram sebagai CDN ^(Gratis, Sangat Cepat ^& Anti-Banned^)
            echo.
            set /p img_method="Pilih metode (1 atau 2, default: 1): "
            
            if "!img_method!"=="1" (
                echo [*] Mode Hotlink diaktifkan. Anda bisa mengaturnya nanti via --settings.
                echo SKIP_TELEGRAM=true>> .env
                set SKIP_TELEGRAM=true
            ) else (
                echo.
                echo [!] Token Bot Telegram tidak ditemukan. Mari konfigurasi bot Anda.
                set /p BOT_TOKEN="Masukkan Token Bot Telegram Anda: "
                if "!BOT_TOKEN!"=="" (
                    echo [-] Token tidak boleh kosong! Dibatalkan.
                    pause
                    exit /b 1
                )
                echo BOT_TOKEN=!BOT_TOKEN!>> .env
                echo [+] Token berhasil disimpan ke .env!
            )
        )
    )
    
    if not "!SKIP_TELEGRAM!"=="true" (
        if not exist ".chat_ids" (
            if "!AUTO_RUN!"=="true" (
                echo [*] Auto-Run Aktif: Mengisi Chat ID bawaan [0].
                echo 0> .chat_ids
                if not exist "backend" mkdir backend
                echo 0> backend\.chat_ids
            ) else (
                echo.
                echo [!] File .chat_ids tidak ditemukan. Mari konfigurasikan Chat ID penerima.
                set /p CHAT_IDS_INPUT="Masukkan Chat ID / ID Grup Anda: "
                if "!CHAT_IDS_INPUT!"=="" (
                    echo [-] Chat ID tidak boleh kosong! Dibatalkan.
                    pause
                    exit /b 1
                )
                echo !CHAT_IDS_INPUT!> .chat_ids
                if not exist "backend" mkdir backend
                echo !CHAT_IDS_INPUT!> backend\.chat_ids
                echo [+] Chat ID berhasil disimpan ke file .chat_ids!
            )
        )
    )
)

:: =====================================================
:: Install Python Dependencies Based on Mode
:: =====================================================
if "!SKIP_TELEGRAM!"=="true" (
    echo [*] Checking required Python dependencies...
    !VENV_PYTHON! -c "import flask, flask_cors, requests, bs4" >nul 2>&1
    if errorlevel 1 (
        echo [*] Installing required Python dependencies...
        !VENV_PIP! install flask flask-cors requests beautifulsoup4
        if errorlevel 1 (
            echo [-] Gagal menginstal dependensi Python!
            pause
            exit /b 1
        )
        echo [+] Dependensi Python berhasil diinstal!
    )
) else (
    echo [*] Checking required Python dependencies...
    !VENV_PYTHON! -c "import flask, flask_cors, requests, bs4, telegram" >nul 2>&1
    if errorlevel 1 (
        echo [*] Installing required Python dependencies...
        !VENV_PIP! install flask flask-cors requests beautifulsoup4 python-telegram-bot
        if errorlevel 1 (
            echo [-] Gagal menginstal dependensi Python!
            pause
            exit /b 1
        )
        echo [+] Dependensi Python berhasil diinstal!
    )
)

:: =====================================================
:: 2b. KONFIGURASI MODE BERJALAN (FOREGROUND / BACKGROUND)
:: =====================================================
set DEF_MODE=1
if defined DEFAULT_MODE set DEF_MODE=!DEFAULT_MODE!

if "!DEF_MODE!"=="2" (
    set "PROMPT_MODE=2 (Background)"
) else (
    set "PROMPT_MODE=1 (Foreground)"
)

if "!AUTO_RUN!"=="true" (
    set pilihan_mode_berjalan=!DEF_MODE!
    echo [*] Auto-Run Aktif: Memilih Mode Berjalan !PROMPT_MODE! secara otomatis.
) else (
    echo.
    echo ========================================================
    echo             MODE MENJALANKAN LAYANAN (RUN CONFIG)
    echo ========================================================
    echo Pilih mode untuk menjalankan sistem:
    echo 1^) Foreground ^(Berjalan di terminal aktif dengan menu bantuan^)
    echo 2^) Background ^(Berjalan di latar belakang, menutup terminal ini^)
    echo.
    set /p pilihan_mode_berjalan="Masukkan pilihan Anda (1 atau 2, Enter untuk !DEF_MODE!): "
    if "!pilihan_mode_berjalan!"=="" set pilihan_mode_berjalan=!DEF_MODE!
    
    findstr /v "DEFAULT_MODE" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo DEFAULT_MODE=!pilihan_mode_berjalan!>> .env
)

set "START_TYPE=/b"
if "!pilihan_mode_berjalan!"=="2" set "START_TYPE=/min"

:: =====================================================
:: 3. KONFIGURASI TUNNEL
:: =====================================================
set TUNNEL_TYPE=none
set PUBLIC_URL=
set CF_PID=
set NG_PID=

set DEF_TUNNEL=1
if defined DEFAULT_TUNNEL set DEF_TUNNEL=!DEFAULT_TUNNEL!

if "!AUTO_RUN!"=="true" (
    set tunnel_pilihan=!DEF_TUNNEL!
    echo [*] Auto-Run Aktif: Memilih Tunnel !DEF_TUNNEL! secara otomatis.
) else (
    echo.
    echo ========================================================
    echo    AKSES BEDA JARINGAN [ONLINE / TUNNELING] CONFIG
    echo ========================================================
    echo Apakah Anda ingin membuat web ini online?
    echo 1^) Tidak ^(Hanya lokal wifi/LAN^)
    echo 2^) Gunakan Cloudflare Tunnel ^(Gratis, Tanpa Daftar!^)
    echo 3^) Gunakan Ngrok ^(Butuh Authtoken dari ngrok.com^)
    echo.
    set /p tunnel_pilihan="Masukkan pilihan Anda (1, 2, atau 3, Enter untuk !DEF_TUNNEL!): "
    if "!tunnel_pilihan!"=="" set tunnel_pilihan=!DEF_TUNNEL!
    
    rem Simpan pilihan tunnel ke .env
    findstr /v "DEFAULT_TUNNEL" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo DEFAULT_TUNNEL=!tunnel_pilihan!>> .env
)

    if not "!tunnel_pilihan!"=="2" goto skip_cf
    set TUNNEL_TYPE=cloudflare
    echo [*] Mempersiapkan Cloudflare Tunnel...
    where cloudflared >nul 2>&1
    if errorlevel 1 (
        if exist "cloudflared.exe" (
            set CF_COMMAND=cloudflared.exe
        ) else (
            echo [*] Mengunduh Cloudflare Tunnel untuk Windows...
            powershell -Command "Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile 'cloudflared.exe'"
            set CF_COMMAND=cloudflared.exe
        )
    ) else (
        set CF_COMMAND=cloudflared
    )

    echo [*] Memulai Cloudflare Tunnel...
    if not exist "backend\logs" mkdir "backend\logs"
    if not "!CLOUDFLARE_TUNNEL_TOKEN!"=="" (
        start !START_TYPE! "" !CF_COMMAND! tunnel --no-autoupdate run --token !CLOUDFLARE_TUNNEL_TOKEN! > backend\logs\cf_tunnel.log 2>&1
        echo [*] Menjalankan Cloudflare Tunnel via Token...
        timeout /t 4 /nobreak >nul
        set "PUBLIC_URL=!CLOUDFLARE_DOMAIN!"
        if "!PUBLIC_URL!"=="" (
            set "PUBLIC_URL=Domain Kustom [Aktif Melalui Token Cloudflare]"
        ) else (
            echo !PUBLIC_URL! | findstr /i "^http" >nul 2>&1
            if errorlevel 1 set "PUBLIC_URL=https://!PUBLIC_URL!"
        )
    ) else (
        start !START_TYPE! "" !CF_COMMAND! tunnel --url http://localhost:!HTTP_PORT! > backend\logs\cf_tunnel.log 2>&1
        echo [*] Menunggu URL publik dari Cloudflare...
        set CF_ATTEMPTS=0
:wait_cf
        timeout /t 2 /nobreak >nul
        set /a CF_ATTEMPTS+=1
        for /f "tokens=*" %%L in ('findstr /i "trycloudflare.com" backend\logs\cf_tunnel.log 2^>nul') do set CF_LINE=%%L
        if defined CF_LINE for /f "tokens=2 delims= " %%U in ("!CF_LINE!") do set PUBLIC_URL=%%U
        if not defined PUBLIC_URL if !CF_ATTEMPTS! lss 15 goto wait_cf
    )
:skip_cf

    if not "!tunnel_pilihan!"=="3" goto skip_ngrok
    set TUNNEL_TYPE=ngrok
    echo [*] Mempersiapkan Ngrok...
    where ngrok >nul 2>&1
    if errorlevel 1 (
        if not exist "ngrok.exe" (
            echo [-] ngrok.exe tidak ditemukan! Silakan download dari ngrok.com.
            pause
            exit /b 1
        )
        set NG_COMMAND=ngrok.exe
    ) else (
        set NG_COMMAND=ngrok
    )

    if not defined NGROK_AUTHTOKEN (
        set /p ngrok_token="Masukkan Ngrok Authtoken Anda: "
        !NG_COMMAND! config add-authtoken !ngrok_token! >nul 2>&1
        echo NGROK_AUTHTOKEN=!ngrok_token!>> .env
    ) else (
        !NG_COMMAND! config add-authtoken !NGROK_AUTHTOKEN! >nul 2>&1
    )

    echo [*] Memulai Ngrok...
    if not exist "backend\logs" mkdir "backend\logs"
    if not "!NGROK_DOMAIN!"=="" (
        start !START_TYPE! "" !NG_COMMAND! http !HTTP_PORT! --domain=!NGROK_DOMAIN! --log=stdout > backend\logs\ngrok.log 2>&1
        set "PUBLIC_URL=!NGROK_DOMAIN!"
        echo !PUBLIC_URL! | findstr /i "^http" >nul 2>&1
        if errorlevel 1 set "PUBLIC_URL=https://!PUBLIC_URL!"
    ) else (
        start !START_TYPE! "" !NG_COMMAND! http !HTTP_PORT! --log=stdout > backend\logs\ngrok.log 2>&1
        echo [*] Menunggu URL publik dari Ngrok...
        set NG_ATTEMPTS=0
:wait_ngrok
        timeout /t 2 /nobreak >nul
        set /a NG_ATTEMPTS+=1
        for /f "tokens=*" %%L in ('findstr /i "ngrok-free.app\|ngrok.io\|ngrok.dev" backend\logs\ngrok.log 2^>nul') do set NG_LINE=%%L
        if defined NG_LINE for /f "tokens=2 delims= " %%U in ("!NG_LINE!") do set PUBLIC_URL=%%U
        if not defined PUBLIC_URL (
            python -c "import urllib.request,json; d=json.loads(urllib.request.urlopen('http://127.0.0.1:4040/api/tunnels').read()); print(d['tunnels'][0]['public_url'])" 2>nul > ngrok_url.tmp
            set /p PUBLIC_URL=<ngrok_url.tmp
            del ngrok_url.tmp 2>nul
        )
        if not defined PUBLIC_URL if !NG_ATTEMPTS! lss 15 goto wait_ngrok
    )
:skip_ngrok

:: =====================================================
:: 4. DETEKSI IP LOKAL
:: =====================================================
for /f "tokens=2 delims=:" %%I in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "127.0.0.1"') do set LOCAL_IP_RAW=%%I
for /f "tokens=* delims= " %%T in ("!LOCAL_IP_RAW!") do set LOCAL_IP=%%T
if not defined LOCAL_IP set LOCAL_IP=Tidak terdeteksi

:: =====================================================
:: 5. JALANKAN LAYANAN
:: =====================================================
echo.
echo [*] Memeriksa dan mematikan proses lama...
taskkill /f /im python.exe >nul 2>&1
taskkill /f /im nginx.exe >nul 2>&1

echo [*] Menjalankan Anime Web Server...

:start_services
if not exist "backend\logs" mkdir "backend\logs"
echo [*] Menjalankan startup jobs di latar belakang...
start !START_TYPE! "StartupJobs" !VENV_PYTHON! -c "import sys; sys.path.append('backend'); import web_server; web_server.resume_pending_uploads(); web_server.upload_all_missing_covers()" > backend\logs\startup_jobs.log 2>&1

start !START_TYPE! "AnimeWeb" !VENV_PYTHON! backend\web_server.py > backend\logs\web_server.log 2>&1
echo [*] Web Server dijalankan di background (window AnimeWeb)

echo [*] Menyalakan Nginx Reverse Proxy...
call :generate_nginx_config
start !START_TYPE! "Nginx" "%CD%\backend\nginx\nginx.exe" -c "%CD%\backend\nginx.conf" > backend\logs\nginx.log 2>&1
echo [*] Nginx Reverse Proxy dijalankan di background (port !HTTP_PORT!)

:: Jalankan preloader di background jika mode 2 dipilih
if "!RUN_PRELOADER_ON_START!"=="1" (
    echo [*] Memulai pra-unduh cache di background...
    start !START_TYPE! "Preloader" !VENV_PYTHON! backend\preloader.py %* > backend\logs\preloader.log 2>&1
)

timeout /t 2 /nobreak >nul

:: =====================================================
:: 6. TAMPILKAN INFO AKSES
:: =====================================================
echo.
echo -------------------------------------------------------
echo    AKSES WEB STREAMING ANIME DI SINI:
echo    Lokal Komputer : http://localhost:!HTTP_PORT!
echo    Lokal Jaringan : http://!LOCAL_IP!:!HTTP_PORT!
if defined PUBLIC_URL (
    echo    ONLINE TUNNEL  : !PUBLIC_URL!
)
echo -------------------------------------------------------
echo.
echo [*] Bantuan: [r] Restart + git pull  [q] Keluar  [c] Cek Status
echo.

if not "!HAS_OPENED_BROWSER!"=="true" (
    call :select_and_open_link
    set HAS_OPENED_BROWSER=true
)

if "!pilihan_mode_berjalan!"=="2" (
    echo.
    echo [+] Layanan telah dijalankan di latar belakang.
    echo [+] Anda dapat menutup terminal ini sekarang.
    echo -------------------------------------------------------
    pause
    exit /b 0
)

:: =====================================================
:: 7. MONITORING LOOP
:: =====================================================
:monitor_loop
choice /c rqc /n >nul 2>&1
set KEY_PRESSED=!errorlevel!

if !KEY_PRESSED!==1 (
    rem R - Restart dengan git pull
    echo.
    echo [*] Memeriksa pembaruan dari GitHub [git pull]...
    git pull origin main
    echo.
    echo [*] Merestart layanan...
    taskkill /f /im python.exe >nul 2>&1
    taskkill /f /im nginx.exe >nul 2>&1
    timeout /t 1 /nobreak >nul
    goto start_services
)

if !KEY_PRESSED!==2 (
    rem Q - Keluar
    echo.
    echo [!] Menghentikan seluruh layanan dan keluar...
    taskkill /f /im python.exe >nul 2>&1
    taskkill /f /im nginx.exe >nul 2>&1
    if defined PUBLIC_URL (
        if "!TUNNEL_TYPE!"=="ngrok" taskkill /f /im ngrok.exe >nul 2>&1
        if "!TUNNEL_TYPE!"=="cloudflare" taskkill /f /im cloudflared.exe >nul 2>&1
    )
    echo [*] Seluruh proses berhasil dihentikan. Sampai jumpa!
    pause
    exit /b 0
)

if !KEY_PRESSED!==3 (
    rem C - Cek Status
    echo.
    echo [*] Memeriksa status proses aktif saat ini...
    
    tasklist /fi "imagename eq python.exe" 2>nul | findstr /i "python.exe" >nul
    if not errorlevel 1 (
        echo    - Web Server [Python] : AKTIF
    ) else (
        echo    - Web Server [Python] : MATI
    )
    
    tasklist /fi "imagename eq nginx.exe" 2>nul | findstr /i "nginx.exe" >nul
    if not errorlevel 1 (
        echo    - Reverse Proxy [Nginx] : AKTIF
    ) else (
        echo    - Reverse Proxy [Nginx] : MATI
    )
    
    echo.
    echo -------------------------------------------------------
    echo    AKSES WEB STREAMING ANIME DI SINI:
    echo    Lokal Komputer : http://localhost:!HTTP_PORT!
    echo    Lokal Jaringan : http://!LOCAL_IP!:!HTTP_PORT!
    if defined PUBLIC_URL (
        echo    ONLINE TUNNEL  : !PUBLIC_URL!
    )
    echo -------------------------------------------------------
    echo.
    echo [*] Bantuan: [r] Restart + git pull  [q] Keluar  [c] Cek Status
    echo.
)

goto monitor_loop

:: =====================================================
:: MODE SETTINGS INTERAKTIF (--settings)
:: =====================================================
:settings_mode
echo.
echo ========================================================
echo              PENGATURAN ^& KONFIGURASI SISTEM
echo ========================================================
echo Apa yang ingin Anda lakukan?
echo 1^) Atur ulang Mode Penyimpanan Gambar ^(CDN Telegram / Hotlink^)
echo 2^) Atur ulang Akses Online / Tunnel ^(Ngrok / Cloudflare^)
echo 3^) Atur ulang Mode Berjalan ^(Foreground / Background^)
echo 4^) Atur ulang Token Bot Telegram ^& Chat ID
echo 5^) Atur ulang Ngrok Domain
echo 6^) Konfigurasi Cloudflare Tunnel Custom Domain ^(Token ^& Domain^)
echo 7^) Reset Semua Konfigurasi ke Awal
echo 8^) Atur Pilihan Jalankan Otomatis ^(Auto-Run / Tanpa Enter^)
echo 9^) Batal / Keluar
echo.
set /p set_choice="Masukkan pilihan Anda (1-9): "

if "!set_choice!"=="1" (
    findstr /v "SKIP_TELEGRAM" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo [+] Konfigurasi Penyimpanan Gambar berhasil dihapus!
) else if "!set_choice!"=="2" (
    findstr /v "DEFAULT_TUNNEL" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo [+] Konfigurasi Tunnel berhasil dihapus!
) else if "!set_choice!"=="3" (
    findstr /v "DEFAULT_MODE" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo [+] Konfigurasi Mode Berjalan berhasil dihapus!
) else if "!set_choice!"=="4" (
    findstr /v "BOT_TOKEN" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    del .chat_ids backend\.chat_ids 2>nul
    echo [+] Token Bot Telegram ^& Chat ID berhasil diset ulang!
) else if "!set_choice!"=="5" (
    findstr /v "NGROK_DOMAIN" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    echo [+] Ngrok Domain berhasil diset ulang!
) else if "!set_choice!"=="6" (
    echo.
    echo [!] Konfigurasi Custom Domain Cloudflare Tunnel.
    set /p cf_token_input="Masukkan Cloudflare Tunnel Token Anda: "
    set /p cf_domain_input="Masukkan Custom Domain Anda (contoh: anime.saya.com): "
    if not "!cf_token_input!"=="" (
        findstr /v "CLOUDFLARE_TUNNEL_TOKEN CLOUDFLARE_DOMAIN" .env > .env.tmp 2>nul
        move /y .env.tmp .env >nul 2>&1
        echo CLOUDFLARE_TUNNEL_TOKEN=!cf_token_input!>> .env
        echo CLOUDFLARE_DOMAIN=!cf_domain_input!>> .env
        set CLOUDFLARE_TUNNEL_TOKEN=!cf_token_input!
        set CLOUDFLARE_DOMAIN=!cf_domain_input!
        echo [+] Token ^& Domain Cloudflare berhasil disimpan!
    ) else (
        echo [-] Token kosong. Batal.
    )
) else if "!set_choice!"=="7" (
    findstr /v "SKIP_TELEGRAM DEFAULT_TUNNEL DEFAULT_MODE BOT_TOKEN NGROK_AUTHTOKEN AUTO_RUN NGROK_DOMAIN CLOUDFLARE_TUNNEL_TOKEN CLOUDFLARE_DOMAIN" .env > .env.tmp 2>nul
    move /y .env.tmp .env >nul 2>&1
    del .chat_ids backend\.chat_ids 2>nul
    echo [+] Seluruh konfigurasi telah di-reset ke awal!
) else if "!set_choice!"=="8" (
    echo.
    if "!AUTO_RUN!"=="true" (
        set CURRENT_STATUS=Aktif
    ) else (
        set CURRENT_STATUS=Nonaktif
    )
    echo Mode Jalankan Otomatis [Auto-Run] saat ini: !CURRENT_STATUS!
    echo Jika diaktifkan, script akan berjalan langsung tanpa meminta input/Enter di awal.
    echo 1^) Aktifkan
    echo 2^) Nonaktifkan
    set /p ar_choice="Pilih opsi (1-2): "
    if "!ar_choice!"=="1" (
        findstr /v "AUTO_RUN" .env > .env.tmp 2>nul
        move /y .env.tmp .env >nul 2>&1
        echo AUTO_RUN=true>> .env
        echo [+] Mode Jalankan Otomatis [Auto-Run] diaktifkan!
    ) else if "!ar_choice!"=="2" (
        findstr /v "AUTO_RUN" .env > .env.tmp 2>nul
        move /y .env.tmp .env >nul 2>&1
        echo AUTO_RUN=false>> .env
        echo [+] Mode Jalankan Otomatis [Auto-Run] dinonaktifkan!
    ) else (
        echo [*] Tidak ada perubahan.
    )
) else (
    echo [*] Dibatalkan.
)
exit /b 0

:: =====================================================
:: MODE UNINSTALL (--uninstall)
:: =====================================================
:uninstall_mode
echo ========================================================
echo             MODE UNINSTALL ANIME TERMUX
echo ========================================================
echo.

echo [*] Menghentikan semua proses latar belakang yang aktif...
taskkill /f /im python.exe >nul 2>&1
taskkill /f /im nginx.exe >nul 2>&1
taskkill /f /im cloudflared.exe >nul 2>&1
taskkill /f /im ngrok.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: 1. Hapus virtual environment dan build folders
echo [*] Menghapus virtual environment Python (backend\venv)...
if exist "backend\venv" rmdir /s /q "backend\venv"

echo [*] Menghapus node_modules (frontend\node_modules)...
if exist "frontend\node_modules" rmdir /s /q "frontend\node_modules"

echo [*] Menghapus hasil build frontend (frontend\dist)...
if exist "frontend\dist" rmdir /s /q "frontend\dist"

echo [*] Menghapus file binary standalone...
if exist "cloudflared.exe" del /f /q "cloudflared.exe"
if exist "ngrok.exe" del /f /q "ngrok.exe"
if exist "backend\nginx" rmdir /s /q "backend\nginx"

echo [*] Menghapus file konfigurasi dan chat ID...
if exist ".env" del /f /q ".env"
if exist ".chat_ids" del /f /q ".chat_ids"
if exist "backend\.chat_ids" del /f /q "backend\.chat_ids"
if exist "backend\nginx.conf" del /f /q "backend\nginx.conf"
if exist "backend\nginx.pid" del /f /q "backend\nginx.pid"
if exist "backend\nginx_tmp" rmdir /s /q "backend\nginx_tmp"

:: 2. Hapus package winget yang dicatat
    set "HAS_PKGS=0"
    if exist ".installed_packages.txt" set "HAS_PKGS=1"
    if exist ".installed_packages.json" set "HAS_PKGS=1"
    if !HAS_PKGS!==0 goto skip_uninstall_pkgs

    echo [*] Membaca daftar paket yang diinstal oleh skrip...

    if exist ".installed_packages.txt" (
        for /f "usebackq tokens=*" %%P in (".installed_packages.txt") do (
            echo [*] Meng-uninstall package: %%P...
            winget uninstall -e --id %%P --accept-source-agreements
        )
        del ".installed_packages.txt" 2>nul
    )

    if exist ".installed_packages.json" (
        powershell -Command "$file='.installed_packages.json'; if (Test-Path $file) { $pkgs = Get-Content $file | ConvertFrom-Json; foreach ($pkg in $pkgs) { Write-Host \"[*] Meng-uninstall package: $pkg...\"; winget uninstall -e --id $pkg --accept-source-agreements } }"
        del ".installed_packages.json" 2>nul
    )
:skip_uninstall_pkgs

echo.
echo [+] Uninstall selesai! Seluruh folder aplikasi akan dihapus otomatis setelah Anda menekan tombol apapun.
pause
start /b "" cmd /c "timeout /t 1 /nobreak >nul & cd .. & rmdir /s /q \"%~dp0\""
exit /b 0

:: =====================================================
:: FUNGSI HELPER: CATAT INSTALASI WINGET
:: =====================================================
:record_package
set "PKG_ID=%~1"
if exist ".installed_packages.txt" (
    findstr /x /c:"!PKG_ID!" ".installed_packages.txt" >nul 2>&1
    if errorlevel 1 echo !PKG_ID!>> ".installed_packages.txt"
) else (
    echo !PKG_ID!> ".installed_packages.txt"
)
goto :eof

:: =====================================================
:: FUNGSI HELPER: SEGARKAN PATH SISTEM (REFRESH PATH)
:: =====================================================
:refresh_path
for /f "tokens=*" %%I in ('powershell -Command "[Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')"') do set "PATH=%%I"
goto :eof

:check_git_updates
if not exist ".git" goto :eof
git --version >nul 2>&1
if errorlevel 1 goto :eof

echo [*] Memeriksa pembaruan dari repositori Git...
git ls-remote origin HEAD >nul 2>&1
if errorlevel 1 (
    echo [!] Koneksi internet tidak tersedia. Melewati pengecekan pembaruan...
    goto :eof
)

git fetch origin >nul 2>&1
for /f "tokens=*" %%A in ('git rev-parse HEAD') do set LOCAL_COMMIT=%%A
for /f "tokens=*" %%B in ('git rev-parse @{u}') do set REMOTE_COMMIT=%%B
if "!LOCAL_COMMIT!"=="!REMOTE_COMMIT!" (
    echo [+] Kode Anda sudah versi terbaru.
    goto :eof
)

echo [!] Menemukan pembaruan kode baru di Git!
echo [*] Menghentikan semua layanan lama...
taskkill /f /im python.exe >nul 2>&1
taskkill /f /im nginx.exe >nul 2>&1
taskkill /f /im cloudflared.exe >nul 2>&1
taskkill /f /im ngrok.exe >nul 2>&1
echo [*] Mengunduh pembaruan [git pull]...
git pull origin main
echo [+] Pembaruan berhasil diterapkan! Memulai ulang skrip...
echo -------------------------------------------------------
timeout /t 2 >nul
start "" "%~f0" %*
exit 0

:: =====================================================
:: FUNGSI HELPER: GENERATE NGINX CONFIG
:: =====================================================
:generate_nginx_config
echo [*] Membuat konfigurasi Nginx lokal...
if not exist "backend\logs" mkdir "backend\logs"
if not exist "backend\nginx_tmp" mkdir "backend\nginx_tmp"
set "CONF_DIR=!ANIMETERMUX_DIR:\=/!"

(
if not "!NGINX_USER_DIRECTIVE!"=="" echo !NGINX_USER_DIRECTIVE!
echo daemon off;
echo pid !CONF_DIR!/backend/nginx.pid;
echo error_log !CONF_DIR!/backend/logs/nginx_error.log;
echo.
echo events {
echo     worker_connections 1024;
echo }
echo.
echo http {
echo     default_type application/octet-stream;
echo     access_log off;
echo.
echo     gzip on;
echo     gzip_vary on;
echo     gzip_min_length 1024;
echo     gzip_proxied expired no-cache no-store private auth;
echo     gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
echo     gzip_comp_level 5;
echo.
echo     types {
echo         text/html                             html htm shtml;
echo         text/css                              css;
echo         application/javascript                js;
echo         image/gif                             gif;
echo         image/jpeg                            jpeg jpg;
echo         image/png                             png;
echo         image/svg+xml                         svg svgz;
echo         image/webp                            webp;
echo         application/json                      json;
echo     }
echo.
echo     client_body_temp_path !CONF_DIR!/backend/nginx_tmp/client_body;
echo     proxy_temp_path !CONF_DIR!/backend/nginx_tmp/proxy;
echo     fastcgi_temp_path !CONF_DIR!/backend/nginx_tmp/fastcgi;
echo     uwsgi_temp_path !CONF_DIR!/backend/nginx_tmp/uwsgi;
echo     scgi_temp_path !CONF_DIR!/backend/nginx_tmp/scgi;
echo.
echo     server {
echo         listen !HTTP_PORT!;
echo         server_name localhost animetermux.com;
echo.
echo         location / {
echo             proxy_pass http://127.0.0.1:5000;
echo             proxy_set_header Host $host;
echo             proxy_set_header X-Real-IP $remote_addr;
echo             proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
echo             proxy_set_header X-Forwarded-Proto $scheme;
echo         }
echo     }
echo }
) > "%CD%\backend\nginx.conf"
goto :eof

:: =====================================================
:: FUNGSI HELPER: SELECT AND OPEN LINK IN BROWSER
:: =====================================================
:select_and_open_link
echo.
echo Pilih URL untuk dibuka di browser:
echo   1^) Lokal Komputer ^(http://localhost:!HTTP_PORT!^)
echo   2^) Lokal Jaringan ^(http://!LOCAL_IP!:!HTTP_PORT!^)
if defined PUBLIC_URL (
    echo   3^) Online Tunnel ^(!PUBLIC_URL!^)
)
echo   x^) Jangan buka browser / Batal
echo.
set /p link_choice="Masukkan pilihan Anda (1, 2, 3, atau x, default: 1): "
if "!link_choice!"=="" set link_choice=1

if "!link_choice!"=="1" (
    echo [*] Membuka: http://localhost:!HTTP_PORT!
    start http://localhost:!HTTP_PORT!
) else if "!link_choice!"=="2" (
    echo [*] Membuka: http://!LOCAL_IP!:!HTTP_PORT!
    start http://!LOCAL_IP!:!HTTP_PORT!
) else if "!link_choice!"=="3" (
    if defined PUBLIC_URL (
        echo [*] Membuka: !PUBLIC_URL!
        start !PUBLIC_URL!
    ) else (
        echo [-] Online Tunnel tidak aktif.
    )
) else (
    echo [*] Batal membuka browser.
)
goto :eof
