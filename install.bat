@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

echo ===================================================
echo          AnimeTermux One-Click Installer
echo ===================================================
echo.

:: Check for Git
git --version >nul 2>&1
if errorlevel 1 (
    where winget >nul 2>&1
    if not errorlevel 1 (
        winget list --id Git.Git >nul 2>&1
        if not errorlevel 1 (
            echo [*] Git terdeteksi sudah terinstal di sistem, menyegarkan PATH...
            call :refresh_path
        )
    )
    git --version >nul 2>&1
)
if errorlevel 1 (
    echo [*] Git belum terinstal. Mencoba memasang Git...
    
    rem Check if winget is available
    where winget >nul 2>&1
    if not errorlevel 1 (
        echo [*] Menginstal Git via winget...
        winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
        if not errorlevel 1 call :record_package Git.Git
    ) else (
        echo [*] Mengunduh Git installer...
        powershell -Command "Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe' -OutFile 'git_installer.exe'"
        echo [*] Menjalankan installer Git...
        start /wait git_installer.exe /VERYSILENT /NORESTART
        del git_installer.exe 2>nul
    )
    
    rem Verify installation
    call :refresh_path
    git --version >nul 2>&1
    if errorlevel 1 (
        echo [-] Gagal menginstal Git. Silakan pasang Git secara manual.
        pause
        exit /b 1
    )
    echo [+] Git berhasil diinstal!
)

:: Clone or Update Repository
if exist "run.bat" (
    echo [*] Menjalankan installer langsung di dalam folder proyek.
    git pull origin main || true
) else (
    if exist "animetermux" (
        echo [*] Folder animetermux sudah ada. Melakukan sinkronisasi...
        cd animetermux
        git pull origin main || true
    ) else (
        echo [*] Mengkloning AnimeTermux...
        git clone https://github.com/uznbt/animetermux.git animetermux
        cd animetermux
    )
    if exist "..\.installed_packages.txt" (
        move /y "..\.installed_packages.txt" . >nul 2>&1
    )
    if exist "..\.installed_packages.json" (
        move /y "..\.installed_packages.json" . >nul 2>&1
    )
)

echo [+] Sukses mengunduh AnimeTermux! Memulai launcher...
call run.bat
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
