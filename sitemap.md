# Peta Situs (Sitemap) Proyek AnimeTermux

Berikut adalah gambaran keseluruhan (peta struktur) dari seluruh file dan folder penting di dalam proyek AnimeTermux. File log sementara dan *cache* telah disembunyikan agar strukturnya lebih mudah dipahami.

```text
animetermux/
├── 📄 README.md                 # Dokumentasi utama proyek
├── 📄 CONTRIBUTING.md           # Panduan untuk berkontribusi
├── 📄 LICENSE                   # Lisensi open-source proyek
│
├── ⚙️ Scripts & Launchers (Pengaturan Server)
│   ├── 📄 run.sh                # Skrip utama untuk menjalankan aplikasi di Termux/Linux (Setup Nginx, SSL, Tunneling)
│   ├── 📄 run.bat               # Skrip launcher untuk pengguna Windows
│   └── 📄 termuxsetup.sh        # Skrip instalasi awal khusus untuk perangkat Termux
│
├── 🐍 backend/                  # Kode Sisi Server (Python & Nginx)
│   ├── 📄 web_server.py         # Skrip utama server Python (Flask/Gunicorn) & Bot Telegram
│   ├── 📄 preloader.py          # Skrip pembantu untuk memuat data awal
│   ├── 📄 nginx.conf            # Konfigurasi reverse-proxy web server Nginx
│   └── 🗄️ cache.db              # Database SQLite lokal untuk menyimpan cache anime
│
├── ⚛️ frontend/                 # Kode Sisi Klien / Antarmuka Pengguna (React.js)
│   ├── 📄 index.html            # Halaman HTML kerangka utama React
│   ├── 📄 package.json          # Daftar dependensi modul Node.js (React, Vite, dll)
│   ├── 📄 vite.config.js        # Konfigurasi bundler Vite untuk performa build
│   │
│   ├── 📁 public/               # Aset statis publik (ikon & favicon)
│   │   ├── 🖼️ favicon.svg
│   │   └── 🖼️ icons.svg
│   │
│   └── 📁 src/                  # Kode Sumber Utama React
│       ├── 📄 main.jsx          # Titik masuk utama aplikasi React (Entry point)
│       ├── 📄 App.jsx           # Komponen akar (Root) untuk routing halaman
│       ├── 📄 App.css           # Gaya desain utama aplikasi (CSS)
│       ├── 📄 index.css         # Gaya desain utilitas tambahan
│       │
│       ├── 📁 api/              
│       │   └── 📄 index.js      # Fungsi-fungsi pusat untuk mengambil data dari backend
│       │
│       ├── 📁 context/          
│       │   └── 📄 AnimeCacheContext.jsx # Pengelola state memori lokal (Mencegah reload layar)
│       │
│       └── 📁 components/       # Kumpulan Komponen UI Aplikasi (Halaman & Elemen)
│           ├── 📄 Home.jsx         # Halaman Beranda
│           ├── 📄 Detail.jsx       # Halaman Detail Info Anime
│           ├── 📄 Watch.jsx        # Halaman Menonton Video Anime
│           ├── 📄 Search.jsx       # Halaman Pencarian Anime
│           ├── 📄 Genres.jsx       # Halaman Kategori/Genre Anime
│           ├── 📄 Schedule.jsx     # Halaman Jadwal Tayang Anime
│           ├── 📄 AnimeCard.jsx    # Komponen elemen kartu poster anime
│           ├── 📄 AnimeList.jsx    # Komponen peletakan barisan kartu anime
│           ├── 📄 MobileNav.jsx    # Komponen navigasi bawah (khusus tampilan HP)
│           ├── 📄 RelatedAnime.jsx # Komponen mesin rekomendasi pintar
│           └── 📄 LazyImage.jsx    # Komponen pintar pemuat gambar (menghemat kuota)
│
└── 📁 src/                      # Aset Tangkapan Layar (Screenshots)
    ├── 🖼️ berandaHP.png
    └── 🖼️ berandaPC.png
```

### Ringkasan Arsitektur
1. **Frontend**: Dibangun menggunakan **React (Vite)** murni dengan CSS Vanila yang memprioritaskan performa tinggi dan tampilan cantik. Semua *state* antar halaman dipertahankan menggunakan sistem `Context API`.
2. **Backend**: Menggunakan **Python (Flask)** yang dibungkus oleh Gunicorn. Bertugas mengambil dan membersihkan data API, serta mendelegasikan perintah-perintah ke Bot Telegram.
3. **Infrastruktur Lokal**: Menggunakan **Nginx** sebagai jembatan *proxy* antara *frontend*, *backend*, dan dunia luar (baik via akses lokal dengan OpenSSL, maupun via *Tunneling* Cloudflare/Ngrok).
