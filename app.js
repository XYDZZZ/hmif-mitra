/* ============================================================
   MITRA DIGIPRINT — app.js
   Vanilla JS murni, tanpa build tools. Memakai Supabase JS Client
   v2 lewat CDN (lihat <script> di index.html).
============================================================= */

// ------------------------------------------------------------
// 1. KONEKSI SUPABASE
// ------------------------------------------------------------
// SUPABASE_URL & SUPABASE_ANON_KEY didefinisikan di config.js
// (dimuat sebelum file ini di index.html) supaya tidak perlu diisi
// ulang setiap kali app.js diperbarui.
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ------------------------------------------------------------
// 2. STATE APLIKASI
// ------------------------------------------------------------
const state = {
  session: null,
  isAdmin: false,
  mitra: null,          // baris mitra_digiprint milik user (null jika admin / belum setup)
  authMode: "masuk",     // "masuk" | "daftar"
  produkList: [],
  diskonList: [],
  jenisFilter: "Semua",
  approvalFilter: "Menunggu",
  laporanStatusFilter: "semua",
  cart: [],              // [{id_produk, nama_produk, harga_satuan, kuantitas, stokMax}]
  activeView: "pos",
  activeSubview: "produk",
};

const fmtRupiah = new Intl.NumberFormat("id-ID", {
  style: "currency",
  currency: "IDR",
  maximumFractionDigits: 0,
});

const fmtWaktu = new Intl.DateTimeFormat("id-ID", {
  day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit",
});

// ------------------------------------------------------------
// 3. HELPER DOM KECIL
// ------------------------------------------------------------
function $(id) { return document.getElementById(id); }
function showEl(el) { el.classList.remove("hidden"); }
function hideEl(el) { el.classList.add("hidden"); }

function showScreen(name) {
  ["screen-loading", "screen-auth", "screen-setup-profil", "screen-menunggu-approval", "screen-app"].forEach((id) => {
    id === name ? showEl($(id)) : hideEl($(id));
  });
}

function setFormError(el, message) {
  if (!message) { hideEl(el); el.textContent = ""; return; }
  el.textContent = message;
  showEl(el);
}

function showBanner(message, isError = false) {
  const el = $("status-banner");
  el.textContent = message;
  el.classList.toggle("is-error", isError);
  showEl(el);
  window.clearTimeout(showBanner._t);
  showBanner._t = window.setTimeout(() => hideEl(el), 4000);
}

function setButtonLoading(btn, loading, loadingText = "Memproses...") {
  if (loading) {
    btn.dataset.originalText = btn.textContent;
    btn.textContent = loadingText;
    btn.disabled = true;
  } else {
    btn.textContent = btn.dataset.originalText || btn.textContent;
    btn.disabled = false;
  }
}

function friendlyError(error) {
  if (!error) return "Terjadi kesalahan yang tidak diketahui.";
  const msg = error.message || String(error);
  if (msg.includes("Invalid login credentials")) return "Email atau kata sandi salah.";
  if (msg.includes("User already registered")) return "Email ini sudah terdaftar. Coba masuk.";
  if (msg.includes("duplicate key value")) return "Data dengan kode/nilai ini sudah ada.";
  return msg;
}

// ==============================================================
// 4. AUTENTIKASI
// ==============================================================

async function init() {
  showScreen("screen-loading");

  const { data: { session } } = await supabaseClient.auth.getSession();
  state.session = session;

  supabaseClient.auth.onAuthStateChange((_event, newSession) => {
    state.session = newSession;
  });

  if (session) {
    await resolveUserAndBoot();
  } else {
    showScreen("screen-auth");
  }
}

function renderAuthMode() {
  const isDaftar = state.authMode === "daftar";
  $("auth-title").textContent = isDaftar ? "Daftar akun mitra" : "Masuk ke akun Anda";
  $("btn-auth-submit").textContent = isDaftar ? "Daftar" : "Masuk";
  $("auth-toggle-label").textContent = isDaftar ? "Sudah punya akun?" : "Belum punya akun mitra?";
  $("btn-auth-toggle").textContent = isDaftar ? "Masuk" : "Daftar akun mitra";
  setFormError($("auth-error"), "");
}

$("btn-auth-toggle").addEventListener("click", () => {
  state.authMode = state.authMode === "masuk" ? "daftar" : "masuk";
  renderAuthMode();
});

$("form-auth").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = $("btn-auth-submit");
  setFormError($("auth-error"), "");

  const email = $("input-email").value.trim();
  const password = $("input-password").value;

  setButtonLoading(btn, true, state.authMode === "daftar" ? "Mendaftarkan..." : "Masuk...");
  try {
    if (state.authMode === "daftar") {
      const { data, error } = await supabaseClient.auth.signUp({ email, password });
      if (error) throw error;

      if (!data.session) {
        // Project mewajibkan konfirmasi email
        setFormError(
          $("auth-error"),
          "Pendaftaran berhasil. Silakan cek email Anda untuk konfirmasi, lalu masuk."
        );
        state.authMode = "masuk";
        renderAuthMode();
        return;
      }
      state.session = data.session;
      await resolveUserAndBoot();
    } else {
      const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
      if (error) throw error;
      state.session = data.session;
      await resolveUserAndBoot();
    }
  } catch (err) {
    setFormError($("auth-error"), friendlyError(err));
  } finally {
    setButtonLoading(btn, false);
  }
});

$("btn-logout").addEventListener("click", async () => {
  await supabaseClient.auth.signOut();
  state.session = null;
  state.isAdmin = false;
  state.mitra = null;
  state.cart = [];
  $("input-email").value = "";
  $("input-password").value = "";
  showScreen("screen-auth");
});

$("form-setup-profil").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = $("btn-setup-submit");
  setFormError($("setup-error"), "");

  const nama_usaha = $("input-nama-usaha").value.trim();
  const nama_pemilik = $("input-nama-pemilik").value.trim();
  const kontak_whatsapp = $("input-kontak-wa").value.trim() || null;

  setButtonLoading(btn, true, "Menyimpan...");
  try {
    const { data, error } = await supabaseClient
      .from("mitra_digiprint")
      .insert({
        auth_user_id: state.session.user.id,
        nama_usaha,
        nama_pemilik,
        kontak_whatsapp,
      })
      .select()
      .single();
    if (error) throw error;
    state.mitra = data;
    routeMitraByStatus();
  } catch (err) {
    setFormError($("setup-error"), friendlyError(err));
  } finally {
    setButtonLoading(btn, false);
  }
});

async function resolveUserAndBoot() {
  showScreen("screen-loading");
  try {
    const { data: isAdmin, error: adminErr } = await supabaseClient.rpc("is_digiprint_admin");
    if (adminErr) throw adminErr;
    state.isAdmin = !!isAdmin;

    if (state.isAdmin) {
      await bootAdminApp();
      return;
    }

    const { data: mitraRow, error: mitraErr } = await supabaseClient
      .from("mitra_digiprint")
      .select("*")
      .eq("auth_user_id", state.session.user.id)
      .is("deleted_at", null)
      .maybeSingle();
    if (mitraErr) throw mitraErr;

    if (!mitraRow) {
      showScreen("screen-setup-profil");
      return;
    }
    state.mitra = mitraRow;
    routeMitraByStatus();
  } catch (err) {
    showScreen("screen-auth");
    setFormError($("auth-error"), friendlyError(err));
  }
}

// Mengarahkan mitra ke layar yang tepat sesuai status_pendaftaran &
// status_aktif: aplikasi penuh (Disetujui + aktif), layar menunggu
// (Menunggu), atau layar ditolak (Ditolak).
function routeMitraByStatus() {
  const m = state.mitra;
  if (m.status_pendaftaran === "Disetujui" && m.status_aktif) {
    bootMitraApp();
    return;
  }

  if (m.status_pendaftaran === "Ditolak") {
    $("menunggu-judul").textContent = "Pendaftaran ditolak";
    $("menunggu-pesan").textContent = m.catatan_penolakan
      ? `Admin HMIF menolak pendaftaran usaha Anda. Alasan: "${m.catatan_penolakan}". Hubungi pengurus HMIF untuk info lebih lanjut.`
      : "Admin HMIF menolak pendaftaran usaha Anda. Hubungi pengurus HMIF untuk info lebih lanjut.";
  } else if (m.status_pendaftaran === "Disetujui" && !m.status_aktif) {
    $("menunggu-judul").textContent = "Akun dinonaktifkan";
    $("menunggu-pesan").textContent = "Akun mitra Anda saat ini dinonaktifkan oleh Admin HMIF. Hubungi pengurus HMIF untuk info lebih lanjut.";
  } else {
    $("menunggu-judul").textContent = "Menunggu persetujuan";
    $("menunggu-pesan").textContent = "Pendaftaran usaha Anda sedang ditinjau oleh Admin HMIF. Anda akan bisa mengakses Kasir setelah disetujui.";
  }
  showScreen("screen-menunggu-approval");
}

$("btn-menunggu-refresh").addEventListener("click", async () => {
  const btn = $("btn-menunggu-refresh");
  setButtonLoading(btn, true, "Memeriksa...");
  try {
    const { data, error } = await supabaseClient
      .from("mitra_digiprint")
      .select("*")
      .eq("auth_user_id", state.session.user.id)
      .is("deleted_at", null)
      .maybeSingle();
    if (error) throw error;
    if (data) { state.mitra = data; routeMitraByStatus(); }
  } catch (err) {
    showBanner(friendlyError(err), true);
  } finally {
    setButtonLoading(btn, false);
  }
});

$("btn-menunggu-logout").addEventListener("click", () => $("btn-logout").click());

// ==============================================================
// 5. NAVIGASI
// ==============================================================

function switchView(viewName) {
  state.activeView = viewName;
  ["pos", "produk", "laporan", "approval"].forEach((v) => {
    $(`view-${v}`).classList.toggle("hidden", v !== viewName);
    $(`tab-btn-${v}`).classList.toggle("is-active", v === viewName);
  });
  if (viewName === "laporan") loadLaporan();
  if (viewName === "pos") { loadProduk(); loadDiskon(); loadRiwayat(); }
  if (viewName === "produk") { loadProdukTable(); loadDiskonTable(); }
  if (viewName === "approval") loadApprovalMitra();
}

document.querySelectorAll(".nav-tab").forEach((btn) => {
  btn.addEventListener("click", () => switchView(btn.dataset.view));
});

function switchSubview(name) {
  state.activeSubview = name;
  ["produk", "diskon"].forEach((v) => {
    $(`subview-${v}`).classList.toggle("hidden", v !== name);
    $(`subtab-btn-${v}`).classList.toggle("is-active", v === name);
  });
}
$("subtab-btn-produk").addEventListener("click", () => switchSubview("produk"));
$("subtab-btn-diskon").addEventListener("click", () => switchSubview("diskon"));

async function bootMitraApp() {
  $("nav-identitas").textContent = state.mitra.nama_usaha;
  showEl($("tab-btn-pos"));
  showEl($("tab-btn-produk"));
  hideEl($("tab-btn-approval"));
  $("laporan-title").textContent = "Laporan Keuangan";
  $("laporan-subtitle").textContent = "Ringkasan pendapatan usaha Anda dan setoran ke Kas HMIF.";
  hideEl($("panel-laporan-per-mitra"));
  document.querySelectorAll(".th-mitra").forEach(hideEl);

  showScreen("screen-app");
  switchView("pos");
}

async function bootAdminApp() {
  $("nav-identitas").textContent = "Admin HMIF";
  hideEl($("tab-btn-pos"));
  hideEl($("tab-btn-produk"));
  showEl($("tab-btn-approval"));
  $("laporan-title").textContent = "Laporan Keuangan — Semua Mitra";
  $("laporan-subtitle").textContent = "Akses baca untuk seluruh transaksi mitra DIGIPRINT, plus verifikasi setoran.";
  showEl($("panel-laporan-per-mitra"));
  document.querySelectorAll(".th-mitra").forEach(showEl);

  showScreen("screen-app");
  switchView("laporan");
}

// ==============================================================
// 6. KASIR / POS
// ==============================================================

async function loadProduk() {
  const { data, error } = await supabaseClient
    .from("mitra_produk")
    .select("*")
    .eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint)
    .eq("status_aktif", true)
    .is("deleted_at", null)
    .order("nama_produk");

  if (error) { showBanner(friendlyError(error), true); return; }
  state.produkList = data;
  renderProductGrid();
}

function renderProductGrid() {
  const grid = $("pos-product-grid");
  const list = state.produkList.filter(
    (p) => state.jenisFilter === "Semua" || p.jenis === state.jenisFilter
  );

  grid.innerHTML = "";
  $("pos-product-empty").classList.toggle("hidden", state.produkList.length > 0);

  list.forEach((p) => {
    const habis = p.stok !== null && p.stok <= 0;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pos-product-card" + (habis ? " is-out" : "");
    btn.disabled = habis;
    btn.dataset.id = p.id_produk;
    btn.innerHTML = `
      <span class="p-jenis">${p.jenis}</span>
      <p class="p-nama">${escapeHtml(p.nama_produk)}</p>
      <p class="p-harga">${fmtRupiah.format(p.harga_satuan)}</p>
      ${p.stok !== null ? `<p class="p-stok">Stok: ${p.stok}</p>` : ""}
    `;
    btn.addEventListener("click", () => addToCart(p));
    grid.appendChild(btn);
  });
}

$("pos-filter-jenis").addEventListener("click", (e) => {
  const chip = e.target.closest(".chip");
  if (!chip) return;
  document.querySelectorAll("#pos-filter-jenis .chip").forEach((c) => c.classList.remove("is-active"));
  chip.classList.add("is-active");
  state.jenisFilter = chip.dataset.jenis;
  renderProductGrid();
});

function addToCart(produk) {
  const existing = state.cart.find((c) => c.id_produk === produk.id_produk);
  if (existing) {
    if (produk.stok !== null && existing.kuantitas >= produk.stok) {
      showBanner(`Stok "${produk.nama_produk}" tidak cukup.`, true);
      return;
    }
    existing.kuantitas += 1;
  } else {
    state.cart.push({
      id_produk: produk.id_produk,
      nama_produk: produk.nama_produk,
      harga_satuan: produk.harga_satuan,
      kuantitas: 1,
      stokMax: produk.stok,
    });
  }
  renderCart();
}

function changeQty(id_produk, delta) {
  const item = state.cart.find((c) => c.id_produk === id_produk);
  if (!item) return;
  item.kuantitas += delta;
  if (item.kuantitas <= 0) {
    state.cart = state.cart.filter((c) => c.id_produk !== id_produk);
  } else if (item.stokMax !== null && item.kuantitas > item.stokMax) {
    item.kuantitas = item.stokMax;
    showBanner(`Stok "${item.nama_produk}" tidak cukup.`, true);
  }
  renderCart();
}

function renderCart() {
  const wrap = $("pos-cart-items");
  wrap.innerHTML = "";
  $("pos-cart-empty").classList.toggle("hidden", state.cart.length > 0);
  $("btn-pos-simpan").disabled = state.cart.length === 0;

  state.cart.forEach((item) => {
    const row = document.createElement("div");
    row.className = "cart-row";
    row.innerHTML = `
      <div class="c-info">
        <p class="c-nama">${escapeHtml(item.nama_produk)}</p>
        <p class="c-harga">${fmtRupiah.format(item.harga_satuan)}</p>
      </div>
      <div class="c-qty">
        <button type="button" class="qty-btn" data-action="dec">−</button>
        <span>${item.kuantitas}</span>
        <button type="button" class="qty-btn" data-action="inc">+</button>
      </div>
      <div class="c-subtotal">${fmtRupiah.format(item.harga_satuan * item.kuantitas)}</div>
    `;
    row.querySelector('[data-action="inc"]').addEventListener("click", () => changeQty(item.id_produk, 1));
    row.querySelector('[data-action="dec"]').addEventListener("click", () => changeQty(item.id_produk, -1));
    wrap.appendChild(row);
  });

  computeTotals();
}

function computeTotals() {
  const totalKotor = state.cart.reduce((sum, c) => sum + c.harga_satuan * c.kuantitas, 0);
  const opt = $("pos-select-diskon").selectedOptions[0];
  const persen = opt ? Number(opt.dataset.persen || 0) : 0;
  const nominalDiskon = Math.round((totalKotor * persen) / 100);
  const totalBersih = totalKotor - nominalDiskon;

  $("pos-total-kotor").textContent = fmtRupiah.format(totalKotor);
  $("pos-total-diskon").textContent = "− " + fmtRupiah.format(nominalDiskon);
  $("pos-total-bersih").textContent = fmtRupiah.format(totalBersih);
}

$("pos-select-diskon").addEventListener("change", computeTotals);

$("pos-select-jenis-transaksi").addEventListener("change", () => {
  const isInternal = $("pos-select-jenis-transaksi").value === "Pemakaian Internal HMIF";
  $("pos-catatan-label").textContent = isInternal ? "Catatan (wajib — nama pengambil/keperluan)" : "Catatan (opsional)";
  $("pos-catatan-hint").classList.toggle("hidden", !isInternal);
});

$("btn-pos-kosongkan").addEventListener("click", () => {
  state.cart = [];
  renderCart();
});

async function loadDiskon() {
  const { data, error } = await supabaseClient
    .from("mitra_diskon")
    .select("*")
    .eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint)
    .eq("status_aktif", true)
    .is("deleted_at", null)
    .order("kode_diskon");

  if (error) { showBanner(friendlyError(error), true); return; }
  state.diskonList = data;

  const select = $("pos-select-diskon");
  select.innerHTML = '<option value="">Tanpa diskon</option>';
  data.forEach((d) => {
    const opt = document.createElement("option");
    opt.value = d.id_diskon;
    opt.dataset.persen = d.persentase_potongan;
    opt.textContent = `${d.kode_diskon} — ${d.nama_diskon} (${d.persentase_potongan}%)${d.khusus_anggota_hmif ? " · Khusus HMIF" : ""}`;
    select.appendChild(opt);
  });
  computeTotals();
}

$("btn-pos-simpan").addEventListener("click", async () => {
  const btn = $("btn-pos-simpan");
  setFormError($("pos-save-error"), "");

  if (state.cart.length === 0) return;

  const p_items = state.cart.map((c) => ({ id_produk: c.id_produk, kuantitas: c.kuantitas }));
  const p_id_diskon = $("pos-select-diskon").value || null;
  const p_metode_pembayaran = $("pos-select-metode").value;
  const p_jenis_transaksi = $("pos-select-jenis-transaksi").value;
  const p_catatan = $("pos-input-catatan").value.trim() || null;

  if (p_jenis_transaksi === "Pemakaian Internal HMIF" && !p_catatan) {
    setFormError($("pos-save-error"), "Catatan (nama pengambil/keperluan) wajib diisi untuk Pemakaian Internal HMIF.");
    return;
  }

  setButtonLoading(btn, true, "Menyimpan...");
  try {
    const { error } = await supabaseClient.rpc("catat_transaksi_digiprint", {
      p_items, p_id_diskon, p_metode_pembayaran, p_catatan, p_jenis_transaksi,
    });
    if (error) throw error;

    showBanner("Transaksi berhasil disimpan.");
    state.cart = [];
    $("pos-input-catatan").value = "";
    $("pos-select-jenis-transaksi").value = "Penjualan";
    $("pos-catatan-label").textContent = "Catatan (opsional)";
    hideEl($("pos-catatan-hint"));
    renderCart();
    await loadProduk();   // refresh stok
    await loadRiwayat();
  } catch (err) {
    setFormError($("pos-save-error"), friendlyError(err));
  } finally {
    setButtonLoading(btn, false);
  }
});

async function loadRiwayat() {
  const { data, error } = await supabaseClient
    .from("mitra_transaksi")
    .select("id_transaksi, total_bersih, status_setoran, status_transaksi, jenis_transaksi, dibuat_pada, mitra_transaksi_detail(kuantitas, nama_produk_snapshot)")
    .eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint)
    .order("dibuat_pada", { ascending: false })
    .limit(10);

  const tbody = $("pos-riwayat-body");
  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="empty-note">Gagal memuat riwayat.</td></tr>`;
    return;
  }
  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="5" class="empty-note">Belum ada transaksi.</td></tr>`;
    return;
  }
  tbody.innerHTML = data.map((t) => `
    <tr>
      <td>${fmtWaktu.format(new Date(t.dibuat_pada))}</td>
      <td>${t.mitra_transaksi_detail.length} item${t.jenis_transaksi === "Pemakaian Internal HMIF" ? ' <span class="badge badge-off">Internal</span>' : ""}</td>
      <td class="num">${fmtRupiah.format(t.total_bersih)}</td>
      <td>${statusBadge(t)}</td>
      <td>${t.status_transaksi !== "Dibatalkan" && t.status_setoran === "Pending"
          ? `<button type="button" class="btn-danger-text" data-action="batal" data-id="${t.id_transaksi}">Batalkan</button>`
          : ""}</td>
    </tr>
  `).join("");

  tbody.querySelectorAll('[data-action="batal"]').forEach((b) =>
    b.addEventListener("click", () => batalkanTransaksi(b.dataset.id, async () => {
      await loadRiwayat();
      await loadProduk();
    })));
}

// ==============================================================
// 7. MANAJEMEN PRODUK
// ==============================================================

async function loadProdukTable() {
  const { data, error } = await supabaseClient
    .from("mitra_produk")
    .select("*")
    .eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint)
    .is("deleted_at", null)
    .order("nama_produk");

  const tbody = $("table-produk-body");
  if (error) { tbody.innerHTML = `<tr><td colspan="6" class="empty-note">Gagal memuat produk.</td></tr>`; return; }
  state.produkList = data;

  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty-note">Belum ada produk.</td></tr>`;
    return;
  }
  tbody.innerHTML = data.map((p) => `
    <tr>
      <td>${escapeHtml(p.nama_produk)}</td>
      <td>${p.jenis}</td>
      <td class="num">${fmtRupiah.format(p.harga_satuan)}</td>
      <td class="num">${p.stok === null ? "—" : p.stok}</td>
      <td>${p.status_aktif ? '<span class="badge badge-on">Aktif</span>' : '<span class="badge badge-off">Nonaktif</span>'}</td>
      <td>
        <button type="button" class="btn-text" data-action="edit" data-id="${p.id_produk}">Ubah</button>
        <button type="button" class="btn-danger-text" data-action="hapus" data-id="${p.id_produk}">Hapus</button>
      </td>
    </tr>
  `).join("");

  tbody.querySelectorAll('[data-action="edit"]').forEach((b) =>
    b.addEventListener("click", () => editProduk(b.dataset.id)));
  tbody.querySelectorAll('[data-action="hapus"]').forEach((b) =>
    b.addEventListener("click", () => hapusProduk(b.dataset.id)));
}

function editProduk(id) {
  const p = state.produkList.find((x) => x.id_produk === id);
  if (!p) return;
  $("input-produk-id").value = p.id_produk;
  $("input-produk-nama").value = p.nama_produk;
  $("input-produk-jenis").value = p.jenis;
  $("input-produk-harga").value = p.harga_satuan;
  $("input-produk-stok").value = p.stok === null ? "" : p.stok;
  $("input-produk-status").checked = p.status_aktif;
  $("form-produk-title").textContent = "Ubah produk";
  showEl($("btn-produk-batal-edit"));
  $("input-produk-nama").focus();
}

function resetFormProduk() {
  $("form-produk").reset();
  $("input-produk-id").value = "";
  $("input-produk-status").checked = true;
  $("form-produk-title").textContent = "Tambah produk";
  hideEl($("btn-produk-batal-edit"));
}
$("btn-produk-batal-edit").addEventListener("click", resetFormProduk);

$("form-produk").addEventListener("submit", async (e) => {
  e.preventDefault();
  setFormError($("produk-form-error"), "");
  const btn = $("btn-produk-simpan");

  const id = $("input-produk-id").value;
  const stokRaw = $("input-produk-stok").value;
  const payload = {
    nama_produk: $("input-produk-nama").value.trim(),
    jenis: $("input-produk-jenis").value,
    harga_satuan: Number($("input-produk-harga").value),
    stok: stokRaw === "" ? null : Number(stokRaw),
    status_aktif: $("input-produk-status").checked,
  };

  setButtonLoading(btn, true, "Menyimpan...");
  try {
    let error;
    if (id) {
      ({ error } = await supabaseClient.from("mitra_produk").update(payload).eq("id_produk", id));
    } else {
      ({ error } = await supabaseClient.from("mitra_produk").insert({
        ...payload, id_mitra_digiprint: state.mitra.id_mitra_digiprint,
      }));
    }
    if (error) throw error;
    showBanner("Produk berhasil disimpan.");
    resetFormProduk();
    await loadProdukTable();
  } catch (err) {
    setFormError($("produk-form-error"), friendlyError(err));
  } finally {
    setButtonLoading(btn, false);
  }
});

async function hapusProduk(id) {
  if (!window.confirm("Hapus produk ini? Produk tidak akan tampil lagi di Kasir.")) return;
  const { error } = await supabaseClient
    .from("mitra_produk")
    .update({ deleted_at: new Date().toISOString(), status_aktif: false })
    .eq("id_produk", id);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Produk dihapus.");
  await loadProdukTable();
}

// ---------------- Diskon ----------------

async function loadDiskonTable() {
  const { data, error } = await supabaseClient
    .from("mitra_diskon")
    .select("*")
    .eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint)
    .is("deleted_at", null)
    .order("kode_diskon");

  const tbody = $("table-diskon-body");
  if (error) { tbody.innerHTML = `<tr><td colspan="6" class="empty-note">Gagal memuat diskon.</td></tr>`; return; }
  state.diskonList = data;

  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty-note">Belum ada diskon.</td></tr>`;
    return;
  }
  tbody.innerHTML = data.map((d) => `
    <tr>
      <td>${escapeHtml(d.kode_diskon)}</td>
      <td>${escapeHtml(d.nama_diskon)}</td>
      <td class="num">${d.persentase_potongan}%</td>
      <td>${d.khusus_anggota_hmif ? "Ya" : "Tidak"}</td>
      <td>${d.status_aktif ? '<span class="badge badge-on">Aktif</span>' : '<span class="badge badge-off">Nonaktif</span>'}</td>
      <td>
        <button type="button" class="btn-text" data-action="edit" data-id="${d.id_diskon}">Ubah</button>
        <button type="button" class="btn-danger-text" data-action="hapus" data-id="${d.id_diskon}">Hapus</button>
      </td>
    </tr>
  `).join("");

  tbody.querySelectorAll('[data-action="edit"]').forEach((b) =>
    b.addEventListener("click", () => editDiskon(b.dataset.id)));
  tbody.querySelectorAll('[data-action="hapus"]').forEach((b) =>
    b.addEventListener("click", () => hapusDiskon(b.dataset.id)));
}

function editDiskon(id) {
  const d = state.diskonList.find((x) => x.id_diskon === id);
  if (!d) return;
  $("input-diskon-id").value = d.id_diskon;
  $("input-diskon-kode").value = d.kode_diskon;
  $("input-diskon-nama").value = d.nama_diskon;
  $("input-diskon-persen").value = d.persentase_potongan;
  $("input-diskon-khusus-hmif").checked = d.khusus_anggota_hmif;
  $("input-diskon-status").checked = d.status_aktif;
  $("form-diskon-title").textContent = "Ubah diskon";
  showEl($("btn-diskon-batal-edit"));
  $("input-diskon-kode").focus();
}

function resetFormDiskon() {
  $("form-diskon").reset();
  $("input-diskon-id").value = "";
  $("input-diskon-status").checked = true;
  $("form-diskon-title").textContent = "Tambah diskon";
  hideEl($("btn-diskon-batal-edit"));
}
$("btn-diskon-batal-edit").addEventListener("click", resetFormDiskon);

$("form-diskon").addEventListener("submit", async (e) => {
  e.preventDefault();
  setFormError($("diskon-form-error"), "");
  const btn = $("btn-diskon-simpan");

  const id = $("input-diskon-id").value;
  const payload = {
    kode_diskon: $("input-diskon-kode").value.trim(),
    nama_diskon: $("input-diskon-nama").value.trim(),
    persentase_potongan: Number($("input-diskon-persen").value),
    khusus_anggota_hmif: $("input-diskon-khusus-hmif").checked,
    status_aktif: $("input-diskon-status").checked,
  };

  setButtonLoading(btn, true, "Menyimpan...");
  try {
    let error;
    if (id) {
      ({ error } = await supabaseClient.from("mitra_diskon").update(payload).eq("id_diskon", id));
    } else {
      ({ error } = await supabaseClient.from("mitra_diskon").insert({
        ...payload, id_mitra_digiprint: state.mitra.id_mitra_digiprint,
      }));
    }
    if (error) throw error;
    showBanner("Diskon berhasil disimpan.");
    resetFormDiskon();
    await loadDiskonTable();
  } catch (err) {
    setFormError($("diskon-form-error"), friendlyError(err));
  } finally {
    setButtonLoading(btn, false);
  }
});

async function hapusDiskon(id) {
  if (!window.confirm("Hapus diskon ini?")) return;
  const { error } = await supabaseClient
    .from("mitra_diskon")
    .update({ deleted_at: new Date().toISOString(), status_aktif: false })
    .eq("id_diskon", id);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Diskon dihapus.");
  await loadDiskonTable();
}

// ==============================================================
// 7b. PERSETUJUAN MITRA (khusus Admin HMIF)
// ==============================================================

$("approval-filter-status").addEventListener("click", (e) => {
  const chip = e.target.closest(".chip");
  if (!chip) return;
  document.querySelectorAll("#approval-filter-status .chip").forEach((c) => c.classList.remove("is-active"));
  chip.classList.add("is-active");
  state.approvalFilter = chip.dataset.status;
  loadApprovalMitra();
});

async function loadApprovalMitra() {
  let query = supabaseClient
    .from("mitra_digiprint")
    .select("*")
    .is("deleted_at", null)
    .order("dibuat_pada", { ascending: false });

  if (state.approvalFilter !== "Semua") query = query.eq("status_pendaftaran", state.approvalFilter);

  const { data, error } = await query;
  const tbody = $("table-approval-body");
  if (error) { tbody.innerHTML = `<tr><td colspan="7" class="empty-note">Gagal memuat data.</td></tr>`; return; }

  if (!data.length) {
    tbody.innerHTML = `<tr><td colspan="7" class="empty-note">Tidak ada data.</td></tr>`;
    return;
  }

  const badgeFor = (status) => {
    if (status === "Disetujui") return '<span class="badge badge-lunas">Disetujui</span>';
    if (status === "Ditolak") return '<span class="badge badge-batal">Ditolak</span>';
    return '<span class="badge badge-pending">Menunggu</span>';
  };

  tbody.innerHTML = data.map((m) => `
    <tr>
      <td>${escapeHtml(m.nama_usaha)}</td>
      <td>${escapeHtml(m.nama_pemilik)}</td>
      <td>${escapeHtml(m.kontak_whatsapp || "—")}</td>
      <td class="num">${m.persentase_porsi_hmif}%</td>
      <td>${fmtWaktu.format(new Date(m.dibuat_pada))}</td>
      <td>${badgeFor(m.status_pendaftaran)}</td>
      <td>
        <button type="button" class="btn-text" data-action="setujui" data-id="${m.id_mitra_digiprint}">Setujui</button>
        <button type="button" class="btn-danger-text" data-action="tolak" data-id="${m.id_mitra_digiprint}">Tolak</button>
        <button type="button" class="btn-text" data-action="ubah-persen" data-id="${m.id_mitra_digiprint}" data-persen="${m.persentase_porsi_hmif}">Ubah %</button>
      </td>
    </tr>
  `).join("");

  tbody.querySelectorAll('[data-action="setujui"]').forEach((b) =>
    b.addEventListener("click", () => setujuiMitra(b.dataset.id)));
  tbody.querySelectorAll('[data-action="tolak"]').forEach((b) =>
    b.addEventListener("click", () => tolakMitra(b.dataset.id)));
  tbody.querySelectorAll('[data-action="ubah-persen"]').forEach((b) =>
    b.addEventListener("click", () => ubahPersenMitra(b.dataset.id, b.dataset.persen)));
}

// Admin mengubah persentase porsi HMIF milik satu mitra secara manual
// (mis. ada kesepakatan baru). Kolom ini dikunci trigger di database
// supaya HANYA admin yang bisa mengubahnya -- lihat trg_lindungi_kolom_sensitif_mitra
// di 0012/0013.
async function ubahPersenMitra(id, currentPersen) {
  const input = window.prompt(`Porsi HMIF baru untuk mitra ini, dalam persen (saat ini ${currentPersen}%):`, currentPersen);
  if (input === null) return; // batal
  const persen = Number(input);
  if (Number.isNaN(persen) || persen < 0 || persen > 100) {
    showBanner("Persentase harus berupa angka antara 0-100.", true);
    return;
  }
  const { error } = await supabaseClient
    .from("mitra_digiprint")
    .update({ persentase_porsi_hmif: persen })
    .eq("id_mitra_digiprint", id);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Porsi HMIF diperbarui. Berlaku untuk transaksi baru mulai sekarang (transaksi lama tidak dihitung ulang).");
  await loadApprovalMitra();
}

async function setujuiMitra(id) {
  if (!window.confirm("Setujui pendaftaran mitra ini? Mitra akan langsung bisa mengakses Kasir.")) return;
  const { error } = await supabaseClient
    .from("mitra_digiprint")
    .update({
      status_pendaftaran: "Disetujui",
      status_aktif: true,
      diproses_oleh: state.session.user.id,
      diproses_pada: new Date().toISOString(),
    })
    .eq("id_mitra_digiprint", id);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Mitra disetujui.");
  await loadApprovalMitra();
}

async function tolakMitra(id) {
  const alasan = window.prompt("Alasan penolakan (opsional, akan terlihat oleh mitra):", "");
  if (alasan === null) return; // batal
  const { error } = await supabaseClient
    .from("mitra_digiprint")
    .update({
      status_pendaftaran: "Ditolak",
      status_aktif: false,
      catatan_penolakan: alasan || null,
      diproses_oleh: state.session.user.id,
      diproses_pada: new Date().toISOString(),
    })
    .eq("id_mitra_digiprint", id);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Pendaftaran mitra ditolak.");
  await loadApprovalMitra();
}

// ==============================================================
// 8. LAPORAN KEUANGAN
// ==============================================================

function statusBadge(row) {
  if (row.status_transaksi === "Dibatalkan") return '<span class="badge badge-batal">Dibatalkan</span>';
  return row.status_setoran === "Lunas"
    ? '<span class="badge badge-lunas">Lunas</span>'
    : '<span class="badge badge-pending">Pending</span>';
}

// Membatalkan transaksi lewat RPC (mitra: hanya milik sendiri & masih
// Pending; Admin: siapa saja). Stok dikembalikan otomatis oleh trigger.
async function batalkanTransaksi(id_transaksi, onDone) {
  const alasan = window.prompt("Alasan pembatalan (opsional):", "");
  if (alasan === null) return; // batal
  const { error } = await supabaseClient.rpc("batalkan_transaksi_digiprint", {
    p_id_transaksi: id_transaksi,
    p_alasan: alasan || null,
  });
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Transaksi dibatalkan, stok telah dikembalikan.");
  if (onDone) await onDone();
}

function currentDateRange() {
  const dari = $("input-laporan-dari").value;
  const sampai = $("input-laporan-sampai").value;
  return {
    dariISO: dari ? new Date(dari + "T00:00:00").toISOString() : null,
    sampaiISO: sampai ? new Date(sampai + "T23:59:59").toISOString() : null,
  };
}

$("form-laporan-filter").addEventListener("submit", (e) => { e.preventDefault(); loadLaporan(); });
$("btn-laporan-reset").addEventListener("click", () => {
  $("input-laporan-dari").value = "";
  $("input-laporan-sampai").value = "";
  $("input-laporan-status").value = "semua";
  loadLaporan();
});

// Status transaksi bukan cuma satu kolom (status_setoran + status_transaksi
// digabung jadi 4 kondisi: pending/lunas/dibatalkan), jadi difilter di JS
// setelah data diambil -- lebih sederhana daripada query OR bertingkat.
function applyStatusFilter(rows) {
  const f = $("input-laporan-status").value;
  if (f === "dibatalkan") return rows.filter((r) => r.status_transaksi === "Dibatalkan");
  if (f === "internal") return rows.filter((r) => r.jenis_transaksi === "Pemakaian Internal HMIF");
  if (f === "pending") return rows.filter((r) => r.status_transaksi !== "Dibatalkan" && r.status_setoran === "Pending");
  if (f === "lunas") return rows.filter((r) => r.status_transaksi !== "Dibatalkan" && r.status_setoran === "Lunas");
  return rows; // "semua"
}

async function loadLaporan() {
  const { dariISO, sampaiISO } = currentDateRange();

  let query = supabaseClient
    .from("mitra_transaksi")
    .select(state.isAdmin
      ? "*, mitra_digiprint(nama_usaha)"
      : "*")
    .is("deleted_at", null)
    .order("dibuat_pada", { ascending: false });

  if (!state.isAdmin) query = query.eq("id_mitra_digiprint", state.mitra.id_mitra_digiprint);
  if (dariISO) query = query.gte("dibuat_pada", dariISO);
  if (sampaiISO) query = query.lte("dibuat_pada", sampaiISO);

  const { data, error } = await query;
  if (error) { showBanner(friendlyError(error), true); return; }

  const filtered = applyStatusFilter(data);
  renderLaporanSummary(filtered);
  if (state.isAdmin) renderLaporanPerMitra(filtered);
  renderLaporanTabel(filtered);
}

function renderLaporanSummary(allRows) {
  const rows = allRows.filter((r) => r.status_transaksi !== "Dibatalkan");
  const sum = (key) => rows.reduce((acc, r) => acc + Number(r[key] || 0), 0);
  const belumSetor = rows
    .filter((r) => r.status_setoran === "Pending")
    .reduce((acc, r) => acc + Number(r.porsi_hmif || 0), 0);

  $("laporan-total-kotor").textContent = fmtRupiah.format(sum("total_kotor"));
  $("laporan-total-diskon").textContent = fmtRupiah.format(sum("nominal_diskon"));
  $("laporan-total-bersih").textContent = fmtRupiah.format(sum("total_bersih"));
  $("laporan-porsi-mitra").textContent = fmtRupiah.format(sum("porsi_mitra"));
  $("laporan-porsi-hmif").textContent = fmtRupiah.format(sum("porsi_hmif"));
  $("laporan-belum-setor").textContent = fmtRupiah.format(belumSetor);
}

function renderLaporanPerMitra(allRows) {
  const rows = allRows.filter((r) => r.status_transaksi !== "Dibatalkan");
  const byMitra = new Map();
  rows.forEach((r) => {
    const key = r.id_mitra_digiprint;
    const nama = r.mitra_digiprint?.nama_usaha || "(tidak diketahui)";
    if (!byMitra.has(key)) byMitra.set(key, { nama, bersih: 0, porsiHmif: 0, belumSetor: 0 });
    const acc = byMitra.get(key);
    acc.bersih += Number(r.total_bersih || 0);
    acc.porsiHmif += Number(r.porsi_hmif || 0);
    if (r.status_setoran === "Pending") acc.belumSetor += Number(r.porsi_hmif || 0);
  });

  const tbody = $("table-laporan-per-mitra-body");
  const entries = [...byMitra.values()];
  if (!entries.length) {
    tbody.innerHTML = `<tr><td colspan="4" class="empty-note">Tidak ada data.</td></tr>`;
    return;
  }
  tbody.innerHTML = entries.map((m) => `
    <tr>
      <td>${escapeHtml(m.nama)}</td>
      <td class="num">${fmtRupiah.format(m.bersih)}</td>
      <td class="num">${fmtRupiah.format(m.porsiHmif)}</td>
      <td class="num">${fmtRupiah.format(m.belumSetor)}</td>
    </tr>
  `).join("");
}

function renderLaporanTabel(rows) {
  const tbody = $("table-laporan-body");
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="9" class="empty-note">Tidak ada data.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r) => `
    <tr>
      <td>${fmtWaktu.format(new Date(r.dibuat_pada))}</td>
      <td class="th-mitra ${state.isAdmin ? "" : "hidden"}">${escapeHtml(r.mitra_digiprint?.nama_usaha || "—")}</td>
      <td>${r.jenis_transaksi === "Pemakaian Internal HMIF" ? '<span class="badge badge-off">Internal HMIF</span>' : "Penjualan"}</td>
      <td class="num">${fmtRupiah.format(r.total_kotor)}</td>
      <td class="num">${fmtRupiah.format(r.nominal_diskon)}</td>
      <td class="num">${fmtRupiah.format(r.total_bersih)}</td>
      <td class="num">${fmtRupiah.format(r.porsi_hmif)}</td>
      <td>${statusBadge(r)}</td>
      <td>${renderAksiLaporan(r)}</td>
    </tr>
  `).join("");

  tbody.querySelectorAll('[data-action="lunas"]').forEach((b) =>
    b.addEventListener("click", () => tandaiLunas(b.dataset.id)));
  tbody.querySelectorAll('[data-action="batal"]').forEach((b) =>
    b.addEventListener("click", () => batalkanTransaksi(b.dataset.id, loadLaporan)));
}

function renderAksiLaporan(r) {
  if (r.status_transaksi === "Dibatalkan") return "";
  let html = "";
  if (state.isAdmin && r.status_setoran === "Pending" && r.jenis_transaksi !== "Pemakaian Internal HMIF") {
    html += `<button type="button" class="btn-text" data-action="lunas" data-id="${r.id_transaksi}">Tandai Lunas</button> `;
  }
  // Admin boleh batalkan kapan saja (termasuk Lunas); mitra hanya kalau masih Pending
  if (state.isAdmin || r.status_setoran === "Pending") {
    html += `<button type="button" class="btn-danger-text" data-action="batal" data-id="${r.id_transaksi}">Batalkan</button>`;
  }
  return html;
}

async function tandaiLunas(id_transaksi) {
  if (!window.confirm("Tandai transaksi ini sebagai sudah disetor (Lunas)?")) return;
  const { error } = await supabaseClient
    .from("mitra_transaksi")
    .update({ status_setoran: "Lunas" })
    .eq("id_transaksi", id_transaksi);
  if (error) { showBanner(friendlyError(error), true); return; }
  showBanner("Status setoran diperbarui.");
  await loadLaporan();
}

// ==============================================================
// 9. UTIL
// ==============================================================
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ------------------------------------------------------------
init();
