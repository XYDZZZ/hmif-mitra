# Setup — Mitra DIGIPRINT

## 1. Jalankan migrasi
Di Supabase Dashboard project Anda (yang sudah punya `0001`–`0011`) → **SQL Editor** →
jalankan **berurutan**:
1. `0012_mitra_digiprint.sql`
2. `0013_digiprint_pembatalan_dan_approval.sql` (menambah fitur batalkan transaksi & alur approval mitra)

## 2. Aktifkan login Email
**Authentication → Providers → Email** → pastikan aktif.
Jika project Anda mewajibkan konfirmasi email, mitra harus klik link di email
sebelum bisa masuk (form Daftar di `index.html` sudah menangani kedua kasus).

## 3. Isi `config.js` (BUKAN app.js)
Buka `config.js` — file ini **terpisah dari `app.js` dan tidak akan pernah
saya timpa lagi** di update-update berikutnya. Ganti dua baris ini dengan
nilai dari **Project Settings → API** di Supabase Dashboard:
```js
const SUPABASE_URL = "https://xxxxx.supabase.co";
const SUPABASE_ANON_KEY = "...";
```
Gunakan **anon public key** (bukan `service_role`), dan pastikan seluruh
key tersalin — key asli selalu diawali `eyJ`. Kalau ke depannya saya kirim
`app.js` versi baru, cukup timpa `app.js` saja; `config.js` tidak perlu
disentuh lagi.

## 4. Tambahkan Admin HMIF pertama
Belum ada UI untuk ini (sengaja — mengikuti pola default-deny `0005_rls_lockdown.sql`).
1. Buka `index.html` di browser, klik **Daftar akun mitra**, daftar pakai email
   Bendahara/pengurus.
2. Di Supabase Dashboard → **Authentication → Users**, salin UUID akun tsb.
3. Di **SQL Editor**:
   ```sql
   insert into digiprint_admin (auth_user_id, keterangan)
   values ('<uuid-tadi>', 'Bendahara 2026');
   ```
4. Login ulang di `index.html` — akun tsb otomatis masuk sebagai Admin HMIF
   (hanya melihat tab Laporan, read-only + tombol "Tandai Lunas").

## 5. Jalankan
Buka `index.html` langsung di browser (double-click, atau `Live Server` di
VS Code). Tidak perlu `npm install` / build apa pun.

## Alur pemakaian
- **Mitra baru**: Daftar → isi form "Lengkapi profil usaha" sekali → masuk
  layar **"Menunggu persetujuan"** (belum bisa akses Kasir). Begitu Admin HMIF
  menyetujui, mitra tinggal klik "Cek status lagi" (atau login ulang) untuk
  masuk ke 3 tab: Kasir/POS, Manajemen Produk (+ sub-tab Diskon), Laporan
  Keuangan (data milik sendiri saja).
- **Admin HMIF**: melihat 2 tab — **Persetujuan Mitra** (Setujui/Tolak
  pendaftaran baru, dengan alasan opsional untuk penolakan) dan **Laporan**
  yang mencakup **semua** mitra, dengan ringkasan per-mitra, tombol verifikasi
  setoran ("Tandai Lunas"), dan bisa membatalkan transaksi siapa saja
  (termasuk yang sudah Lunas).
- **Batalkan transaksi**: mitra bisa membatalkan transaksi miliknya sendiri
  selama status setoran masih `Pending` (tombol "Batalkan" muncul di tab Kasir
  → Transaksi terakhir, dan di tab Laporan). Stok produk dikembalikan otomatis
  lewat trigger database, jadi tetap akurat meskipun dibatalkan lewat jalur
  lain (bukan cuma lewat tombol di UI ini).

## Catatan
- Akun mitra yang sempat Anda buat sebelum menjalankan `0013` otomatis
  dianggap `Disetujui` (migrasi membackfill ini) — tidak akan mendadak
  terkunci keluar.
- Transaksi berstatus `Dibatalkan` otomatis dikeluarkan dari semua angka
  ringkasan di Laporan (total kotor/bersih/porsi HMIF), tapi tetap terlihat di
  tabel rincian dengan badge merah untuk jejak audit.
