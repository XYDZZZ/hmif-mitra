-- ============================================================
-- MIGRATION 0014: KATEGORI TRANSAKSI (PENJUALAN vs PEMAKAIAN
-- INTERNAL HMIF)
-- Lanjutan dari 0012 & 0013.
-- ============================================================
-- Kasus: pengurus/anggota HMIF mengambil kertas A4/F4/dll dari mitra
-- untuk keperluan organisasi. Secara kepemilikan itu bukan penjualan
-- (tidak ada uang yang berpindah, baik ke mitra maupun ke Kas HMIF),
-- tapi stok tetap harus berkurang dan tetap perlu tercatat untuk
-- akuntabilitas -- siapa ambil, untuk apa, berapa nilainya.
-- ============================================================

alter table mitra_transaksi
  add column jenis_transaksi varchar(30) not null default 'Penjualan'
    constraint chk_jenis_transaksi check (jenis_transaksi in ('Penjualan', 'Pemakaian Internal HMIF')),
  add constraint chk_catatan_wajib_internal check (
    jenis_transaksi <> 'Pemakaian Internal HMIF'
    or (catatan is not null and length(trim(catatan)) > 0)
  );

comment on column mitra_transaksi.jenis_transaksi is 'Penjualan = transaksi normal ke pelanggan, dibagi porsi_mitra/porsi_hmif seperti biasa. Pemakaian Internal HMIF = kertas/jasa diambil pengurus/anggota HMIF sendiri, TIDAK ada uang masuk sehingga porsi_mitra & porsi_hmif dipaksa 0 oleh trigger, tapi total_kotor/total_bersih tetap tersimpan sebagai nilai informasional (berapa nilai yang terpakai), dan stok tetap dipotong seperti biasa.';

-- ============================================================
-- Perluas trigger kalkulasi: paksa porsi jadi 0 untuk pemakaian
-- internal, dan kunci jenis_transaksi supaya tidak bisa diubah
-- sepihak oleh mitra (mencegah transaksi asli "disamarkan" jadi
-- internal untuk menghindari setoran, atau sebaliknya).
-- ============================================================
create or replace function trg_mitra_transaksi_biz_rules()
returns trigger
language plpgsql
as $$
declare
  v_persen_hmif numeric(5,2);
begin
  if TG_OP = 'UPDATE' then
    if NEW.status_setoran is distinct from OLD.status_setoran and not is_digiprint_admin() then
      raise exception 'Hanya Admin HMIF yang dapat mengubah status_setoran';
    end if;
    if NEW.id_mitra_digiprint is distinct from OLD.id_mitra_digiprint then
      raise exception 'id_mitra_digiprint tidak boleh diubah setelah transaksi dibuat';
    end if;
    if NEW.jenis_transaksi is distinct from OLD.jenis_transaksi and not is_digiprint_admin() then
      raise exception 'Hanya Admin HMIF yang dapat mengubah jenis transaksi setelah dibuat';
    end if;
  end if;

  if NEW.jenis_transaksi = 'Pemakaian Internal HMIF'
     and (NEW.catatan is null or length(trim(NEW.catatan)) = 0) then
    raise exception 'Catatan (nama pengambil/keperluan) wajib diisi untuk Pemakaian Internal HMIF';
  end if;

  select persentase_porsi_hmif into v_persen_hmif
    from mitra_digiprint
    where id_mitra_digiprint = NEW.id_mitra_digiprint;

  if v_persen_hmif is null then
    raise exception 'Konfigurasi persentase porsi HMIF tidak ditemukan untuk mitra ini';
  end if;

  NEW.persentase_hmif_saat_transaksi := v_persen_hmif;
  NEW.total_bersih := NEW.total_kotor - NEW.nominal_diskon;

  if NEW.total_bersih < 0 then
    raise exception 'total_bersih tidak boleh negatif (nominal_diskon melebihi total_kotor)';
  end if;

  if NEW.jenis_transaksi = 'Pemakaian Internal HMIF' then
    NEW.porsi_hmif := 0;
    NEW.porsi_mitra := 0;
  else
    NEW.porsi_hmif := round(NEW.total_bersih * v_persen_hmif / 100, 2);
    NEW.porsi_mitra := NEW.total_bersih - NEW.porsi_hmif;
  end if;

  return NEW;
end;
$$;

-- ============================================================
-- catat_transaksi_digiprint: tambah parameter p_jenis_transaksi.
-- Signature berubah (5 parameter, sebelumnya 4) sehingga fungsi lama
-- di-drop dulu supaya tidak ada dua versi nyangkut berbarengan.
-- ============================================================
drop function if exists catat_transaksi_digiprint(jsonb, uuid, varchar, text);

create or replace function catat_transaksi_digiprint(
  p_items jsonb,
  p_id_diskon uuid default null,
  p_metode_pembayaran varchar default null,
  p_catatan text default null,
  p_jenis_transaksi varchar default 'Penjualan'
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
  if p_jenis_transaksi not in ('Penjualan', 'Pemakaian Internal HMIF') then
    raise exception 'jenis_transaksi tidak valid';
  end if;

  if p_jenis_transaksi = 'Pemakaian Internal HMIF'
     and (p_catatan is null or length(trim(p_catatan)) = 0) then
    raise exception 'Catatan (nama pengambil/keperluan) wajib diisi untuk Pemakaian Internal HMIF';
  end if;

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
    id_mitra_digiprint, id_diskon, total_kotor, nominal_diskon, metode_pembayaran, catatan, jenis_transaksi
  ) values (
    v_id_mitra, p_id_diskon, v_total_kotor, v_nominal_diskon, p_metode_pembayaran, p_catatan, p_jenis_transaksi
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

grant execute on function catat_transaksi_digiprint(jsonb, uuid, varchar, text, varchar) to authenticated;
