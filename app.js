(() => {
  const $ = (selector, parent = document) => parent.querySelector(selector);
  const pairsElement = $("#pairs");
  const overlay = $("#overlay");
  const dialogElement = $("#dialog");
  const notice = $("#notice");
  const requests = new Map();
  let requestNumber = 0;
  let pairs = [];
  let firstRender = true;
  let skillInfo = new Map();
  let pendingSkillsPair = null;
  let query = "";

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);

  function summarizeSkills(items) {
    const total = items.length;
    const active = items.filter(item => /quản lý/.test(item.state || "")).length;
    const kept = items.filter(item => /giữ nguyên/.test(item.state || "")).length;
    return { total, active, kept };
  }

  function request(action, fields = {}) {
    if (!window.chrome?.webview) {
      return Promise.reject(new Error("Không tìm thấy kết nối WebView2."));
    }
    const requestId = `r${++requestNumber}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        requests.delete(requestId);
        reject(new Error("Ứng dụng không nhận được phản hồi. Hãy đóng rồi mở lại và thử lần nữa."));
      }, 15000);
      requests.set(requestId, { resolve, reject, timer });
      window.chrome.webview.postMessage({ requestId, action, ...fields });
    });
  }

  function render() {
    const activeCount = pairs.filter(pair => pair.on).length;
    const statOn = $("#stat-on");
    const statAll = $("#stat-all");
    if (statOn) statOn.textContent = String(activeCount);
    if (statAll) statAll.textContent = String(pairs.length);
    const searchRow = $("#search-row");
    if (searchRow) searchRow.hidden = pairs.length === 0;
    if (!pairs.length) {
      pairsElement.innerHTML = `
        <div class="empty">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.5.5l2.5-2.5a5 5 0 0 0-7-7l-1.5 1.5"/><path d="M14 11a5 5 0 0 0-7.5-.5L4 13a5 5 0 0 0 7 7l1.5-1.5"/></svg>
          <strong>Chưa có Junction nào</strong>
          <span>Tạo Junction đầu tiên để đồng bộ thư mục Skills.</span>
        </div>`;
      return;
    }
    const visible = query
      ? pairs.filter(pair => `${pair.name} ${pair.group}`.toLowerCase().includes(query))
      : pairs;
    if (!visible.length) {
      pairsElement.innerHTML = '<div class="empty"><span>Không có Junction nào khớp từ khóa tìm kiếm.</span></div>';
      return;
    }
    pairsElement.classList.toggle("steady", !firstRender);
    firstRender = false;
    pairsElement.innerHTML = visible.map(pair => renderCard(pair)).join("");
  }

  function renderCard(pair) {
    const info = skillInfo.get(pair.id);
    const meta = info
      ? (info.total === 0
          ? '<span class="meta-chip">Thư mục nguồn rỗng</span>'
          : `<span class="meta-chip${info.active ? " on" : ""}">${info.active}/${info.total} skills</span>` +
            `<span class="mini-bar" aria-hidden="true"><span style="width:${Math.round((info.active / info.total) * 100)}%"></span></span>` +
            (info.kept ? `<span class="meta-chip warn">${info.kept} giữ nguyên</span>` : ""))
      : '<span class="meta-chip">Đang đếm skills…</span>';
    const tools = path => `
      <div class="path-tools">
        <button class="button quiet mini" data-action="copy-path" data-path="${escapeHtml(path)}" aria-label="Sao chép đường dẫn"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button>
        <button class="button quiet mini" data-action="open" data-path="${escapeHtml(path)}" aria-label="Mở thư mục trong Explorer"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 14 1.5-2.9A2 2 0 0 1 9.2 10H20a2 2 0 0 1 1.9 2.6l-1.6 5a2 2 0 0 1-1.9 1.4H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.7.9l.8 1.2a2 2 0 0 0 1.7.9H18a2 2 0 0 1 2 2z"/></svg></button>
      </div>`;
    return `
      <article class="pair-card" data-state="${pair.on ? "on" : "off"}">
        <div class="pair-head">
          <div class="pair-title">
            <strong>${escapeHtml(pair.name)}</strong>
            <span class="badge">${escapeHtml(pair.group || "Skills dùng chung")}</span>
          </div>
          <div class="pair-actions">
            <button class="button quiet" data-action="skills" data-id="${escapeHtml(pair.id)}">Skills</button>
            <button class="button quiet" data-action="edit" data-id="${escapeHtml(pair.id)}">Sửa</button>
            <button class="button quiet icon danger" data-action="delete" data-id="${escapeHtml(pair.id)}" aria-label="Xóa cặp ${escapeHtml(pair.name)}">
              <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 6h12M8 6V4h4v2m2 0-.7 10H6.7L6 6m2.5 2v5m3-5v5"/></svg>
            </button>
            <button class="switch" type="button" role="switch" aria-checked="${pair.on ? "true" : "false"}" aria-label="Junction ${escapeHtml(pair.name)} · ${escapeHtml(pair.group)}" data-action="toggle" data-id="${escapeHtml(pair.id)}"></button>
          </div>
        </div>
        <div class="pair-meta">${meta}</div>
        <div class="paths">
          <div class="path"><span class="path-label">Nguồn</span><code title="${escapeHtml(pair.source)}">${escapeHtml(pair.source)}</code>${tools(pair.source)}</div>
          <div class="path"><span class="path-label">Đích</span><code title="${escapeHtml(pair.target)}">${escapeHtml(pair.target)}</code>${tools(pair.target)}</div>
        </div>
      </article>`;
  }

  function closeDialog() {
    overlay.hidden = true;
    dialogElement.replaceChildren();
  }

  function openDialog(title, body, dialogClass = "") {
    dialogElement.className = `dialog ${dialogClass}`.trim();
    dialogElement.innerHTML = `
      <div class="dialog-head"><h2 id="dialog-title">${escapeHtml(title)}</h2>
        <button class="button quiet icon" type="button" data-action="close" aria-label="Đóng"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7m0-7-7 7"/></svg></button></div>
      ${body}`;
    overlay.hidden = false;
    $("input,button", dialogElement)?.focus();
  }

  function showEdit(pair = null) {
    const value = key => escapeHtml(pair?.[key] ?? (key === "group" ? "Skills dùng chung" : ""));
    openDialog(pair ? "Sửa Junction" : "Tạo Junction", `
      <form class="form" id="edit-form" data-id="${escapeHtml(pair?.id ?? "")}">
        <label>Tên đích<input name="name" required maxlength="50" value="${value("name")}" placeholder="Ví dụ: Codex"></label>
        <label>Nhóm Skills<input name="group" maxlength="70" value="${value("group")}" placeholder="Ví dụ: Skills dùng chung"></label>
        <label>Thư mục Skills nguồn<div class="browse-row"><input name="source" required value="${value("source")}" placeholder="D:\\Vault\\Skills" spellcheck="false"><button class="button" type="button" data-action="browse" data-field="source">Duyệt…</button></div></label>
        <label>Thư mục Skills đích<div class="browse-row"><input name="target" required value="${value("target")}" placeholder="C:\\Users\\…\\skills" spellcheck="false"><button class="button" type="button" data-action="browse" data-field="target">Duyệt…</button></div></label>
        <p class="form-help">Mỗi thư mục Skills con sẽ thành một Junction riêng. Mục trùng tên đã có ở đích được giữ nguyên.</p>
        <p class="form-error" id="form-error" role="alert"></p>
        <div class="dialog-foot"><button class="button" type="button" data-action="close">Hủy</button><button class="button primary" type="submit">${pair ? "Lưu thay đổi" : "Tạo Junction"}</button></div>
      </form>`);
  }

  function showSkills(pair, items) {
    const states = new Map([
      ["Junction do ứng dụng quản lý", { label: "Đã liên kết", className: "linked" }],
      ["Chưa liên kết", { label: "Chưa liên kết", className: "unlinked" }],
      ["Đích đã có sẵn · giữ nguyên", { label: "Giữ nguyên", className: "kept" }]
    ]);
    const sortedItems = [...items].sort((a, b) => String(a.name ?? "").localeCompare(
      String(b.name ?? ""), "vi", { sensitivity: "base", numeric: true }
    ));
    const rows = sortedItems.map(item => {
      const state = states.get(item.state) ?? { label: item.state || "Không rõ", className: "unknown" };
      return `<li class="skill-row"><span class="skill-name">${escapeHtml(item.name)}</span>
        <span class="skill-state ${state.className}">${escapeHtml(state.label)}</span></li>`;
    }).join("");
    openDialog(`Skills · ${pair.name}`, `
      <div class="skills-context">
        <p class="dialog-copy">Nguồn: ${escapeHtml(pair.source)}</p>
        <p class="skills-count">${items.length} skills · Sắp xếp A–Z</p>
      </div>
      <div class="skills-scroll" tabindex="0" role="region" aria-label="Danh sách Skills">
        ${items.length ? `<ul class="skill-list">${rows}</ul>` : '<p class="skills-empty dialog-copy">Không tìm thấy thư mục Skills con.</p>'}
      </div>
      <div class="dialog-foot">
        <p class="skills-note">Đã liên kết: Junction do ứng dụng quản lý.<br>Giữ nguyên: mục có sẵn ở đích.</p>
        <button class="button primary" type="button" data-action="close">Đóng</button>
      </div>`, "skills-dialog");
  }

  function setPairs(nextPairs) {
    if (Array.isArray(nextPairs)) {
      pairs = nextPairs;
      render();
      for (const pair of pairs) request("skills", { id: pair.id }).catch(() => {});
    }
  }

  function setNotice(text, isError = false) {
    notice.textContent = text ?? "";
    notice.classList.toggle("error", Boolean(isError));
  }

  window.chrome.webview.addEventListener("message", event => {
    const response = event.data;
    const pending = requests.get(response.requestId);
    if (pending) {
      requests.delete(response.requestId);
      clearTimeout(pending.timer);
      if (response.ok) pending.resolve(response);
      else pending.reject(new Error(response.error || "Thao tác không thành công."));
    }
    if (Array.isArray(response.pairs)) setPairs(response.pairs);
    if (response.message) setNotice(response.message, !response.ok);
    if (response.error) setNotice(response.error, true);
    if (response.field && response.selectedPath) {
      const input = $(`[name="${CSS.escape(response.field)}"]`, dialogElement);
      if (input) input.value = response.selectedPath;
    }
    if (response.skills && response.pairId) {
      skillInfo.set(response.pairId, summarizeSkills(response.skills));
      render();
      if (pendingSkillsPair === response.pairId) {
        pendingSkillsPair = null;
        const pair = pairs.find(item => item.id === response.pairId);
        if (pair) showSkills(pair, response.skills);
      }
    }
  });

  document.addEventListener("click", async event => {
    const button = event.target.closest("[data-action]");
    if (!button) {
      if (event.target === overlay) closeDialog();
      return;
    }
    const { action, id, field } = button.dataset;
    const pair = pairs.find(item => item.id === id);
    try {
      if (action === "add") { setNotice(""); showEdit(); }
      else if (action === "close") closeDialog();
      else if (action === "edit" && pair) showEdit(pair);
      else if (action === "browse") {
        button.disabled = true;
        setNotice("Đang mở hộp thoại chọn thư mục…");
        await request("browse", { field });
        button.disabled = false;
        setNotice("");
      }
      else if (action === "toggle" && pair) {
        button.disabled = true;
        await request("toggle", { id, enabled: button.getAttribute("aria-checked") !== "true" });
        button.disabled = false;
      }
      else if (action === "skills" && pair) {
        pendingSkillsPair = id;
        await request("skills", { id });
      }
      else if (action === "copy-path") {
        const text = button.dataset.path || "";
        let copied = false;
        try {
          if (navigator.clipboard?.writeText) {
            await navigator.clipboard.writeText(text);
            copied = true;
          }
        } catch { }
        if (!copied) {
          const textarea = document.createElement("textarea");
          textarea.value = text;
          document.body.appendChild(textarea);
          textarea.select();
          document.execCommand("copy");
          textarea.remove();
        }
        setNotice("Đã sao chép đường dẫn.");
      }
      else if (action === "open") {
        await request("open", { path: button.dataset.path });
      }
      else if (action === "delete" && pair && confirm(`Xóa cấu hình Junction “${pair.name} · ${pair.group}”?`)) {
        await request("delete", { id });
      }
    } catch (error) {
      button.disabled = false;
      setNotice(error.message, true);
    }
  });

  document.addEventListener("submit", async event => {
    if (event.target.id !== "edit-form") return;
    event.preventDefault();
    const form = event.target;
    const data = Object.fromEntries(new FormData(form));
    const requestFields = { ...data, group: data.group || "Skills dùng chung" };
    try {
      const result = await request(form.dataset.id ? "edit" : "add", { id: form.dataset.id, ...requestFields });
      if (result.ok) closeDialog();
    } catch (error) {
      $("#form-error", form).textContent = error.message;
    }
  });

  document.addEventListener("keydown", event => { if (event.key === "Escape" && !overlay.hidden) closeDialog(); });

  $("#search")?.addEventListener("input", event => {
    query = event.target.value.trim().toLowerCase();
    if (pairs.length) render();
  });

  request("load").catch(error => setNotice(error.message, true));
})();
