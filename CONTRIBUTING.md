# Panduan Kontribusi

Terima kasih atas ketertarikan Anda untuk berkontribusi di AnimeTermux! Kami sangat menyambut kontribusi dari siapa saja untuk membantu membuat proyek ini menjadi lebih baik.

## Pull Request (PR)

Sebelum mengirimkan Pull Request, pastikan Anda mengikuti panduan berikut:

* **Pemeriksaan Sintaks & Linting:**
  * Untuk perubahan skrip shell, jalankan `bash -n run.sh` untuk memastikan tidak ada kesalahan sintaks.
  * Untuk perubahan Python, pastikan kode dapat berjalan tanpa error sintaks.
* **Kompatibilitas Lintas Platform:**
  * AnimeTermux dirancang untuk berjalan di Android (Termux), Linux, macOS, dan Windows. Jika Anda mengubah skrip utama, pastikan skrip `run.sh` dan `run.bat` disesuaikan dan diuji pada platform terkait.
* **Dokumentasi:**
  * Sesuaikan isi file `README.md` dengan perubahan yang Anda buat (jika diperlukan).
  * Pastikan dokumentasi tetap bersih, jelas, dan mutakhir.
* **Dependensi Minimal:**
  * Jangan menambahkan dependensi baru kecuali jika sangat diperlukan. Kami berkomitmen menjaga aplikasi ini seringan mungkin.
* **Referensi Issue:**
  * Jika Pull Request Anda memperbaiki bug atau menyelesaikan masalah tertentu, cantumkan nomor *issue* terkait di kolom deskripsi.

## Laporan Masalah (Issues)

Saat membuat laporan masalah (issue) baru, harap perhatikan hal-hal berikut:

* **Cari Terlebih Dahulu:** Pastikan masalah atau fitur yang ingin Anda ajukan belum pernah dilaporkan atau ditolak sebelumnya.
* **Detail Sistem:** Cantumkan sistem operasi yang Anda gunakan (Termux di Android, Windows, macOS, Linux) beserta versinya.
* **Log dan Screenshot:** Sertakan log error, stack trace, atau tangkapan layar jika ada. File log sistem dapat Anda temukan di folder `backend/logs/`.
* **Deskripsi Jelas:** Jelaskan langkah-demi-langkah cara mereproduksi masalah tersebut agar mudah dipahami.

## Bagaimana lagi cara saya membantu?

* **Berikan Star:** Dukung proyek ini dengan memberikan bintang (star) pada repositori GitHub kami! 
* **Uji Coba (Testing):** Ikut serta dalam menguji fitur baru, menemukan bug, dan membantu memecahkan masalah pengguna lain.
* **Bagikan:** Sebarkan informasi tentang proyek ini kepada orang lain yang mungkin membutuhkannya.
