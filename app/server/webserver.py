#!/usr/bin/env python3
# =========================================================
#  Traffic Keeper - Web 管理界面服务器
#  Version : 2.9.2
#  端口：默认 8080，可通过 .env 的 WEB_PORT 配置
# =========================================================
import http.server
import socketserver
import json
import os
import time
import threading
import re

ENV_FILE = os.environ.get("TK_ENV_FILE", "/app/.env")
LOG_FILE = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "console.log")

def get_web_port():
    env_port = os.environ.get("TK_WEB_PORT", "")
    if env_port.isdigit():
        return int(env_port)
    try:
        with open(ENV_FILE, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("WEB_PORT="):
                    val = line.split("=", 1)[1].strip()
                    if val.isdigit():
                        return int(val)
    except Exception:
        pass
    return 8080

def parse_env_lines():
    lines = []
    if not os.path.exists(ENV_FILE):
        return lines
    try:
        with open(ENV_FILE, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                lines.append(line.rstrip("\n"))
    except Exception:
        pass
    return lines

def env_to_dict():
    result = {}
    for line in parse_env_lines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        if key == "DOWNLOAD_URLS":
            value = value.replace(",", "\n")
        result[key] = value
    return result

def write_env(config_dict):
    quoted_keys = {"USER_AGENT", "DOWNLOAD_URLS"}
    existing_lines = parse_env_lines()
    written = set()
    new_lines = []

    for line in existing_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        if "=" not in stripped:
            new_lines.append(line)
            continue
        key, _, _ = stripped.partition("=")
        key = key.strip()
        if key in config_dict:
            val = config_dict[key]
            if key == "DOWNLOAD_URLS":
                val = val.replace("\n", ",")
            if key in quoted_keys or " " in val or "," in val:
                if '"' not in val:
                    new_lines.append(f'{key}="{val}"')
                else:
                    new_lines.append(f"{key}={val}")
            else:
                new_lines.append(f"{key}={val}")
            written.add(key)
        else:
            new_lines.append(line)

    for key, val in config_dict.items():
        if key not in written:
            if key == "DOWNLOAD_URLS":
                val = val.replace("\n", ",")
            if key in quoted_keys or " " in val or "," in val:
                new_lines.append(f'{key}="{val}"')
            else:
                new_lines.append(f"{key}={val}")

    content = "\n".join(new_lines) + "\n"
    tmp = ENV_FILE + ".tmp"

    try:
        with open(ENV_FILE, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    except OSError as e:
        if e.errno == 16:
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(content)
                return True
            except OSError:
                pass
        return False

def get_stats():
    import datetime
    today = datetime.date.today().strftime("%Y-%m-%d")
    data = {"DATE": today, "GENERATE_TIME": "-", "COUNT": "0",
            "SIZE_BYTES": "0", "TIME_SECONDS": "0"}
    stats_dir = os.environ.get("TK_DISPLAY_DIR", "/app/流量统计")
    data_dir = os.environ.get("TK_DATA_DIR", "/app/data")
    found = False
    try:
        candidates = []
        if os.path.isdir(data_dir):
            for fname in os.listdir(data_dir):
                if fname.startswith("stats_data_") and fname.endswith(".log"):
                    candidates.append(fname)
        candidates.sort(reverse=True)
        if candidates:
            fpath = os.path.join(data_dir, candidates[0])
            try:
                with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if "=" in line and not line.startswith("#"):
                            k, v = line.split("=", 1)
                            data[k.strip()] = v.strip()
                found = True
            except Exception:
                pass
    except Exception:
        pass

    if not found:
        try:
            candidates = []
            if os.path.isdir(stats_dir):
                for fname in os.listdir(stats_dir):
                    if fname.startswith("stats_show_") and fname.endswith(".log"):
                        candidates.append(fname)
            candidates.sort(reverse=True)
            if candidates:
                fpath = os.path.join(stats_dir, candidates[0])
                try:
                    with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read()
                        m = re.search(r"生成日期\s*[:：]\s*(\S+)", content)
                        if m: data["DATE"] = m.group(1)
                        m = re.search(r"生成时间\s*[:：]\s*(\S+)", content)
                        if m: data["GENERATE_TIME"] = m.group(1)
                        m = re.search(r"下载次数\s*[:：]\s*(\d+)", content)
                        if m: data["COUNT"] = m.group(1)
                        m = re.search(r"下载流量\s*[:：]\s*(\d+(?:\.\d+)?\s*\S+)", content)
                        if m: data["_SIZE_HUMAN"] = m.group(1)
                        m = re.search(r"累计耗时\s*[:：]\s*(\S+)", content)
                        if m: data["_DURATION_HUMAN"] = m.group(1)
                        found = True
                except Exception:
                    pass
        except Exception:
            pass

    size_bytes = int(data.get("SIZE_BYTES", "0") or "0")
    if "_SIZE_HUMAN" not in data:
        for unit, div in [("GB", 1000**3), ("MB", 1000**2), ("KB", 1000)]:
            if size_bytes >= div:
                data["_SIZE_HUMAN"] = f"{size_bytes/div:.2f} {unit}"
                break
        else:
            data["_SIZE_HUMAN"] = f"{size_bytes} B"
    if "_DURATION_HUMAN" not in data:
        dur = int(data.get("TIME_SECONDS", "0") or "0")
        data["_DURATION_HUMAN"] = f"{dur//3600:02d}:{(dur%3600)//60:02d}:{dur%60:02d}"

    # 链接抓取统计
    fetch_stamp = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", ".last-fetch")
    fetched_links = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", "fetched-links.txt")
    try:
        if os.path.exists(fetch_stamp):
            mtime = os.path.getmtime(fetch_stamp)
            dt = datetime.datetime.fromtimestamp(mtime)
            data["FETCH_TIME"] = dt.strftime("%Y-%m-%d %H:%M:%S")
        else:
            data["FETCH_TIME"] = "-"
    except Exception:
        data["FETCH_TIME"] = "-"

    try:
        if os.path.exists(fetched_links):
            with open(fetched_links, "r", encoding="utf-8", errors="replace") as f:
                link_count = sum(1 for line in f if line.strip().startswith("http"))
            data["FETCH_COUNT"] = str(link_count)
        else:
            data["FETCH_COUNT"] = "0"
    except Exception:
        data["FETCH_COUNT"] = "0"

    # 可用链接数（经检测后有效的链接）
    validated_links = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", "validated_urls.list")
    try:
        if os.path.exists(validated_links):
            with open(validated_links, "r", encoding="utf-8", errors="replace") as f:
                valid_count = sum(1 for line in f if line.strip().startswith("http"))
            data["VALID_COUNT"] = str(valid_count)
        else:
            data["VALID_COUNT"] = "0"
    except Exception:
        data["VALID_COUNT"] = "0"

    # 上次链接检测时间
    check_stamp = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", ".last-check")
    try:
        if os.path.exists(check_stamp):
            mtime = os.path.getmtime(check_stamp)
            dt = datetime.datetime.fromtimestamp(mtime)
            data["CHECK_TIME"] = dt.strftime("%Y-%m-%d %H:%M:%S")
        else:
            data["CHECK_TIME"] = "-"
    except Exception:
        data["CHECK_TIME"] = "-"

    # 链接检测耗时
    try:
        if os.path.exists(os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", "check_duration.txt")):
            with open(os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links", "check_duration.txt"), "r", encoding="utf-8", errors="replace") as f:
                dur = int(f.read().strip() or "0")
                data["CHECK_DURATION"] = f"{dur//3600:02d}:{(dur%3600)//60:02d}:{dur%60:02d}"
        else:
            data["CHECK_DURATION"] = "-"
    except Exception:
        data["CHECK_DURATION"] = "-"

    return data

def get_history():
    import datetime
    data_dir = os.environ.get("TK_DATA_DIR", "/app/data")
    stats_dir = os.environ.get("TK_DISPLAY_DIR", "/app/流量统计")
    records = []

    try:
        if os.path.isdir(data_dir):
            for fname in os.listdir(data_dir):
                if fname.startswith("stats_data_") and fname.endswith(".log"):
                    fpath = os.path.join(data_dir, fname)
                    try:
                        with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                            rec = {"source": "data", "filename": fname}
                            for line in f:
                                line = line.strip()
                                if "=" in line and not line.startswith("#"):
                                    k, v = line.split("=", 1)
                                    rec[k.strip()] = v.strip()
                            date_str = fname.replace("stats_data_", "").replace(".log", "")
                            rec["date"] = date_str
                            records.append(rec)
                    except Exception:
                        pass
    except Exception:
        pass

    try:
        if os.path.isdir(stats_dir):
            for fname in os.listdir(stats_dir):
                if fname.startswith("stats_show_") and fname.endswith(".log"):
                    fpath = os.path.join(stats_dir, fname)
                    try:
                        with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                            content = f.read()
                            rec = {"source": "stats_show", "filename": fname}
                            m = re.search(r"(\d{4}-\d{2}-\d{2})", fname)
                            if m:
                                rec["date"] = m.group(1)
                            else:
                                rec["date"] = fname
                            m = re.search(r"生成日期\s*[:：]\s*(\S+)", content)
                            if m: rec["DATE"] = m.group(1)
                            m = re.search(r"生成时间\s*[:：]\s*(\S+)", content)
                            if m: rec["GENERATE_TIME"] = m.group(1)
                            m = re.search(r"下载次数\s*[:：]\s*(\d+)", content)
                            if m: rec["COUNT"] = m.group(1)
                            m = re.search(r"下载流量\s*[:：]\s*(\S+)", content)
                            if m: rec["_SIZE_HUMAN"] = m.group(1)
                            m = re.search(r"累计耗时\s*[:：]\s*(\S+)", content)
                            if m: rec["_DURATION_HUMAN"] = m.group(1)
                            records.append(rec)
                    except Exception:
                        pass
    except Exception:
        pass

    def get_date(rec):
        return rec.get("date", "")
    records.sort(key=get_date, reverse=True)
    seen_dates = set()
    unique_records = []
    for rec in records:
        date = rec.get("date", "")
        if date in seen_dates:
            continue
        seen_dates.add(date)
        unique_records.append(rec)
    records = unique_records
    for rec in records:
        if rec.get("source") == "data":
            size_bytes = int(rec.get("SIZE_BYTES", "0") or "0")
            if size_bytes >= 1000**3:
                rec["_SIZE_HUMAN"] = f"{size_bytes/1000**3:.2f} GB"
            elif size_bytes >= 1000**2:
                rec["_SIZE_HUMAN"] = f"{size_bytes/1000**2:.2f} MB"
            elif size_bytes >= 1000:
                rec["_SIZE_HUMAN"] = f"{size_bytes/1000:.2f} KB"
            else:
                rec["_SIZE_HUMAN"] = f"{size_bytes} B"
            time_seconds = int(rec.get("TIME_SECONDS", "0") or "0")
            rec["_DURATION_HUMAN"] = f"{time_seconds//3600:02d}:{(time_seconds%3600)//60:02d}:{time_seconds%60:02d}"
    return records[:100]

def get_log_tail(limit=1000):
    if not os.path.exists(LOG_FILE):
        return []
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        return [l.rstrip("\n") for l in lines[-limit:]]
    except Exception:
        return []

INDEX_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Traffic Keeper 管理界面</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;background:#f0f2f5;min-height:100vh;padding:20px}
.container{max-width:1200px;margin:0 auto}
.header{text-align:center;padding:24px 0 16px}
.header h1{font-size:32px;color:#1a1a2e;margin-bottom:4px;letter-spacing:-.5px}
.header .version{display:inline-block;background:#667eea;color:#fff;font-size:12px;padding:2px 10px;border-radius:12px;margin-bottom:8px}
.header .sub{color:#666;font-size:14px}
.stats-panel{background:#fff;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.08);margin-bottom:20px;padding:20px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:16px}
.stat-card{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:18px;border-radius:10px;text-align:center}
.stat-card .label{font-size:12px;opacity:.85;margin-bottom:6px}
.stat-card .value{font-size:22px;font-weight:700}
.main-panel{background:#fff;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.08);overflow:hidden}
.panel-body{padding:20px}
.tabs{display:flex;gap:4px;margin-bottom:20px;border-bottom:2px solid #e9ecef;padding-bottom:0}
.tab{padding:10px 20px;border:none;background:none;cursor:pointer;font-size:14px;color:#666;border-bottom:3px solid transparent;margin-bottom:-2px;border-radius:4px 4px 0 0}
.tab:hover{color:#667eea;background:#f8f9fa}
.tab.active{color:#667eea;border-bottom-color:#667eea;font-weight:600;background:#f8f9fa}
.tab-content{display:none}
.tab-content.active{display:block}
.config-section{margin-bottom:24px}
.config-section-title{font-size:15px;font-weight:600;color:#333;margin-bottom:12px;padding-left:8px;border-left:3px solid #667eea}
.config-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}
.config-item{background:#f8f9fa;padding:14px;border-radius:8px;border:1px solid #e9ecef}
.config-item label{display:block;font-weight:600;color:#333;margin-bottom:6px;font-size:13px}
.config-item input,.config-item select,.config-item textarea{width:100%;padding:8px 10px;border:1px solid #ddd;border-radius:6px;font-size:14px;font-family:inherit;background:#fff}
.config-item textarea{font-family:"Courier New",monospace;min-height:70px;resize:vertical}
#tab-sources .config-grid{grid-template-columns:1fr}
#tab-sources textarea{min-height:60vh}
.config-item input:focus,.config-item select:focus,.config-item textarea:focus{outline:none;border-color:#667eea}
.config-item .desc{margin-top:4px;font-size:11px;color:#888;line-height:1.4}
.config-item .convert-hint{margin-top:4px;font-size:11px;color:#667eea;font-weight:500}
.btn{padding:10px 20px;border:none;border-radius:6px;font-size:14px;cursor:pointer;font-weight:600;transition:opacity .2s}
.btn:hover{opacity:.85}
.btn-primary{background:#667eea;color:#fff}
.btn-secondary{background:#e9ecef;color:#495057}
.actions{margin-top:20px;padding-top:16px;border-top:1px solid #e9ecef;display:flex;gap:10px;justify-content:flex-end;align-items:center;flex-wrap:wrap}
.hint{color:#888;font-size:12px;margin-right:auto}
.log-toolbar{display:flex;gap:10px;align-items:center;margin-bottom:12px;flex-wrap:wrap}
.log-search{flex:1;min-width:200px;padding:8px 12px;border:1px solid #ddd;border-radius:6px;font-size:14px}
.log-search:focus{outline:none;border-color:#667eea}
.log-container{background:#1e1e1e;border-radius:8px;padding:16px;height:480px;overflow-y:auto;font-family:Consolas,Monaco,"Courier New",monospace;font-size:13px;line-height:1.6;color:#d4d4d4;white-space:pre-wrap;word-break:break-all}
.log-container::-webkit-scrollbar{width:8px}
.log-container::-webkit-scrollbar-thumb{background:#555;border-radius:4px}
.log-line{padding:1px 0}
.log-line.hidden{display:none}
.toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:8px;color:#fff;font-size:14px;z-index:1000;opacity:0;transform:translateX(100px);transition:all .3s}
.toast.show{opacity:1;transform:translateX(0)}
.toast.success{background:#28a745}
.toast.error{background:#dc3545}
.history-table{width:100%;border-collapse:collapse;font-size:13px}
.history-table th,.history-table td{padding:10px 12px;text-align:left;border-bottom:1px solid #e9ecef}
.history-table th{background:#f8f9fa;font-weight:600;color:#333}
.history-table tr:hover{background:#f8f9fa}
.history-empty{text-align:center;color:#888;padding:40px}
@media(max-width:768px){.config-grid{grid-template-columns:1fr}.stats{grid-template-columns:repeat(2,1fr)}}
</style></head><body>
<div class="container">
<div class="header"><h1>Traffic Keeper</h1>
<div class="sub">飞牛 NAS 流量平衡脚本 | <span id="server-time"></span></div></div>
<div class="stats-panel"><div class="stats" id="stats-box">
<div class="stat-card"><div class="label">生成日期</div><div class="value" id="stat-date">-</div></div>
<div class="stat-card"><div class="label">生成时间</div><div class="value" id="stat-time">-</div></div>
<div class="stat-card"><div class="label">下载次数</div><div class="value" id="stat-count">-</div></div>
<div class="stat-card"><div class="label">下载流量</div><div class="value" id="stat-size">-</div></div>
<div class="stat-card"><div class="label">累计耗时</div><div class="value" id="stat-dur">-</div></div>
<div class="stat-card"><div class="label">上次抓取</div><div class="value" id="stat-fetch-time">-</div></div>
<div class="stat-card"><div class="label">抓取链接</div><div class="value" id="stat-fetch-count">-</div></div>
<div class="stat-card"><div class="label">可用链接</div><div class="value" id="stat-valid-count">-</div></div>
<div class="stat-card"><div class="label">检测时间</div><div class="value" id="stat-check-time">-</div></div>
<div class="stat-card"><div class="label">检测用时</div><div class="value" id="stat-check-dur">-</div></div>
</div></div>
<div class="main-panel"><div class="panel-body">
<div class="tabs">
<button class="tab active" data-tab="config">配置管理</button>
<button class="tab" data-tab="logs">终端日志</button>
<button class="tab" data-tab="history">历史数据</button>
<button class="tab" data-tab="links">抓取链接</button>
<button class="tab" data-tab="sources">配置下载源</button></div>
<div class="tab-content active" id="tab-config"></div>
<div class="tab-content" id="tab-logs">
<div class="log-toolbar">
<input type="text" class="log-search" id="log-search" placeholder="搜索日志..." oninput="filterLogs()">
<button type="button" class="btn btn-secondary" onclick="toggleAutoScroll()" id="scroll-btn">自动滚动</button>
<button type="button" class="btn btn-secondary" onclick="clearLogs()">清空显示</button></div>
<div class="log-container" id="log-container"></div></div>
<div class="tab-content" id="tab-history">
<div style="margin-bottom:12px"><span style="font-size:12px;color:#888">显示最近100条历史记录</span></div>
<div id="history-table" style="overflow-x:auto"></div></div>
<div class="tab-content" id="tab-links">
<div style="margin-bottom:12px"><span style="font-size:12px;color:#888">抓取到的可用链接列表</span></div>
<div id="links-table" style="overflow-x:auto"></div></div>
<div class="tab-content" id="tab-sources"></div>
</div></div></div>
<div class="toast" id="toast"></div>
<script>
const CONFIG_GROUPS=[
{title:"时间设置",keys:["SLEEP_MIN","SLEEP_MAX","CONNECT_TIMEOUT","MAX_TIME","RETRY_DELAY","FETCH_INTERVAL"]},
{title:"数据设置",keys:["LIMIT_RATE","ROUND_MIN_BYTES","FETCH_MIN_FILE_BYTES","MAX_DAILY_BYTES"]},
{title:"网络连接",keys:["RUN_TIMES_MAX","RETRY","LINK_CHECK_INTERVAL","USER_AGENT"]},
{title:"系统设置",keys:["DYNAMIC_SLEEP","WEB_PORT"]}
];
const SOURCE_GROUPS=[
{title:"下载源配置",keys:["DOWNLOAD_URLS"]}
];
const FIELD_META={
LIMIT_RATE:{label:"下载限速",type:"text",desc:"如 5M / 500K / 1G，留空或 0 表示不限速",unit:"rate"},
SLEEP_MAX:{label:"最大休眠时间",type:"text",desc:"支持 s/m/h 单位，如 15m / 1h / 30s",unit:"time"},
SLEEP_MIN:{label:"最小休眠时间",type:"text",desc:"支持 s/m/h 单位，如 1m / 30s",unit:"time"},
DYNAMIC_SLEEP:{label:"动态休眠",type:"select",options:[["true","开启"],["false","关闭"]],desc:"开启后随机在最小/最大之间取值"},

ROUND_MIN_BYTES:{label:"本轮最小下载总量",type:"text",desc:"支持 K/M/G/T 单位，如 1G / 500M，0表示不检查",unit:"size"},
RUN_TIMES_MAX:{label:"每轮最大下载次数",type:"number",desc:"每轮任务最多执行多少次下载"},
LINK_CHECK_INTERVAL:{label:"链接检测间隔",type:"text",desc:"两次链接检测之间的最小间隔，支持 s/m/h 单位，如 30m / 1h",unit:"time"},
CONNECT_TIMEOUT:{label:"连接超时",type:"text",desc:"支持 s/m/h 单位，如 15s / 1m",unit:"time"},
MAX_TIME:{label:"单次下载最大时间",type:"text",desc:"支持 s/m/h 单位，如 50m / 1h",unit:"time"},
RETRY:{label:"重试次数",type:"number",desc:"curl 失败重试次数"},
RETRY_DELAY:{label:"重试间隔",type:"text",desc:"支持 s/m/h 单位，如 5s / 1m",unit:"time"},
FETCH_INTERVAL:{label:"链接抓取间隔",type:"text",desc:"支持 s/m/h 单位，如 6h / 30m",unit:"time"},
FETCH_MIN_FILE_BYTES:{label:"最小文件大小",type:"text",desc:"支持 K/M/G/T 单位，如 1G / 500M",unit:"size"},
USER_AGENT:{label:"User-Agent",type:"text",desc:"HTTP 请求标识"},
MAX_DAILY_BYTES:{label:"单日最大下载量",type:"text",desc:"支持 K/M/G/T 单位，如 200G / 1T",unit:"size"},
DOWNLOAD_URLS:{label:"下载链接列表",type:"textarea",desc:"每行一个链接"},
WEB_PORT:{label:"Web 端口",type:"number",desc:"管理界面端口，需与 docker-compose 一致"}
};
function parseTime(v){const m=String(v).trim().match(/^(\d+)\s*([smh]?)$/i);if(!m)return null;const n=parseInt(m[1]),u=m[2].toLowerCase();if(u==='h')return n*3600;if(u==='m')return n*60;return n}
function parseSize(v){const m=String(v).trim().match(/^(\d+)\s*([KMGTkmgt]?[iI]?[bB]?)?$/);if(!m)return null;const n=parseInt(m[1]);const u=(m[2]||'').toLowerCase().charAt(0);const mul={t:1099511627776,g:1073741824,m:1048576,k:1024};return n*(mul[u]||1)}
function fmtSize(b){if(b>=1099511627776)return(b/1099511627776).toFixed(2)+' TiB';if(b>=1073741824)return(b/1073741824).toFixed(2)+' GiB';if(b>=1048576)return(b/1048576).toFixed(2)+' MiB';if(b>=1024)return(b/1024).toFixed(2)+' KiB';return b+' B'}
function fmtTime(s){if(s>=3600){const h=Math.floor(s/3600),m=Math.floor((s%3600)/60);return h+'h '+m+'m';}if(s>=60){return Math.floor(s/60)+'m '+s%60+'s';}return s+'s'}
function unitHint(key,val){const m=FIELD_META[key];if(!m||!m.unit||!val)return'';if(m.unit==='time'){const s=parseTime(val);if(s!==null)return'<div class="convert-hint">= '+fmtTime(s)+'</div>'}if(m.unit==='size'){const b=parseSize(val);if(b!==null)return'<div class="convert-hint">= '+fmtSize(b)+'</div>'}return''}
document.querySelectorAll('.tab').forEach(b=>{b.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.tab-content').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById('tab-'+b.dataset.tab).classList.add('active');if(b.dataset.tab==='logs')startLogStream();if(b.dataset.tab==='links')loadLinks();}});
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function renderGroups(boxId,groups,cfg,showTitle){const box=document.getElementById(boxId);box.innerHTML='';groups.forEach(g=>{const section=document.createElement('div');section.className='config-section';let html='';if(showTitle!==false){html+='<div class="config-section-title">'+escapeHtml(g.title)+'</div>'}html+='<div class="config-grid">';g.keys.forEach(key=>{const m=FIELD_META[key];if(!m)return;const v=cfg[key]!==undefined?cfg[key]:'';html+='<div class="config-item">';html+='<label>'+escapeHtml(m.label)+'</label>';if(m.type==='textarea'){html+='<textarea name="'+key+'" oninput="updateHint(this)">'+escapeHtml(v)+'</textarea>'}else if(m.type==='select'){html+='<select name="'+key+'">'+m.options.map(([o,l])=>'<option value="'+escapeHtml(o)+'"'+(o===v?' selected':'')+'>'+escapeHtml(l)+'</option>').join('')+'</select>'}else{html+='<input type="'+m.type+'" name="'+key+'" value="'+escapeHtml(v)+'" oninput="updateHint(this)">'}html+=unitHint(key,v);html+='<div class="desc">'+escapeHtml(m.desc)+'</div></div>'});html+='</div>';section.innerHTML=html;box.appendChild(section)});const actions=document.createElement('div');actions.className='actions';actions.innerHTML='<span class="hint">配置保存后，下一轮任务循环自动生效（无需重启容器）</span><button type="button" class="btn btn-secondary" onclick="loadConfig()">重新读取</button><button type="button" class="btn btn-primary" onclick="saveConfig()">保存配置</button>';box.appendChild(actions)}
function renderConfig(cfg){renderGroups('tab-config',CONFIG_GROUPS,cfg,true)}
function renderSources(cfg){renderGroups('tab-sources',SOURCE_GROUPS,cfg,false)}
function updateHint(el){const key=el.name;const hintEl=el.parentElement.querySelector('.convert-hint');if(hintEl)hintEl.outerHTML=unitHint(key,el.value)}
function loadConfig(){fetch('/api/config').then(r=>r.json()).then(d=>{renderConfig(d);renderSources(d);showToast('配置已重新读取','success')}).catch(e=>showToast('读取失败: '+e,'error'))}
function saveConfig(){const data={};document.querySelectorAll('#tab-config input,#tab-config select,#tab-config textarea,#tab-sources input,#tab-sources select,#tab-sources textarea').forEach(el=>{data[el.name]=el.value});fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)}).then(r=>r.json()).then(res=>{if(res.success)showToast('配置保存成功！下一轮任务自动生效','success');else showToast('保存失败: '+(res.error||'未知错误'),'error')}).catch(e=>showToast('保存失败: '+e,'error'))}
function showToast(msg,type){const t=document.getElementById('toast');t.textContent=msg;t.className='toast '+type;setTimeout(()=>t.classList.add('show'),10);setTimeout(()=>t.classList.remove('show'),3000)}
function updateStats(){fetch('/api/stats').then(r=>r.json()).then(d=>{document.getElementById('stat-date').textContent=d.DATE||'-';document.getElementById('stat-time').textContent=d.GENERATE_TIME||'-';document.getElementById('stat-count').textContent=d.COUNT||'0';document.getElementById('stat-size').textContent=d._SIZE_HUMAN||'-';document.getElementById('stat-dur').textContent=d._DURATION_HUMAN||'-';document.getElementById('stat-fetch-time').textContent=d.FETCH_TIME||'-';document.getElementById('stat-fetch-count').textContent=d.FETCH_COUNT||'0';document.getElementById('stat-valid-count').textContent=d.VALID_COUNT||'0';document.getElementById('stat-check-time').textContent=d.CHECK_TIME||'-';document.getElementById('stat-check-dur').textContent=d.CHECK_DURATION||'-';}).catch(()=>{})}
let autoScroll=true,eventSource=null,allLogLines=[];
function toggleAutoScroll(){autoScroll=!autoScroll;document.getElementById('scroll-btn').textContent=autoScroll?'自动滚动':'已暂停'}
function filterLogs(){const q=document.getElementById('log-search').value.trim().toLowerCase();document.querySelectorAll('.log-line').forEach(line=>{line.classList.toggle('hidden',q&&!line.textContent.toLowerCase().includes(q))})}
function renderLogs(lines){const c=document.getElementById('log-container');const q=document.getElementById('log-search').value.trim().toLowerCase();c.innerHTML=lines.map(line=>{const cls=q&&!line.toLowerCase().includes(q)?'log-line hidden':'log-line';return'<div class="'+cls+'">'+escapeHtml(line)+'</div>'}).join('');if(autoScroll)c.scrollTop=c.scrollHeight}
function startLogStream(){if(eventSource)return;const c=document.getElementById('log-container');fetch('/api/logs').then(r=>r.json()).then(d=>{allLogLines=d.lines;renderLogs(allLogLines)});try{eventSource=new EventSource('/api/logs/stream');eventSource.onmessage=(e)=>{allLogLines.push(e.data);const q=document.getElementById('log-search').value.trim().toLowerCase();const div=document.createElement('div');div.className='log-line';if(q&&!e.data.toLowerCase().includes(q))div.classList.add('hidden');div.textContent=e.data;c.appendChild(div);if(autoScroll)c.scrollTop=c.scrollHeight};eventSource.onerror=()=>{setTimeout(()=>{if(eventSource){eventSource.close();eventSource=null}},2000)}}catch(e){console.error(e)}}
function clearLogs(){document.getElementById('log-container').innerHTML='';allLogLines=[]}
function loadHistory(){fetch('/api/history').then(r=>r.json()).then(d=>{const box=document.getElementById('history-table');if(!d.records||d.records.length===0){box.innerHTML='<div class="history-empty">暂无历史数据</div>';return}let html='<table class="history-table"><thead><tr><th>日期</th><th>生成时间</th><th>下载次数</th><th>下载流量</th><th>累计耗时</th></tr></thead><tbody>';d.records.forEach(r=>{html+='<tr>';html+='<td>'+escapeHtml(r.date||'-')+'</td>';html+='<td>'+escapeHtml(r.GENERATE_TIME||'-')+'</td>';html+='<td>'+escapeHtml(r.COUNT||'0')+'</td>';html+='<td>'+escapeHtml(r._SIZE_HUMAN||'-')+'</td>';html+='<td>'+escapeHtml(r._DURATION_HUMAN||'-')+'</td>';html+='</tr>'});html+='</tbody></table>';box.innerHTML=html}).catch(e=>{document.getElementById('history-table').innerHTML='<div class="history-empty">加载失败: '+escapeHtml(e.message)+'</div>'})}
function loadLinks(){fetch('/api/links').then(r=>r.json()).then(d=>{const box=document.getElementById('links-table');const total=d.total||0,valid=d.valid||0,urls=d.urls||[];let html='<div style="margin-bottom:12px;font-size:13px;color:#666">总计: '+total+' 条 | 可用: '+valid+' 条</div>';if(urls.length===0){box.innerHTML=html+'<div class="history-empty">暂无可用链接</div>';return}html+='<table class="history-table"><thead><tr><th style="width:60px">#</th><th>链接地址</th></tr></thead><tbody>';urls.forEach((u,i)=>{html+='<tr><td>'+(i+1)+'</td><td style="word-break:break-all">'+escapeHtml(u)+'</td></tr>'});html+='</tbody></table>';box.innerHTML=html}).catch(e=>{document.getElementById('links-table').innerHTML='<div class="history-empty">加载失败: '+escapeHtml(e.message)+'</div>'})}
function updateTime(){document.getElementById('server-time').textContent=new Date().toLocaleString('zh-CN')}
loadConfig();updateStats();updateTime();loadHistory();loadLinks();setInterval(updateStats,10000);setInterval(updateTime,1000);
</script></body></html>
"""

class LogWatcher:
    def __init__(self, path):
        self.path = path
        self._fp = None
        self._inode = None
        self._open()

    def _open(self):
        try:
            self._fp = open(self.path, "r", encoding="utf-8", errors="replace")
            self._fp.seek(0, 2)
            try:
                self._inode = os.fstat(self._fp.fileno()).st_ino
            except Exception:
                self._inode = None
        except Exception:
            self._fp = None
            self._inode = None

    def check_reopen(self):
        try:
            if not os.path.exists(self.path):
                self._fp = None
                return
            new_inode = os.stat(self.path).st_ino
            if new_inode != self._inode:
                if self._fp:
                    try: self._fp.close()
                    except Exception: pass
                self._open()
        except Exception:
            pass

    def read_new_lines(self):
        self.check_reopen()
        if not self._fp:
            return []
        lines = []
        try:
            for line in self._fp:
                line = line.rstrip("\n")
                if line:
                    lines.append(line)
        except Exception:
            pass
        return lines


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/" or path == "/index.html":
            self._send_html(INDEX_HTML)
        elif path == "/api/config":
            try:
                self._send_json(env_to_dict())
            except Exception as e:
                self._send_json({"success": False, "error": str(e)}, 500)
        elif path == "/api/stats":
            try:
                self._send_json(get_stats())
            except Exception as e:
                self._send_json({}, 500)
        elif path == "/api/history":
            try:
                self._send_json({"records": get_history()})
            except Exception as e:
                self._send_json({"records": [], "error": str(e)}, 500)
        elif path == "/api/links":
            try:
                import os
                links_dir = os.path.join(os.environ.get("TK_DATA_DIR", "/app/data"), "links")
                total, valid, urls = 0, 0, []
                try:
                    with open(os.path.join(links_dir, "fetched-links.txt"), "r", encoding="utf-8", errors="replace") as f:
                        total = sum(1 for line in f if line.strip().startswith("http"))
                except Exception:
                    pass
                try:
                    with open(os.path.join(links_dir, "validated_urls.list"), "r", encoding="utf-8", errors="replace") as f:
                        urls = [line.strip() for line in f if line.strip().startswith("http")]
                        valid = len(urls)
                except Exception:
                    pass
                self._send_json({"total": total, "valid": valid, "urls": urls})
            except Exception as e:
                self._send_json({"total": 0, "valid": 0, "urls": [], "error": str(e)}, 500)
        elif path == "/api/logs":
            try:
                self._send_json({"lines": get_log_tail(2000)})
            except Exception as e:
                self._send_json({"lines": [], "error": str(e)}, 500)
        elif path == "/api/logs/stream":
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()

                watcher = LogWatcher(LOG_FILE)
                for line in get_log_tail(500):
                    self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                self.wfile.flush()

                while True:
                    time.sleep(1.0)
                    lines = watcher.read_new_lines()
                    for line in lines:
                        try:
                            self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                        except Exception:
                            return
                    if lines:
                        try: self.wfile.flush()
                        except Exception: return
            except Exception:
                return
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/config":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8")
                data = json.loads(body)
                success = write_env(data)
                if success:
                    self._send_json({"success": True})
                else:
                    self._send_json({"success": False, "error": "配置文件保存失败，请稍后重试"}, 500)
            except Exception as e:
                self._send_json({"success": False, "error": str(e)}, 400)
        else:
            self.send_response(404)
            self.end_headers()


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = get_web_port()
    os.makedirs(os.path.dirname(LOG_FILE) or ".", exist_ok=True)
    server = ThreadedServer(("0.0.0.0", port), Handler)
    print(f"[webserver] Traffic Keeper Web UI running on http://0.0.0.0:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
