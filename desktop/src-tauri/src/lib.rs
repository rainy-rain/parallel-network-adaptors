use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::{AppHandle, Manager};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ==================== 数据结构 ====================

#[derive(Serialize, Clone, Debug)]
pub struct Link {
    pub index: usize,
    pub name: String,
    pub ip: String,
    pub gateway: String,
    pub metric: u32,
    pub physical: bool,
    pub egress: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct PlatformInfo {
    pub os: String,
    pub arch: String,
    pub scripts_dir: String,
    pub caddy_present: bool,
}

#[derive(Serialize, Clone, Debug)]
pub struct SplitStatus {
    pub running: bool,
    pub port: u16,
    pub pid: Option<u32>,
}

#[derive(Serialize, Clone, Debug)]
pub struct CmStatus {
    pub enabled: bool,
    pub pid: u32,
    pub listeners: u32,
    pub dcs: u32,
    pub hosts: bool,
}

#[derive(Serialize, Clone, Debug)]
pub struct SteamStatus {
    pub caddy: bool,
    pub hosts: bool,
    pub ca: bool,
    pub port443: bool,
    pub enabled: bool,
}

// ==================== 路径与脚本准备 ====================

/// 脚本落地目录：<app_data>/scripts
fn scripts_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let base = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("取应用数据目录失败：{e}"))?;
    let dir = base.join("scripts");
    std::fs::create_dir_all(&dir).map_err(|e| format!("建目录失败：{e}"))?;
    Ok(dir)
}

/// 把打包进 resources 的脚本复制到可写目录，仅当源更新时覆盖。
fn ensure_scripts(app: &AppHandle) -> Result<PathBuf, String> {
    let dst = scripts_dir(app)?;
    let res = app
        .path()
        .resource_dir()
        .map_err(|e| format!("取资源目录失败：{e}"))?;

    // Tauri v2 的 NSIS 安装器把 resources 放在 <install>/_up_/resources，
    // macOS 的 .app 在 Contents/Resources，dev 模式在 target/debug。
    // 这里把常见落点全列出来，再补一层「resource_dir 下所有子目录」的兜底，
    // 否则安装后脚本目录是空的，点任何按钮都会报「脚本缺失」。
    let mut candidates: Vec<PathBuf> = vec![
        res.clone(),
        res.join("resources"),
        res.join("_up_"),
        res.join("_up_").join("resources"),
        res.join("Resources"),
    ];
    if let Ok(rd) = std::fs::read_dir(&res) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                candidates.push(p.join("resources"));
                candidates.push(p.clone());
            }
        }
    }

    let mut names: Vec<&str> = vec![
        "split-proxy.ps1",
        "multi-fetch.ps1",
        "SteamProxy.ps1",
        "Caddyfile",
        "split-proxy.py",
        "multi-fetch.sh",
        "SteamProxy.sh",
        "cm-splitter.ps1",
        "CmSplitter.cs",
    ];
    // caddy 二进制随包分发，运行时释放到脚本目录
    #[cfg(windows)]
    names.push("caddy.exe");
    #[cfg(not(windows))]
    names.push("caddy");

    for name in names {
        let mut src: Option<PathBuf> = None;
        for c in &candidates {
            let p = c.join(name);
            if p.is_file() {
                src = Some(p);
                break;
            }
        }
        let Some(src) = src else { continue };
        let target = dst.join(name);

        let need_copy = match (std::fs::metadata(&src), std::fs::metadata(&target)) {
            (Ok(a), Ok(b)) => match (a.modified().ok(), b.modified().ok()) {
                (Some(ta), Some(tb)) => ta > tb,
                _ => true,
            },
            (Ok(_), Err(_)) => true,
            _ => false,
        };

        if need_copy {
            std::fs::copy(&src, &target)
                .map_err(|e| format!("复制 {name} 失败：{e}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755));
            }
        }
    }

    Ok(dst)
}

/// 在脚本目录里找 caddy 可执行文件（安装器可把它放在这里）。
fn caddy_path(dir: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        let p = dir.join("caddy.exe");
        if p.exists() {
            return p;
        }
        PathBuf::from("caddy.exe")
    }
    #[cfg(not(windows))]
    {
        let p = dir.join("caddy");
        if p.exists() {
            return p;
        }
        PathBuf::from("caddy")
    }
}

// ==================== 统一执行入口 ====================

/// Windows PowerShell 5.1 默认按系统 ANSI 写 stdout/stderr（中文机器是 GBK 936），
/// 而这里一直按 UTF-8 读，于是「网关 / 度量 / 物理 / 出口」全变成乱码，
/// parse_links 一条都解析不出来。先试 UTF-8，不合法再退回 GBK。
fn decode_output(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => {
            let (cow, _, _) = encoding_rs::GBK.decode(bytes);
            cow.into_owned()
        }
    }
}
fn run_in(dir: &Path, program: &Path, args: &[&str], extra_env: &[(&str, &str)]) -> Result<String, String> {
    let mut cmd = Command::new(program);
    cmd.args(args).current_dir(dir);

    // 去掉会把本地请求带去外部代理的环境变量
    for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
        cmd.env_remove(k);
    }
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    cmd.env("NO_PROXY", "*");
    cmd.env("no_proxy", "*");

    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let out = cmd
        .output()
        .map_err(|e| format!("启动进程失败：{e}"))?;

    let stdout = decode_output(&out.stdout);
    let stderr = decode_output(&out.stderr);

    if out.status.success() {
        Ok(if stderr.trim().is_empty() {
            stdout
        } else {
            format!("{stdout}\n{stderr}")
        })
    } else {
        Err(format!(
            "退出码 {:?}\n{}{}",
            out.status.code(),
            stdout,
            stderr
        ))
    }
}

/// 调脚本：按扩展名选解释器
fn run_script(app: &AppHandle, name: &str, args: &[&str]) -> Result<String, String> {
    let dir = ensure_scripts(app)?;
    let script = dir.join(name);
    if !script.is_file() {
        return Err(format!("脚本缺失：{}", script.display()));
    }

    #[cfg(windows)]
    {
        let _ = script;
        let args_owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let mut a: Vec<&str> = vec!["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"];
        let script_s = dir.join(name).to_string_lossy().to_string();
        a.push(&script_s);
        for x in &args_owned {
            a.push(x.as_str());
        }
        let ps = PathBuf::from("powershell.exe");
        run_in(&dir, &ps, &a, &[])
    }

    #[cfg(not(windows))]
    {
        let (program, mut a): (PathBuf, Vec<String>) = if name.ends_with(".py") {
            (PathBuf::from("/usr/bin/python3"), vec![])
        } else {
            (PathBuf::from("/bin/bash"), vec![])
        };
        let script_s = dir.join(name).to_string_lossy().to_string();
        a.push(script_s);
        for x in args {
            a.push((*x).to_string());
        }
        let refs: Vec<&str> = a.iter().map(|s| s.as_str()).collect();
        run_in(&dir, &program, &refs, &[])
    }
}

// ==================== 链路解析 ====================

fn parse_links(output: &str) -> Vec<Link> {
    let mut out = Vec::new();
    for line in output.lines() {
        let t = line.trim();
        if !t.starts_with('[') {
            continue;
        }
        // 形如：[1] Wi-Fi   10.66.82.96  网关 10.66.80.1  度量 35  物理 | 出口 校园网
        let Some(rb) = t.find(']') else { continue };
        let Ok(index) = t[1..rb].trim().parse::<usize>() else { continue };
        let rest = t[rb + 1..].trim();

        let Some(gw_pos) = rest.find("网关") else { continue };
        let left = rest[..gw_pos].trim();
        let after_gw = rest[gw_pos + "网关".len()..].trim();

        let mut lparts = left.split_whitespace();
        let name = lparts.next().unwrap_or("").to_string();
        let ip = lparts.next().unwrap_or("").to_string();

        let mut parts = after_gw.split_whitespace();
        let gateway = parts.next().unwrap_or("").to_string();

        // 找 "度量 N"
        let mut metric: u32 = 0;
        let mut idx_metric = None;
        let tokens: Vec<&str> = parts.collect();
        for (i, tok) in tokens.iter().enumerate() {
            if *tok == "度量" {
                if let Some(v) = tokens.get(i + 1) {
                    metric = v.parse().unwrap_or(0);
                    idx_metric = Some(i + 1);
                }
                break;
            }
        }
        let start = idx_metric.map(|i| i + 1).unwrap_or(0);
        let tail = tokens.get(start..).unwrap_or(&[]);
        let physical = tail.first().map(|s| *s == "物理").unwrap_or(true);

        let egress = tail
            .iter()
            .position(|s| *s == "出口")
            .and_then(|i| tail.get(i + 1))
            .map(|s| s.to_string())
            .unwrap_or_else(|| "未知".to_string());

        if name.is_empty() || ip.is_empty() {
            continue;
        }

        out.push(Link {
            index,
            name,
            ip,
            gateway,
            metric,
            physical,
            egress,
        });
    }
    out
}

/// 从 `Key：Value` 形式的状态行里取值
#[allow(dead_code)]
fn pick<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    for line in text.lines() {
        let t = line.trim_start_matches(|c: char| c.is_ascii_digit() || c == '[' || c == ']' || c == ':' || c == ' ');
        let t = t.trim_start_matches(']').trim();
        if let Some(rest) = t.strip_prefix(key) {
            let rest = rest.trim_start_matches(['：', ':']).trim();
            if !rest.is_empty() {
                return Some(rest);
            }
        }
    }
    None
}

#[allow(dead_code)]
fn yes(v: Option<&str>) -> bool {
    match v {
        Some(s) => {
            s.contains('是') || s.starts_with("已") || s.contains("运行中") || s.contains("True")
        }
        None => false,
    }
}

// ==================== 命令：平台信息 ====================

#[tauri::command]
async fn platform_info(app: AppHandle) -> Result<PlatformInfo, String> {
    let dir = scripts_dir(&app)?;
    let caddy = caddy_path(&dir);
    let caddy_present = caddy.is_file()
        || Command::new(&caddy)
            .arg("version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

    Ok(PlatformInfo {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        scripts_dir: dir.to_string_lossy().to_string(),
        caddy_present,
    })
}

// ==================== 命令：链路 ====================

#[tauri::command]
async fn list_links(app: AppHandle) -> Result<Vec<Link>, String> {
    #[cfg(windows)]
    let raw = run_script(&app, "split-proxy.ps1", &["-List"])?;
    #[cfg(not(windows))]
    let raw = run_script(&app, "split-proxy.py", &["--list"])?;

    Ok(parse_links(&raw))
}

#[tauri::command]
async fn probe_links(app: AppHandle) -> Result<String, String> {
    #[cfg(windows)]
    {
        run_script(&app, "split-proxy.ps1", &["-SelfTest"])
    }
    #[cfg(not(windows))]
    {
        run_script(&app, "split-proxy.py", &["--probe"])
    }
}

// ==================== 命令：分流器 ====================

#[cfg(windows)]
fn find_split_pid() -> Option<u32> {
    let out = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            "@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*split-proxy.ps1*' -and $_.CommandLine -notlike '*Where-Object*' } | Select-Object -First 1 -ExpandProperty ProcessId)",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    s.trim().parse::<u32>().ok()
}

#[cfg(not(windows))]
fn find_split_pid() -> Option<u32> {
    let out = Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    for line in s.lines() {
        if line.contains("split-proxy.py") && !line.contains("grep") && !line.contains("ps -axo") {
            let pid = line.trim().split_whitespace().next()?;
            if let Ok(p) = pid.parse::<u32>() {
                return Some(p);
            }
        }
    }
    None
}

#[tauri::command]
async fn split_status(app: AppHandle) -> Result<SplitStatus, String> {
    let _ = app;
    let pid = find_split_pid();
    Ok(SplitStatus {
        running: pid.is_some(),
        port: 1080,
        pid,
    })
}

#[tauri::command]
async fn split_start(app: AppHandle, port: u16) -> Result<String, String> {
    if find_split_pid().is_some() {
        return Ok("分流器已在运行".to_string());
    }
    let dir = ensure_scripts(&app)?;
    let port_s = port.to_string();

    #[cfg(windows)]
    {
        let script = dir.join("split-proxy.ps1").to_string_lossy().to_string();
        // 用 Start-Process 脱离父进程，避免 Tauri 退出时把分流器带走
        let cmdline = format!(
            "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','{}','-Port','{}' -WindowStyle Hidden",
            script, port_s
        );
        run_in(
            &dir,
            Path::new("powershell.exe"),
            &["-NoProfile", "-Command", &cmdline],
            &[],
        )?;
    }

    #[cfg(not(windows))]
    {
        let script = dir.join("split-proxy.py").to_string_lossy().to_string();
        let log = dir.join("split-proxy.log");
        let log_s = log.to_string_lossy().to_string();
        // nohup + & 脱离 Tauri 生命周期
        let sh = format!(
            "nohup /usr/bin/python3 '{}' --port {} >> '{}' 2>&1 & echo $!",
            script, port_s, log_s
        );
        run_in(&dir, Path::new("/bin/sh"), &["-c", &sh], &[])?;
    }

    // 等端口起来
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(400));
        if find_split_pid().is_some() {
            return Ok(format!("分流器已启动，端口 {port}"));
        }
    }
    Err("启动超时，请查看日志".to_string())
}

#[tauri::command]
async fn split_stop(app: AppHandle) -> Result<String, String> {
    let _ = app;
    let Some(pid) = find_split_pid() else {
        return Ok("分流器未在运行".to_string());
    };

    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }
    #[cfg(not(windows))]
    {
        let _ = Command::new("/bin/kill").args(["-TERM", &pid.to_string()]).output();
    }

    for _ in 0..20 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        if find_split_pid().is_none() {
            return Ok(format!("已停止分流器（PID {pid}）"));
        }
    }
    Err(format!("停止超时，PID {pid} 可能仍在运行"))
}

// ==================== 命令：Steam 社区直连 ====================

#[cfg(windows)]
#[allow(dead_code)]
fn port_listening(port: u16) -> bool {
    let out = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "if (@(Get-NetTCPConnection -LocalPort {} -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {{ 1 }} else {{ 0 }}",
                port
            ),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim() == "1",
        Err(_) => false,
    }
}

#[cfg(not(windows))]
#[allow(dead_code)]
fn port_listening(port: u16) -> bool {
    let out = Command::new("/usr/sbin/lsof")
        .args(["-nP", &format!("-iTCP:{}", port), "-sTCP:LISTEN"])
        .output();
    match out {
        Ok(o) => o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty(),
        Err(_) => false,
    }
}

#[tauri::command]
async fn steam_status(app: AppHandle) -> Result<SteamStatus, String> {
    let _dir = ensure_scripts(&app)?;

    // hosts 是纯文件读取，直接读，不起进程
    let hosts = read_hosts().unwrap_or_default();
    let hosts_ok = hosts.contains("steamcommunity.com") && hosts.contains("127.0.0.1");

    // 进程 / 端口 / 根证书三项合并成一次 PowerShell，省掉两次 ~0.5s 的进程启动
    #[cfg(windows)]
    let (caddy, p443, ca) = steam_probe_all();

    #[cfg(not(windows))]
    let (caddy, p443, ca) = (
        find_caddy_pid().is_some(),
        port_listening(443),
        ca_trusted(std::path::Path::new("")),
    );

    Ok(SteamStatus {
        caddy,
        hosts: hosts_ok,
        ca,
        port443: p443,
        enabled: caddy && p443 && hosts_ok,
    })
}

/// 一次 PowerShell 取回三项状态，返回 (caddy 在跑, 443 在听, 根证书已装)
#[cfg(windows)]
fn steam_probe_all() -> (bool, bool, bool) {
    let script = r#"$c=@(Get-Process -Name caddy -ErrorAction SilentlyContinue).Count -gt 0; $p=@(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue).Count -gt 0; $a=@(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like '*Caddy Local Authority*' }).Count -gt 0; Write-Output "$c $p $a""#;
    let out = Command::new("powershell.exe")
        .args(["-NoProfile", "-Command", script])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match out {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stdout);
            let parts: Vec<&str> = s.split_whitespace().collect();
            (
                parts.first().map(|v| *v == "True").unwrap_or(false),
                parts.get(1).map(|v| *v == "True").unwrap_or(false),
                parts.get(2).map(|v| *v == "True").unwrap_or(false),
            )
        }
        Err(_) => (false, false, false),
    }
}

#[cfg(windows)]
#[allow(dead_code)]
fn find_caddy_pid() -> Option<u32> {
    let out = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            "@(Get-Process -Name caddy -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id)",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

#[cfg(not(windows))]
fn find_caddy_pid() -> Option<u32> {
    let out = Command::new("/usr/bin/pgrep").args(["-x", "caddy"]).output().ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()?
        .trim()
        .parse()
        .ok()
}

fn read_hosts() -> Result<String, String> {
    #[cfg(windows)]
    let path = PathBuf::from(std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into()))
        .join("System32\\drivers\\etc\\hosts");
    #[cfg(not(windows))]
    let path = PathBuf::from("/etc/hosts");

    std::fs::read_to_string(&path).map_err(|e| format!("读 hosts 失败：{e}"))
}

#[allow(dead_code)]
fn ca_trusted(_dir: &Path) -> bool {
    #[cfg(windows)]
    {
        let out = Command::new("powershell.exe")
            .args([
                "-NoProfile",
                "-Command",
                "@(Get-ChildItem Cert:\\LocalMachine\\Root | Where-Object { $_.Subject -like '*Caddy Local Authority*' }).Count",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
        matches!(out, Ok(o) if String::from_utf8_lossy(&o.stdout).trim() != "0")
    }
    #[cfg(not(windows))]
    {
        let _ = dir;
        let out = Command::new("/usr/bin/security")
            .args(["find-certificate", "-c", "Caddy Local Authority", "-a", "/Library/Keychains/System.keychain"])
            .output();
        matches!(out, Ok(o) if o.status.success())
    }
}

#[tauri::command]
async fn steam_enable(app: AppHandle) -> Result<String, String> {
    #[cfg(windows)]
    {
        run_script(&app, "SteamProxy.ps1", &["-EnableQuiet"])
    }
    #[cfg(not(windows))]
    {
        run_script(&app, "SteamProxy.sh", &["enable"])
    }
}

#[tauri::command]
async fn steam_disable(app: AppHandle) -> Result<String, String> {
    #[cfg(windows)]
    {
        run_script(&app, "SteamProxy.ps1", &["-DisableQuiet"])
    }
    #[cfg(not(windows))]
    {
        run_script(&app, "SteamProxy.sh", &["disable"])
    }
}

#[tauri::command]
async fn steam_test(app: AppHandle) -> Result<String, String> {
    #[cfg(windows)]
    {
        run_script(&app, "SteamProxy.ps1", &["-Test"])
    }
    #[cfg(not(windows))]
    {
        run_script(&app, "SteamProxy.sh", &["test"])
    }
}

// ==================== 命令：日志与下载 ====================

fn parse_cm(output: &str) -> CmStatus {
    let get = |k: &str| -> Option<String> {
        let prefix = format!("{k}=");
        output
            .lines()
            .find(|l| l.starts_with(&prefix))
            .map(|l| l[prefix.len()..].trim().to_string())
    };
    CmStatus {
        enabled: get("CM_ENABLED").map(|v| v == "1").unwrap_or(false),
        pid: get("CM_PID").and_then(|v| v.parse().ok()).unwrap_or(0),
        listeners: get("CM_LISTENERS").and_then(|v| v.parse().ok()).unwrap_or(0),
        dcs: get("CM_DC").and_then(|v| v.parse().ok()).unwrap_or(0),
        hosts: get("CM_HOSTS").map(|v| v == "1").unwrap_or(false),
    }
}

#[tauri::command]
async fn cm_status(app: AppHandle) -> Result<CmStatus, String> {
    if !cfg!(windows) {
        return Ok(CmStatus { enabled: false, pid: 0, listeners: 0, dcs: 0, hosts: false });
    }
    let out = run_script(&app, "cm-splitter.ps1", &["-Action", "status"])?;
    Ok(parse_cm(&out))
}

#[tauri::command]
async fn cm_enable(app: AppHandle) -> Result<String, String> {
    if !cfg!(windows) {
        return Err("CM 直连中继目前仅支持 Windows".into());
    }
    run_script(&app, "cm-splitter.ps1", &["-Action", "enable"])
}

#[tauri::command]
async fn cm_disable(app: AppHandle) -> Result<String, String> {
    if !cfg!(windows) {
        return Ok("已跳过（非 Windows）".into());
    }
    run_script(&app, "cm-splitter.ps1", &["-Action", "disable"])
}

#[tauri::command]
async fn cm_test(app: AppHandle) -> Result<String, String> {
    if !cfg!(windows) {
        return Err("CM 直连中继目前仅支持 Windows".into());
    }
    run_script(&app, "cm-splitter.ps1", &["-Action", "test"])
}
#[tauri::command]
async fn read_log(app: AppHandle, kind: String, tail: usize) -> Result<String, String> {
    let dir = ensure_scripts(&app)?;
    let name = match kind.as_str() {
        "split" => {
            #[cfg(windows)]
            {
                String::from("split-proxy.log")
            }
            #[cfg(not(windows))]
            {
                String::from("split-proxy.log")
            }
        }
        "cm" => String::from("cm-splitter.log"),
        _ => String::from("access.log"),
    };
    let p = dir.join(&name);
    if !p.is_file() {
        return Ok(String::new());
    }
    let text = std::fs::read_to_string(&p).map_err(|e| format!("读日志失败：{e}"))?;
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(tail);
    Ok(lines[start..].join("\n"))
}

#[tauri::command]
async fn open_path(app: AppHandle, kind: String) -> Result<(), String> {
    let dir = ensure_scripts(&app)?;
    #[cfg(windows)]
    {
        let target = match kind.as_str() {
            "dir" => dir.clone(),
            "split" => dir.join("split-proxy.log"),
            "cm" => dir.join("cm-splitter.log"),
            _ => dir.join("access.log"),
        };
        let target = if target.exists() {
            target
        } else {
            dir
        };
        Command::new("explorer")
            .arg(target)
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| format!("打开失败：{e}"))?;
    }
    #[cfg(not(windows))]
    {
        let target = match kind.as_str() {
            "split" => dir.join("split-proxy.log"),
            _ => dir.clone(),
        };
        Command::new("/usr/bin/open")
            .arg(target)
            .spawn()
            .map_err(|e| format!("打开失败：{e}"))?;
    }
    Ok(())
}

#[tauri::command]
async fn download_test(app: AppHandle, url: String, threads: u32, chunk_mb: u32) -> Result<String, String> {
    #[cfg(windows)]
    {
        let t = threads.to_string();
        let c = chunk_mb.to_string();
        let port = "1080";
        run_script(
            &app,
            "multi-fetch.ps1",
            &["-Url", &url, "-Threads", &t, "-ChunkMB", &c, "-Proxy", port],
        )
    }
    #[cfg(not(windows))]
    {
        let t = threads.to_string();
        let c = chunk_mb.to_string();
        run_script(
            &app,
            "multi-fetch.sh",
            &["--url", &url, "--threads", &t, "--chunk-mb", &c, "--proxy", "127.0.0.1:1080"],
        )
    }
}

// ==================== 入口 ====================

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            platform_info,
            list_links,
            probe_links,
            split_status,
            split_start,
            split_stop,
            steam_status,
            steam_enable,
            steam_disable,
            steam_test,
            read_log,
            open_path,
            download_test,
        cm_status,
        cm_enable,
        cm_disable,
        cm_test,
    ])
        .run(tauri::generate_context!())
        .expect("启动 Tauri 应用失败");
}
