/* JYV Oftalmología — main.js */
(function () {
  "use strict";

  /* ── Dual-upload validation ───────────────────────────────── */
  const uploadForm = document.getElementById("upload-form");
  if (uploadForm) {
    const inputOD   = document.getElementById("imagen_od");
    const inputOI   = document.getElementById("imagen_oi");
    const previewOD = document.getElementById("preview-od");
    const previewOI = document.getElementById("preview-oi");
    const submitBtn = document.getElementById("submit-upload");

    function checkBothFiles() {
      const ready = inputOD.files.length > 0 && inputOI.files.length > 0;
      submitBtn.disabled = !ready;
    }

    function showPreview(input, previewEl, zone) {
      const file = input.files[0];
      if (!file) return;
      const url = URL.createObjectURL(file);
      if (previewEl) {
        previewEl.src = url;
        previewEl.onload = () => URL.revokeObjectURL(url);
      }
      if (zone) zone.classList.add("has-file");
      checkBothFiles();
    }

    if (inputOD) {
      inputOD.addEventListener("change", () => {
        showPreview(inputOD, previewOD, inputOD.closest(".drop-zone"));
      });
    }
    if (inputOI) {
      inputOI.addEventListener("change", () => {
        showPreview(inputOI, previewOI, inputOI.closest(".drop-zone"));
      });
    }

    // Drag-and-drop visual feedback
    document.querySelectorAll(".drop-zone").forEach(zone => {
      zone.addEventListener("dragover", e => {
        e.preventDefault();
        zone.classList.add("drag-over");
      });
      zone.addEventListener("dragleave", () => zone.classList.remove("drag-over"));
      zone.addEventListener("drop", e => {
        e.preventDefault();
        zone.classList.remove("drag-over");
        const input = zone.querySelector("input[type=file]");
        if (input && e.dataTransfer.files.length) {
          input.files = e.dataTransfer.files;
          input.dispatchEvent(new Event("change"));
        }
      });
    });

    // Initial state
    checkBothFiles();
  }

  /* ── Confirmation modal (doctor actions) ─────────────────── */
  document.querySelectorAll("[data-modal]").forEach(trigger => {
    trigger.addEventListener("click", e => {
      e.preventDefault();
      const targetId = trigger.dataset.modal;
      const overlay  = document.getElementById(targetId);
      if (overlay) overlay.classList.add("open");
    });
  });

  document.querySelectorAll(".modal-close, .modal-overlay").forEach(el => {
    el.addEventListener("click", e => {
      if (e.target === el) {
        el.closest(".modal-overlay").classList.remove("open");
      }
    });
  });

  document.querySelectorAll(".modal").forEach(modal => {
    modal.addEventListener("click", e => e.stopPropagation());
  });

  // Close on Escape
  document.addEventListener("keydown", e => {
    if (e.key === "Escape") {
      document.querySelectorAll(".modal-overlay.open").forEach(o => {
        o.classList.remove("open");
      });
    }
  });

  /* ── Probability bar animation ───────────────────────────── */
  function animateBars() {
    document.querySelectorAll(".prob-bar[data-value]").forEach(bar => {
      const val = parseFloat(bar.dataset.value) || 0;
      requestAnimationFrame(() => {
        bar.style.width = (val * 100).toFixed(1) + "%";
      });
    });
  }

  if ("IntersectionObserver" in window) {
    const obs = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          animateBars();
          obs.disconnect();
        }
      });
    }, { threshold: 0.1 });

    const firstBar = document.querySelector(".prob-bar");
    if (firstBar) obs.observe(firstBar);
  } else {
    animateBars();
  }

  /* ── Auto-dismiss flash messages after 5 s ───────────────── */
  document.querySelectorAll(".flash[data-auto-dismiss]").forEach(flash => {
    setTimeout(() => {
      flash.style.transition = "opacity .4s";
      flash.style.opacity = "0";
      setTimeout(() => flash.remove(), 400);
    }, 5000);
  });

  /* ── Notification dropdown ───────────────────────────────── */
  const notifBtn    = document.getElementById("notif-btn");
  const notifPanel  = document.getElementById("notif-panel");
  const notifList   = document.getElementById("notif-list");
  const markAllBtn  = document.getElementById("notif-mark-all");
  const notifCount  = document.getElementById("notif-count");

  function escHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function getCsrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']");
    return meta ? meta.content : "";
  }

  function updateBadge(count) {
    if (!notifCount) return;
    notifCount.textContent = count;
    notifCount.hidden = count === 0;
    if (notifBtn) notifBtn.setAttribute("aria-label", `${count} notificaciones sin leer`);
  }

  function renderNotifs(notifs) {
    if (!notifs.length) {
      notifList.innerHTML = '<p class="notif-panel__empty">No tienes notificaciones.</p>';
      return;
    }
    notifList.innerHTML = notifs.map(n => `
      <a class="notif-item${n.leida ? " notif-item--read" : ""}"
         data-id="${n.id}" data-url="${escHtml(n.url)}" href="#">
        <span class="notif-item__dot" aria-hidden="true"></span>
        <span class="notif-item__body">
          <span class="notif-item__msg">${escHtml(n.mensaje)}</span>
          <span class="notif-item__time">${escHtml(n.creada_en)}</span>
        </span>
      </a>
    `).join("");

    notifList.querySelectorAll(".notif-item").forEach(item => {
      item.addEventListener("click", async e => {
        e.preventDefault();
        const id  = item.dataset.id;
        const url = item.dataset.url;
        try {
          await fetch(`/notif/${id}/leer`, {
            method: "POST",
            credentials: "same-origin",
            headers: { "X-CSRFToken": getCsrfToken() },
          });
        } catch (_) {}
        window.location.href = url;
      });
    });

    // Actualizar badge con no leídas
    const unread = notifs.filter(n => !n.leida).length;
    updateBadge(unread);
  }

  let panelLoaded = false;

  async function loadNotifs() {
    notifList.innerHTML = '<p class="notif-panel__empty">Cargando…</p>';
    try {
      const r = await fetch("/notif/lista", { credentials: "same-origin" });
      const d = await r.json();
      renderNotifs(d.notificaciones || []);
      panelLoaded = true;
    } catch (_) {
      notifList.innerHTML = '<p class="notif-panel__empty" style="color:var(--danger)">Error al cargar. Reintenta.</p>';
    }
  }

  function openPanel() {
    notifPanel.hidden = false;
    notifBtn.setAttribute("aria-expanded", "true");
    if (!panelLoaded) loadNotifs();
  }

  function closePanel() {
    notifPanel.hidden = true;
    notifBtn.setAttribute("aria-expanded", "false");
  }

  if (notifBtn && notifPanel) {
    notifBtn.addEventListener("click", e => {
      e.stopPropagation();
      notifPanel.hidden ? openPanel() : closePanel();
    });

    document.addEventListener("click", e => {
      if (!notifPanel.hidden && !notifPanel.contains(e.target) && e.target !== notifBtn) {
        closePanel();
      }
    });

    document.addEventListener("keydown", e => {
      if (e.key === "Escape" && !notifPanel.hidden) {
        closePanel();
        notifBtn.focus();
      }
    });
  }

  if (markAllBtn) {
    markAllBtn.addEventListener("click", async e => {
      e.stopPropagation();
      try {
        await fetch("/notif/leer-todas", {
          method: "POST",
          credentials: "same-origin",
          headers: { "X-CSRFToken": getCsrfToken() },
        });
      } catch (_) {}
      panelLoaded = false;
      loadNotifs();
    });
  }

  /* ── Notification badge polling (every 60 s, todos los roles) ── */
  if (notifCount) {
    const pollBadge = () => {
      fetch("/notif/count", { credentials: "same-origin" })
        .then(r => r.ok ? r.json() : null)
        .then(data => { if (data) updateBadge(data.count); })
        .catch(() => {});
    };
    setInterval(pollBadge, 60_000);
  }

  /* ── Toggle sidebar on mobile ─────────────────────────────── */
  const sidebarToggle = document.getElementById("sidebar-toggle");
  const sidebar = document.querySelector(".sidebar");
  if (sidebarToggle && sidebar) {
    sidebarToggle.addEventListener("click", () => {
      sidebar.classList.toggle("open");
    });
  }

  /* ── Form: prevent double-submit ─────────────────────────── */
  document.querySelectorAll("form.no-double-submit").forEach(form => {
    form.addEventListener("submit", () => {
      form.querySelectorAll("[type=submit]").forEach(btn => {
        btn.disabled = true;
        btn.textContent = "Procesando…";
      });
    });
  });
})();
