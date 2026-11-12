import { invoke } from "@tauri-apps/api/core";

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

const isWindows = navigator.userAgent.includes("Windows");

// ==================== 日志 ====================

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function log(pane, text, level = "") {
  const el = pane === "steam" ? $("#log-steam") : $("#log-adapters");
  const cls = level ? ` class="l-${level}"` : "";
  for (const line of String(text).split("\n")) {
    if (!line.trim()) continue;
    el.insertAdjacentHTML(
      "beforeend",
      `<span${cls}>[${stamp()}] ${escapeHtml(line)}</span>\n`
    );
  }
  el.scrollTop = el.scrollHeight;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function status(msg) {
  $("#status-msg").textContent = msg;
}

function busy(btn, on) {
  if (!btn) return;
  btn.disabled = on;
  btn.classList.toggle("busy", on);
}

// ==================== Tab ====================

$$(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    $$(".tab").forEach((t) => t.classList.toggle("active", t === tab));
    $$(".pane").forEach((p) => p.classList.toggle("active", p.id === `pane-${tab.dataset.tab}`));
  });
});

// ==================== 平台 ====================

async function loadPlatform() {
  try {
    const p = await invoke("platform_info");
    $("#platform-tag").textContent = `${p.os} / ${p.arch}`;
    if (!p.caddy_present) {
      log("steam", "提示：未找到 caddy 可执行文件，Steam 社区直连需要它。", "warn");
    }
  } catch (e) {
    log("adapters", `平台信息读取失败：${e}`, "err");
  }
}

// ==================== 链路 ====================

function renderLinks(links) {
  const tbody = $("#links-body");
  $("#link-count").textContent = links.length;

  if (!links.length) {
    tbody.innerHTML = `<tr class="empty-row"><td colspan="7">没有检测到满足条件的链路（需 Up 状态 + 有 IPv4 + 有默认网关）</td></tr>`;
    $("#link-hint").textContent = "点「重新检测」重试";
    return;
  }

  tbody.innerHTML = links
    .map(
      (l) => `
      <tr>
        <td>${l.index}</td>
        <td>${escapeHtml(l.name)}</td>
        <td>${escapeHtml(l.ip)}</td>
        <td>${escapeHtml(l.gateway)}</td>
        <td>${l.metric}</td>
        <td><span class="tag ${l.physical ? "phys" : "virt"}">${l.physical ? "物理" : "虚拟"}</span></td>
        <td>${escapeHtml(l.egress)}</td>
      </tr>`
    )
    .join("");

  $("#link-hint").textContent =
    links.length >= 2
      ? `${links.length} 条链路，可叠加带宽`
      : "只有 1 条链路：分流器能跑，但带宽不会叠加";
}

async function detectLinks(btn) {
  busy(btn, true);
  status("正在枚举链路…");
  try {
    const links = await invoke("list_links");
    renderLinks(links);
    log("adapters", `检测到 ${links.length} 条链路`, links.length ? "ok" : "warn");
    links.forEach((l) =>
      log("adapters", `  [${l.index}] ${l.name}  ${l.ip}  网关 ${l.gateway}  度量 ${l.metric}  ${l.physical ? "物理" : "虚拟"} | 出口 ${l.egress}`)
    );
    status("就绪");
  } catch (e) {
    log("adapters", `枚举失败：${e}`, "err");
    status("枚举失败");
  } finally {
    busy(btn, false);
  }
}

async function probeLinks(btn) {
  busy(btn, true);
  status("正在自检…");
  log("adapters", "--- 链路自检（下载 500KB / 条）---", "dim");
  try {
    const out = await invoke("probe_links");
    log("adapters", out);
    status("自检完成");
  } catch (e) {
    log("adapters", `自检失败：${e}`, "err");
    status("自检失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== 分流器 ====================

function renderSplit(st) {
  const dot = $("#split-dot");
  dot.className = "dot " + (st.running ? "on" : "off");
  $("#split-state").textContent = st.running ? "运行中" : "未运行";
  $("#split-meta").textContent = st.pid
    ? `端口 ${st.port} · PID ${st.pid}`
    : `端口 ${st.port} · 模式 split`;
}

async function refreshSplit() {
  try {
    renderSplit(await invoke("split_status"));
  } catch (e) {
    log("adapters", `状态读取失败：${e}`, "err");
  }
}

async function startSplit(btn) {
  busy(btn, true);
  status("正在启动分流器…");
  try {
    const msg = await invoke("split_start", { port: 1080 });
    log("adapters", msg, "ok");
    renderSplit({ running: true, port: 1080 });
    status("分流器已启动");
  } catch (e) {
    log("adapters", `启动失败：${e}`, "err");
    status("启动失败");
  } finally {
    busy(btn, false);
  }
}

async function stopSplit(btn) {
  busy(btn, true);
  status("正在停止分流器…");
  try {
    const msg = await invoke("split_stop");
    log("adapters", msg, "ok");
    renderSplit({ running: false, port: 1080 });
    status("分流器已停止");
  } catch (e) {
    log("adapters", `停止失败：${e}`, "err");
    status("停止失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== Steam ====================

function mark(id, ok, label) {
  const el = $(id);
  el.textContent = `${label}：${ok ? "就绪" : "未就绪"}`;
  el.parentElement.className = ok ? "ok" : "off";
}

function renderSteam(st) {
  mark("#st-caddy", st.caddy, "Caddy");
  mark("#st-hosts", st.hosts, "hosts");
  mark("#st-ca", st.ca, "根证书");
  mark("#st-port", st.port443, "443 端口");

  const dot = $("#steam-dot");
  if (st.enabled) {
    dot.className = "dot on";
    $("#steam-state").textContent = "已开启";
    $("#steam-meta").textContent = "社区门户已指向本机反代";
  } else if (st.caddy || st.hosts) {
    dot.className = "dot warn";
    $("#steam-state").textContent = "部分就绪";
    $("#steam-meta").textContent = "状态不一致，可再点一次「开启」修正";
  } else {
    dot.className = "dot off";
    $("#steam-state").textContent = "未开启";
    $("#steam-meta").textContent = "本机终结 TLS，再转发到 Valve 白名单域名";
  }
}

async function refreshSteam() {
  try {
    renderSteam(await invoke("steam_status"));
  } catch (e) {
    log("steam", `状态读取失败：${e}`, "err");
  }
}

async function steamAction(btn, cmd, arg, label) {
  busy(btn, true);
  status(`正在${label}…`);
  log("steam", `--- ${label} ---`, "dim");
  try {
    const out = await invoke(cmd, arg);
    if (out && out.trim()) log("steam", out);
    log("steam", `${label}完成`, "ok");
    status(`${label}完成`);
    await refreshSteam();
  } catch (e) {
    log("steam", `${label}失败：${e}`, "err");
    status(`${label}失败`);
  } finally {
    busy(btn, false);
  }
}

// ==================== 日志 / 下载 ====================

async function pullLog(kind) {
  try {
    const text = await invoke("read_log", { kind, tail: 200 });
    if (!text) {
      log(kind === "split" ? "adapters" : "steam", "日志为空", "dim");
      return;
    }
    log(kind === "split" ? "adapters" : "steam", text);
  } catch (e) {
    log("adapters", `读日志失败：${e}`, "err");
  }
}

async function openLog(kind) {
  try {
    await invoke("open_path", { kind });
  } catch (e) {
    log("adapters", `打开失败：${e}`, "err");
  }
}

async function runDownload(btn) {
  const url = prompt(
    "多线程下载测试\n\n留空则用默认镜像（约 20MB）：",
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz"
  );
  if (!url) return;
  const threads = Number($("#threads").value) || 16;
  const chunk = Number($("#chunk").value) || 4;
  busy(btn, true);
  status("正在下载…");
  log("adapters", `--- 下载 ${url}（${threads} 线程 / ${chunk} MB 分片）---`, "dim");
  try {
    const out = await invoke("download_test", { url, threads, chunkMb: chunk });
    log("adapters", out);
    status("下载完成");
  } catch (e) {
    log("adapters", `下载失败：${e}`, "err");
    status("下载失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== 事件绑定 ====================

$("#btn-detect").addEventListener("click", (e) => detectLinks(e.currentTarget));
$("#btn-probe").addEventListener("click", (e) => probeLinks(e.currentTarget));
$("#btn-split-start").addEventListener("click", (e) => startSplit(e.currentTarget));
$("#btn-split-stop").addEventListener("click", (e) => stopSplit(e.currentTarget));
$("#btn-download").addEventListener("click", (e) => runDownload(e.currentTarget));

$("#btn-steam-enable").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_enable", undefined, "开启社区直连")
);
$("#btn-steam-disable").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_disable", undefined, "关闭社区直连")
);
$("#btn-steam-test").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_test", undefined, "自检")
);

$("#btn-steam-log").addEventListener("click", () => openLog("steam"));
$("#btn-clear-log").addEventListener("click", () => ($("#log-adapters").textContent = ""));
$("#btn-clear-steam-log").addEventListener("click", () => ($("#log-steam").textContent = ""));

$$("[data-open-log]").forEach((b) =>
  b.addEventListener("click", () => openLog(b.dataset.openLog))
);

$("#btn-refresh-all").addEventListener("click", async () => {
  await Promise.all([refreshSplit(), refreshSteam()]);
  status("状态已刷新");
});

// ==================== 启动 ====================

(async function init() {
  log("adapters", `平台：${isWindows ? "Windows" : "macOS / Unix"}`, "dim");
  await loadPlatform();
  await detectLinks($("#btn-detect"));
  await refreshSplit();
  await refreshSteam();
  status("就绪");

  // 状态轮询
  setInterval(refreshSplit, 5000);
  setInterval(refreshSteam, 8000);
})();
