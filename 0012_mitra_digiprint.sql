-- ============================================================
-- MIGRATION 0012: MANAJEMEN MITRA DIGIPRINT
-- SIM HIMATIF
-- ============================================================
-- CATATAN ARSITEKTUR (baca sebelum menjalankan):
--
-- Skema di migrations.zip TIDAK memakai Supabase Auth (auth.uid()
-- tidak dipakai sama sekali) -- login users/mitra pakai password_hash
-- custom, dan otorisasi ditangani di server Next.js. 0005_rls_lockdown
-- sengaja membuat RLS default-deny total untuk anon/authenticated di
-- SEMUA tabel lama; hanya service_role yang tembus.
--
-- Modul DIGIPRINT ini adalah SPA statis (HTML/JS murni via CDN, TANPA
-- server) sesuai permintaan, sehingga TIDAK punya service_role yang
-- aman untuk disimpan di browser. Konsekuensinya, modul ini WAJIB pakai
-- Supabase Auth (auth.uid()) sungguhan sebagai identitas, supaya RLS
-- bisa jadi satu-satunya lapisan keamanan yang berlaku.
--
-- Prinsip yang dipegang di migrasi ini:
--   1. TIDAK mengubah/melonggarkan RLS tabel lama (0001-0011) sama sekali.
--   2. Tabel baru di sini punya identitas sendiri (mitra_digiprint,
--      digiprint_admin) yang terhubung ke auth.users, terpisah dari
--      tabel `mitra` (danus) & `users` (anggota) yang sudah ada --
--      supaya tidak mewarisi/mencampur model keamanan modul lain.
--   3. Angka uang (total, diskon, porsi) SELALU dihitung ulang di
--      Postgres (trigger + function), tidak pernah dipercaya mentah
--      dari client -- pola yang sama seperti proses_transaksi_danus()
--      di 0004_danus_mitra.sql (snapshot harga, hitung server-side).
--   4. Siapa yang jadi "Admin HMIF" TIDAK bisa diatur dari frontend --
--      hanya lewat SQL editor/dashboard oleh pengurus yang punya akses
--      Supabase, konsisten dengan filosofi default-deny 0005.
-- ============================================================

-- ------------------------------------------------------------
-- TABEL: mitra_digiprint
-- Identitas bisnis mitra DIGIPRINT, 1:1 dengan auth.users.
-- ------------------------------------------------------------
create table mitra_digiprint (
  id_mitra_digiprint     uuid primary key default gen_random_uuid(),
  auth_user_id           uuid not null unique references auth.users(id) on delete cascade,
  nama_usaha             varchar(150) not null,
  nama_pemilik           varchar(150) not null,
  kontak_whatsapp        varchar(20),
  persentase_porsi_hmif  numeric(5,2) not null default 20
                            constraint chk_persentase_porsi_hmif check (persentase_porsi_hmif between 0 and 100),
  status_aktif           boolean not null default true,
  dibuat_pada            timestamptz not null default now(),
  deleted_at             timestamptz
);

comment on table mitra_digiprint is 'Identitas mitra DIGIPRINT. Baris ini dibuat otomatis saat mitra login pertama kali (self-provisioning), tapi persentase_porsi_hmif & status_aktif hanya boleh diubah Admin HMIF (lihat trigger trg_before_write_mitra_digiprint).';
comment on column mitra_digiprint.persentase_porsi_hmif is 'Persen dari total_bersih yang jadi hak HMIF, contoh default 20 = HMIF 20%% / Mitra 80%%. Diambil sebagai snapshot ke tiap transaksi.';

-- ------------------------------------------------------------
-- TABEL: digiprint_admin
-- Whitelist akun Supabase Auth yang berperan sebagai "Admin HMIF"
-- (mis. Bendahara/Ketua). HANYA dikelola manual lewat SQL editor --
-- sengaja tidak ada policy insert/update/delete untuk client.
-- ------------------------------------------------------------
create table digiprint_admin (
  auth_user_id      uuid primary key references auth.users(id) on delete cascade,
  keterangan        text,
  ditambahkan_pada  timestamptz not null default now()
);

comment on table digiprint_admin is 'Daftar akun Admin HMIF untuk modul digiprint. Isi manual lewat SQL editor Supabase, contoh: insert into digiprint_admin (auth_user_id, keterangan) values (''<uuid-dari-auth.users>'', ''Bendahara 2026'');';

-- ------------------------------------------------------------
-- FUNCTION: is_digiprint_admin()
-- Helper dipakai di RLS policy & trigger. Aman dipanggil siapa saja
-- (tidak bocorkan daftar admin) karena hanya cek baris milik sendiri.
-- ------------------------------------------------------------
create or replace function is_digiprint_admin()
returns boolean
language sql
security invoker
stable
as $$
  select exists (
    select 1 from digiprint_admin where auth_user_id = auth.uid()
  );
$$;

comment on function is_digiprint_admin() is 'True jika user yang sedang login terdaftar sebagai Admin HMIF di modul digiprint.';

-- ------------------------------------------------------------
-- TABEL: mitra_produk
-- ------------------------------------------------------------
create table mitra_produk (
  id_produk           uuid primary key default gen_random_uuid(),
  id_mitra_digiprint  uuid not null references mitra_digiprint(id_mitra_digiprint) on delete cascade,
  nama_produk         varchar(150) not null,
  jenis               varchar(20) not null,
  harga_satuan        numeric(12,2) not null constraint chk_harga_satuan check (harga_satuan >= 0),
  stok                int,  -- boleh NULL = tidak dilacak (mis. jasa jilid)
  status_aktif        boolean not null default true,
  dibuat_pada         timestamptz not null default now(),
  deleted_at          timestamptz,

  constraint chk_jenis_produk check (jenis in ('Warna', 'Hitam Putih', 'Jilid', 'Lainnya')),
  constraint chk_stok check (stok is null or stok >= 0)
);

create index idx_mitra_produk_mitra on mitra_produk(id_mitra_digiprint);

-- ------------------------------------------------------------
-- TABEL: mitra_diskon
-- ------------------------------------------------------------
create table mitra_diskon (
  id_diskon             uuid primary key default gen_random_uuid(),
  id_mitra_digiprint    uuid not null references mitra_digiprint(id_mitra_digiprint) on delete cascade,
  kode_diskon           varchar(50) not null,
  nama_diskon           varchar(150) not null,
  persentase_potongan   numeric(5,2) not null constraint chk_persentase_potongan check (persentase_potongan between 0 and 100),
  khusus_anggota_hmif   boolean not null default false,
  status_aktif          boolean not null default true,
  dibuat_pada           timestamptz not null default now(),
  deleted_at            timestamptz
);

create index idx_mitra_diskon_mitra on mitra_diskon(id_mitra_digiprint);

-- Kode diskon unik per mitra (bukan global), abaikan yang sudah dihapus
create unique index idx_mitra_diskon_kode_aktif
  on mitra_diskon (id_mitra_digiprint, kode_diskon)
  where deleted_at is null;

comment on column mitra_diskon.khusus_anggota_hmif is 'Jika true, diskon ini hanya boleh dipakai kasir untuk pelanggan yang menunjukkan status keanggotaan HMIF (dicek manual oleh kasir saat transaksi, bukan divalidasi sistem).';

-- ------------------------------------------------------------
-- TABEL: mitra_transaksi
-- ------------------------------------------------------------
create table mitra_transaksi (
  id_transaksi                    uuid primary key default gen_random_uuid(),
  id_mitra_digiprint               uuid not null references mitra_digiprint(id_mitra_digiprint),
  kasir_auth_id                    uuid not null default auth.uid() references auth.users(id),
  id_diskon                        uuid references mitra_diskon(id_diskon),
  total_kotor                      numeric(12,2) not null constraint chk_total_kotor check (total_kotor >= 0),
  nominal_diskon                   numeric(12,2) not null default 0 constraint chk_nominal_diskon check (nominal_diskon >= 0),
  total_bersih                     numeric(12,2),        -- diisi otomatis oleh trigger
  persentase_hmif_saat_transaksi   numeric(5,2),          -- SNAPSHOT dari mitra_digiprint, diisi trigger
  porsi_mitra                      numeric(12,2),          -- dihitung trigger
  porsi_hmif                       numeric(12,2),          -- dihitung trigger
  status_setoran                   varchar(20) not null default 'Pending',
  metode_pembayaran                varchar(20),
  catatan                          text,
  dibuat_pada                      timestamptz not null default now(),
  deleted_at                       timestamptz,

  constraint chk_status_setoran check (status_setoran in ('Pending', 'Lunas')),
  constraint chk_metode_bayar check (metode_pembayaran is null or metode_pembayaran in ('Tunai', 'Transfer'))
);

create index idx_mitra_transaksi_mitra on mitra_transaksi(id_mitra_digiprint);
create index idx_mitra_transaksi_status on mitra_transaksi(status_setoran);

comment on column mitra_transaksi.status_setoran is 'Pending = belum disetor/diverifikasi ke Kas HMIF, Lunas = sudah. Hanya Admin HMIF yang boleh mengubah kolom ini (ditegakkan trigger, mirror pola verifikasi Bendahara di kas_transaksi pada 0003_keuangan.sql).';
comment on column mitra_transaksi.total_bersih is 'total_kotor - nominal_diskon. Selalu dihitung ulang di trigger, mengabaikan nilai yang dikirim client.';

-- ------------------------------------------------------------
-- TABEL: mitra_transaksi_detail
-- ------------------------------------------------------------
create table mitra_transaksi_detail (
  id_detail               uuid primary key default gen_random_uuid(),
  id_transaksi             uuid not null references mitra_transaksi(id_transaksi) on delete cascade,
  id_produk                 uuid not null references mitra_produk(id_produk),
  nama_produk_snapshot      varchar(150) not null,
  harga_satuan_snapshot     numeric(12,2) not null,
  kuantitas                 int not null constraint chk_kuantitas check (kuantitas > 0),
  subtotal                  numeric(12,2) not null
);

create index idx_mitra_transaksi_detail_transaksi on mitra_transaksi_detail(id_transaksi);

-- ============================================================
-- TRIGGER: hitung total_bersih, porsi_mitra, porsi_hmif otomatis
-- + tegakkan aturan bisnis (status_setoran hanya diubah admin,
--   id_mitra_digiprint tidak boleh dipindah setelah dibuat).
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

  NEW.porsi_hmif := round(NEW.total_bersih * v_persen_hmif / 100, 2);
  NEW.porsi_mitra := NEW.total_bersih - NEW.porsi_hmif;

  return NEW;
end;
$$;

create trigger trg_before_write_mitra_transaksi
  before insert or update on mitra_transaksi
  for each row execute function trg_mitra_transaksi_biz_rules();

-- ============================================================
-- TRIGGER: lindungi kolom sensitif di mitra_digiprint
-- Mitra boleh update profil sendiri (nama_usaha, kontak_whatsapp),
-- tapi TIDAK boleh mengubah persentase_porsi_hmif / status_aktif
-- milik sendiri -- itu wewenang Admin HMIF.
-- ============================================================
create or replace function trg_lindungi_kolom_sensitif_mitra()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'UPDATE' and not is_digiprint_admin() then
    if NEW.persentase_porsi_hmif is distinct from OLD.persentase_porsi_hmif
       or NEW.status_aktif is distinct from OLD.status_aktif then
      raise exception 'Hanya Admin HMIF yang boleh mengubah persentase porsi atau status aktif mitra';
    end if;
  end if;
  return NEW;
end;
$$;

create trigger trg_before_update_mitra_digiprint
  before update on mitra_digiprint
  for each row execute function trg_lindungi_kolom_sensitif_mitra();

-- ============================================================
-- FUNCTION: catat_transaksi_digiprint
-- Satu-satunya jalur resmi untuk mencatat transaksi POS. Dipanggil
-- dari app.js lewat supabase.rpc(). Menghitung total_kotor dari
-- HARGA PRODUK YANG TERSIMPAN DI DATABASE (bukan dari input client),
-- supaya kasir tidak bisa memanipulasi total lewat DevTools.
-- security invoker (default) -- tetap tunduk ke RLS mitra_produk/
-- mitra_diskon/mitra_transaksi milik pemanggil, tidak ada bypass.
-- ============================================================
create or replace function catat_transaksi_digiprint(
  p_items jsonb,                    -- [{"id_produk": "...", "kuantitas": 2}, ...]
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
    where auth_user_id = auth.uid() and status_aktif = true and deleted_at is null;

  if v_id_mitra is null then
    raise exception 'Akun mitra tidak ditemukan atau tidak aktif';
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

  -- Pass 1: validasi & hitung total dari harga live di database
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

  -- Pass 2: insert detail (snapshot harga & nama) + potong stok
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

comment on function catat_transaksi_digiprint(jsonb, uuid, varchar, text) is 'Jalur resmi POS. Body: p_items = [{"id_produk": uuid, "kuantitas": int}, ...]. Harga & total selalu dihitung server-side dari mitra_produk, tidak menerima harga dari client.';

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table mitra_digiprint enable row level security;
alter table digiprint_admin enable row level security;
alter table mitra_produk enable row level security;
alter table mitra_diskon enable row level security;
alter table mitra_transaksi enable row level security;
alter table mitra_transaksi_detail enable row level security;

-- ---------- digiprint_admin ----------
-- Tidak ada policy insert/update/delete sama sekali (sengaja) --
-- hanya bisa diisi lewat SQL editor oleh yang punya akses dashboard.
create policy "admin_lihat_baris_sendiri"
  on digiprint_admin for select
  using (auth_user_id = auth.uid());

-- ---------- mitra_digiprint ----------
create policy "mitra_lihat_profil_sendiri"
  on mitra_digiprint for select
  using (auth_user_id = auth.uid());

create policy "admin_lihat_semua_mitra"
  on mitra_digiprint for select
  using (is_digiprint_admin());

-- Self-provisioning: baris dibuat otomatis saat login pertama kali
create policy "mitra_buat_profil_sendiri"
  on mitra_digiprint for insert
  with check (auth_user_id = auth.uid());

create policy "mitra_update_profil_sendiri"
  on mitra_digiprint for update
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- Admin boleh update baris siapa saja (dipakai utk approve/atur
-- persentase_porsi_hmif & status_aktif -- lihat trigger perlindungan
-- kolom di atas untuk pembatasan lebih detail)
create policy "admin_update_semua_mitra"
  on mitra_digiprint for update
  using (is_digiprint_admin())
  with check (is_digiprint_admin());

-- ---------- mitra_produk (Mitra: CRUD penuh milik sendiri) ----------
create policy "mitra_kelola_produk_sendiri"
  on mitra_produk for all
  using (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  )
  with check (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

create policy "admin_lihat_semua_produk"
  on mitra_produk for select
  using (is_digiprint_admin());

-- ---------- mitra_diskon (Mitra: CRUD penuh milik sendiri) ----------
create policy "mitra_kelola_diskon_sendiri"
  on mitra_diskon for all
  using (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  )
  with check (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

create policy "admin_lihat_semua_diskon"
  on mitra_diskon for select
  using (is_digiprint_admin());

-- ---------- mitra_transaksi ----------
-- Mitra: lihat semua transaksi sendiri (histori penuh)
create policy "mitra_lihat_transaksi_sendiri"
  on mitra_transaksi for select
  using (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

-- Mitra: insert transaksi milik sendiri (idealnya lewat RPC
-- catat_transaksi_digiprint, tapi policy ini dijaga juga sebagai
-- defense-in-depth kalau suatu saat insert langsung dipakai)
create policy "mitra_input_transaksi_sendiri"
  on mitra_transaksi for insert
  with check (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

-- Mitra: hanya boleh edit/batalkan transaksi SENDIRI yang masih
-- Pending (belum diverifikasi/disetor) -- transaksi Lunas terkunci.
create policy "mitra_update_transaksi_pending"
  on mitra_transaksi for update
  using (
    status_setoran = 'Pending'
    and id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  )
  with check (
    id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

create policy "mitra_hapus_transaksi_pending"
  on mitra_transaksi for delete
  using (
    status_setoran = 'Pending'
    and id_mitra_digiprint in (
      select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
    )
  );

-- Admin HMIF: SELECT semua transaksi semua mitra (sesuai spek: read-only)
create policy "admin_lihat_semua_transaksi"
  on mitra_transaksi for select
  using (is_digiprint_admin());

-- Perluasan yang disengaja di luar spek "read-only": Admin butuh bisa
-- memverifikasi setoran (ubah status_setoran ke Lunas), sama seperti
-- pola diverifikasi_oleh Bendahara di kas_transaksi (0003). Kolom lain
-- selain status_setoran tetap dikunci oleh trigger di atas.
create policy "admin_verifikasi_setoran"
  on mitra_transaksi for update
  using (is_digiprint_admin())
  with check (is_digiprint_admin());

-- ---------- mitra_transaksi_detail ----------
create policy "mitra_lihat_detail_sendiri"
  on mitra_transaksi_detail for select
  using (
    exists (
      select 1 from mitra_transaksi t
      where t.id_transaksi = mitra_transaksi_detail.id_transaksi
        and t.id_mitra_digiprint in (
          select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
        )
    )
  );

create policy "mitra_kelola_detail_pending"
  on mitra_transaksi_detail for all
  using (
    exists (
      select 1 from mitra_transaksi t
      where t.id_transaksi = mitra_transaksi_detail.id_transaksi
        and t.status_setoran = 'Pending'
        and t.id_mitra_digiprint in (
          select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
        )
    )
  )
  with check (
    exists (
      select 1 from mitra_transaksi t
      where t.id_transaksi = mitra_transaksi_detail.id_transaksi
        and t.id_mitra_digiprint in (
          select id_mitra_digiprint from mitra_digiprint where auth_user_id = auth.uid()
        )
    )
  );

create policy "admin_lihat_semua_detail"
  on mitra_transaksi_detail for select
  using (is_digiprint_admin());

-- ============================================================
-- GRANTS
-- Eksplisit (jangan mengandalkan default privileges project) --
-- anon TIDAK diberi apa pun (harus login). RLS di atas tetap jadi
-- pagar utama; grant ini hanya membuka pintu di level tabel/fungsi.
-- ============================================================
grant select, insert, update, delete on mitra_digiprint      to authenticated;
grant select                        on digiprint_admin       to authenticated;
grant select, insert, update, delete on mitra_produk          to authenticated;
grant select, insert, update, delete on mitra_diskon          to authenticated;
grant select, insert, update, delete on mitra_transaksi       to authenticated;
grant select, insert, update, delete on mitra_transaksi_detail to authenticated;

grant execute on function is_digiprint_admin() to authenticated;
grant execute on function catat_transaksi_digiprint(jsonb, uuid, varchar, text) to authenticated;

-- ============================================================
-- SETUP MANUAL SETELAH MIGRASI INI DIJALANKAN:
--
-- 1. Di Supabase Dashboard > Authentication > Providers, pastikan
--    Email provider aktif (untuk login Mitra & Admin HMIF).
--
-- 2. Jadikan seseorang Admin HMIF (mis. Bendahara) -- setelah orang
--    tsb sign up sekali lewat form login di index.html:
--      insert into digiprint_admin (auth_user_id, keterangan)
--      values ('<uuid dari auth.users, lihat di dashboard>', 'Bendahara 2026');
--
-- 3. Mitra tinggal sign up sendiri lewat form login -- profil usaha
--    (mitra_digiprint) akan otomatis dibuat saat mereka mengisi form
--    "Lengkapi Profil" pertama kali.
-- ============================================================
