-- ============================================================
-- MIGRATION 0013: PEMBATALAN TRANSAKSI + ALUR APPROVAL MITRA
-- Lanjutan dari 0012_mitra_digiprint.sql
-- ============================================================

-- ------------------------------------------------------------
-- BAGIAN A: PEMBATALAN TRANSAKSI (mirror pola batalkan_transaksi_danus
-- di 0004_danus_mitra.sql -- soft-cancel + kembalikan stok, bukan hard delete)
-- ------------------------------------------------------------

alter table mitra_transaksi
  add column status_transaksi   varchar(20) not null default 'Selesai'
    constraint chk_status_transaksi check (status_transaksi in ('Selesai', 'Dibatalkan')),
  add column dibatalkan_oleh    uuid references auth.users(id),
  add column dibatalkan_pada    timestamptz,
  add column alasan_pembatalan  text;

-- Transaksi yang sudah Dibatalkan tidak boleh dihitung sebagai piutang
-- setoran ke HMIF -- frontend (app.js) mengecualikannya dari ringkasan.

-- Hard-delete langsung ke tabel tidak lagi diizinkan untuk mitra (stok
-- tidak akan ter-restore kalau lewat delete mentah) -- ganti dengan
-- fungsi batalkan_transaksi_digiprint() di bawah.
drop policy if exists "mitra_hapus_transaksi_pending" on mitra_transaksi;

-- Detail transaksi juga tidak lagi bisa diedit/dihapus langsung oleh
-- mitra (supaya subtotal & stok tidak pernah desync dari total header) --
-- hanya INSERT yang tersisa, dipakai internal oleh catat_transaksi_digiprint().
drop policy if exists "mitra_kelola_detail_pending" on mitra_transaksi_detail;

create policy "mitra_insert_detail_sendiri"
  on mitra_transaksi_detail for insert
  with check (
    exists (
      select 1 from mitra_transaksi t
      where t.id_transaksi = mitra_transaksi_detail.id_transaksi
        and t.id_mitra_digiprint in (
          select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
        )
    )
  );

-- ============================================================
-- TRIGGER: kembalikan stok otomatis saat status_transaksi berubah
-- jadi 'Dibatalkan'. Sengaja jadi trigger (bukan hanya logika di
-- dalam function RPC) supaya restore stok tetap terjadi APAPUN jalur
-- update-nya, bukan cuma kalau orang lewat RPC yang "benar".
-- ============================================================
create or replace function trg_kembalikan_stok_setelah_batal()
returns trigger
language plpgsql
as $$
declare
  v_detail record;
begin
  if NEW.status_transaksi = 'Dibatalkan' and OLD.status_transaksi is distinct from 'Dibatalkan' then
    for v_detail in
      select id_produk, kuantitas from mitra_transaksi_detail where id_transaksi = NEW.id_transaksi
    loop
      update mitra_produk
        set stok = stok + v_detail.kuantitas
        where id_produk = v_detail.id_produk and stok is not null;
    end loop;
  end if;
  return NEW;
end;
$$;

create trigger trg_after_batal_kembalikan_stok
  after update of status_transaksi on mitra_transaksi
  for each row execute function trg_kembalikan_stok_setelah_batal();

-- ============================================================
-- FUNCTION: batalkan_transaksi_digiprint
-- Satu-satunya jalur resmi pembatalan. Otorisasi 100% didelegasikan
-- ke RLS yang sudah ada (security invoker, tanpa logika izin
-- duplikat) -- kalau UPDATE tidak match baris manapun (bukan milik
-- sendiri, sudah Dibatalkan, atau statusnya Lunas & bukan admin),
-- FOUND bernilai false dan kita lempar pesan yang jelas.
-- ============================================================
create or replace function batalkan_transaksi_digiprint(
  p_id_transaksi uuid,
  p_alasan text default null
)
returns void
language plpgsql
security invoker
as $$
begin
  update mitra_transaksi
    set status_transaksi = 'Dibatalkan',
        dibatalkan_oleh = auth.uid(),
        dibatalkan_pada = now(),
        alasan_pembatalan = p_alasan
    where id_transaksi = p_id_transaksi
      and status_transaksi <> 'Dibatalkan';

  if not found then
    raise exception 'Transaksi tidak ditemukan, sudah dibatalkan sebelumnya, atau Anda tidak berhak membatalkannya (transaksi yang sudah Lunas hanya bisa dibatalkan oleh Admin HMIF)';
  end if;
end;
$$;

comment on function batalkan_transaksi_digiprint(uuid, text) is 'Membatalkan transaksi (soft-cancel) & memicu trigger pengembalian stok. Mitra hanya bisa membatalkan transaksi sendiri yang masih Pending; Admin HMIF bisa membatalkan transaksi siapa saja termasuk yang sudah Lunas.';

grant execute on function batalkan_transaksi_digiprint(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- BAGIAN B: ALUR APPROVAL MITRA BARU
-- (mirror pola status_pendaftaran Menunggu/Disetujui/Ditolak di
-- tabel mitra pada 0004_danus_mitra.sql)
-- ------------------------------------------------------------

alter table mitra_digiprint
  add column status_pendaftaran  varchar(20) not null default 'Menunggu'
    constraint chk_status_pendaftaran check (status_pendaftaran in ('Menunggu', 'Disetujui', 'Ditolak')),
  add column diproses_oleh       uuid references auth.users(id),
  add column diproses_pada       timestamptz,
  add column catatan_penolakan   text;

-- Mitra hasil dari 0012 (dibuat sebelum kolom ini ada, status_aktif
-- sudah true) dianggap otomatis Disetujui -- supaya tidak tiba-tiba
-- terkunci keluar oleh migrasi ini.
update mitra_digiprint set status_pendaftaran = 'Disetujui' where status_aktif = true;

-- Mitra baru sekarang TIDAK aktif sampai disetujui Admin
alter table mitra_digiprint alter column status_aktif set default false;

-- Perluas trigger penjaga kolom sensitif: status_pendaftaran &
-- metadata proses persetujuan sekarang ikut dikunci dari mitra sendiri
-- (kalau tidak, mitra bisa mengirim payload update yang menyelipkan
-- status_pendaftaran='Disetujui' untuk approve dirinya sendiri).
create or replace function trg_lindungi_kolom_sensitif_mitra()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'UPDATE' and not is_digiprint_admin() then
    if NEW.persentase_porsi_hmif is distinct from OLD.persentase_porsi_hmif
       or NEW.status_aktif is distinct from OLD.status_aktif
       or NEW.status_pendaftaran is distinct from OLD.status_pendaftaran
       or NEW.diproses_oleh is distinct from OLD.diproses_oleh
       or NEW.diproses_pada is distinct from OLD.diproses_pada then
      raise exception 'Kolom ini hanya boleh diubah oleh Admin HMIF';
    end if;
  end if;
  return NEW;
end;
$$;
-- (trigger trg_before_update_mitra_digiprint dari 0012 otomatis
-- memakai definisi baru ini, tidak perlu di-CREATE TRIGGER ulang)

-- Perketat gerbang transaksi: sekarang mensyaratkan status_pendaftaran
-- Disetujui juga, bukan cuma status_aktif (defense-in-depth, karena
-- keduanya seharusnya selalu diset bersamaan oleh Admin).
create or replace function catat_transaksi_digiprint(
  p_items jsonb,
  p_id_diskon uuid default null,
  p_metode_pembayaran varchar default null,
  p_catatan text default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id_mitra        uuid;
  v_item            jsonb;
  v_produk          mitra_produk%rowtype;
  v_total_kotor     numeric(12,2) := 0;
  v_nominal_diskon  numeric(12,2) := 0;
  v_persen_diskon   numeric(5,2)  := 0;
  v_id_transaksi    uuid;
  v_kuantitas       int;
begin
  select id_mitra_digiprint into v_id_mitra
    from mitra_digiprint
    where auth_user_id = auth.uid()
      and status_aktif = true
      and status_pendaftaran = 'Disetujui'
      and deleted_at is null;

  if v_id_mitra is null then
    raise exception 'Akun mitra tidak ditemukan, belum disetujui Admin HMIF, atau tidak aktif';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Keranjang kosong';
  end if;

  if p_id_diskon is not null then
    select persentase_potongan into v_persen_diskon
      from mitra_diskon
      where id_diskon = p_id_diskon
        and id_mitra_digiprint = v_id_mitra
        and status_aktif = true
        and deleted_at is null;
    if not found then
      raise exception 'Diskon tidak valid, tidak aktif, atau bukan milik mitra ini';
    end if;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_kuantitas := (v_item->>'kuantitas')::int;
    if v_kuantitas is null or v_kuantitas <= 0 then
      raise exception 'Kuantitas item tidak valid';
    end if;

    select * into v_produk
      from mitra_produk
      where id_produk = (v_item->>'id_produk')::uuid
        and id_mitra_digiprint = v_id_mitra
        and status_aktif = true
        and deleted_at is null;

    if not found then
      raise exception 'Produk tidak ditemukan, tidak aktif, atau bukan milik mitra ini';
    end if;

    if v_produk.stok is not null and v_produk.stok < v_kuantitas then
      raise exception 'Stok "%" tidak cukup (sisa %, diminta %)', v_produk.nama_produk, v_produk.stok, v_kuantitas;
    end if;

    v_total_kotor := v_total_kotor + (v_produk.harga_satuan * v_kuantitas);
  end loop;

  v_nominal_diskon := round(v_total_kotor * v_persen_diskon / 100, 2);

  insert into mitra_transaksi (
    id_mitra_digiprint, id_diskon, total_kotor, nominal_diskon, metode_pembayaran, catatan
  ) values (
    v_id_mitra, p_id_diskon, v_total_kotor, v_nominal_diskon, p_metode_pembayaran, p_catatan
  ) returning id_transaksi into v_id_transaksi;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_kuantitas := (v_item->>'kuantitas')::int;

    select * into v_produk from mitra_produk where id_produk = (v_item->>'id_produk')::uuid;

    insert into mitra_transaksi_detail (
      id_transaksi, id_produk, nama_produk_snapshot, harga_satuan_snapshot, kuantitas, subtotal
    ) values (
      v_id_transaksi, v_produk.id_produk, v_produk.nama_produk, v_produk.harga_satuan,
      v_kuantitas, v_produk.harga_satuan * v_kuantitas
    );

    if v_produk.stok is not null then
      update mitra_produk set stok = stok - v_kuantitas where id_produk = v_produk.id_produk;
    end if;
  end loop;

  return v_id_transaksi;
end;
$$;

-- ============================================================
-- CATATAN: TIDAK ADA POLICY BARU YANG DIPERLUKAN UNTUK APPROVAL.
-- Admin menyetujui/menolak lewat UPDATE biasa ke mitra_digiprint,
-- yang sudah diizinkan policy "admin_update_semua_mitra" dari 0012 --
-- trigger di atas yang menjaga supaya HANYA admin yang bisa lewat.
-- ============================================================
