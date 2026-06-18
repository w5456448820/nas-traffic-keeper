#!/usr/bin/env python3
# =========================================================
#  Traffic Keeper - Web 管理界面服务器
#  使用 Python 标准库实现（无需第三方依赖）
#  端口：默认 8080，可通过 .env 的 WEB_PORT 配置
# =========================================================
import http.server
import socketserver
import json
import os
import time
import threading
import re

ENV_FILE = "/app/.env"
LOG_FILE = "/app/data/console.log"

def get_web_port():
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
        result[key] = value
    return result

def write_env(config_dict):
    existing_lines = parse_env_lines()
    written = set()
    new_lines = []
    quoted_keys = {"DOWNLOAD_URLS", "USER_AGENT"}

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
            if key in quoted_keys or " " in val or "," in val:
                new_lines.append(f'{key}="{val}"')
            else:
                new_lines.append(f"{key}={val}")

    content = "\n".join(new_lines) + "\n"
    tmp = ENV_FILE + ".tmp"
    
    # 直接写入 .env，放弃原子替换（避免 Docker volume / NFS 文件锁冲突）
    try:
        with open(ENV_FILE, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    except OSError as e:
        if e.errno == 16:  # Resource busy
            # 降级：写入临时文件，由下次 reload_env() 自动加载
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(content)
                return True
            except OSError:
                pass
        return False

def get_stats():
    """读取今日统计数据"""
    import datetime
    today = datetime.date.today().strftime("%Y-%m-%d")
    data = {"DATE": today, "GENERATE_TIME": "-", "COUNT": "0",
            "SIZE_BYTES": "0", "TIME_SECONDS": "0"}
    stats_dir = "/app/流量统计"
    data_dir = "/app/data"
    # 1) 优先读取 data/stats_data_*.log，按文件名日期倒序，取最新
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

    # 2) 如果 data/ 下没有读取到，则回退到 流量统计/stats_show_*.log
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
                        # 解析 stats_show 文件中的 key: value 格式
                        import re
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
    # 友好展示（仅当尚未解析出人类可读值时）
    size_bytes = int(data.get("SIZE_BYTES", "0") or "0")
    if "_SIZE_HUMAN" not in data:
        for unit, div in [("GB", 1024**3), ("MB", 1024**2), ("KB", 1024)]:
            if size_bytes >= div:
                data["_SIZE_HUMAN"] = f"{size_bytes/div:.2f} {unit}"
                break
        else:
            data["_SIZE_HUMAN"] = f"{size_bytes} B"
    if "_DURATION_HUMAN" not in data:
        dur = int(data.get("TIME_SECONDS", "0") or "0")
        data["_DURATION_HUMAN"] = f"{dur//60:02d}min {dur%60:02d}s"
    return data

def get_log_tail(limit=1000):
    if not os.path.exists(LOG_FILE):
        return []
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        return [l.rstrip("\n") for l in lines[-limit:]]
    except Exception:
        return []

# -------- HTML 页面模板（含配置管理 + 实时日志） --------
INDEX_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Traffic Keeper 管理界面</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:20px}
.container{max-width:1200px;margin:0 auto}
.header{color:#fff;text-align:center;padding:20px 0 30px}
.header h1{font-size:28px;margin-bottom:8px}
.header .sub{opacity:.9;font-size:14px}
.panel{background:#fff;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.2);margin-bottom:20px;overflow:hidden}
.panel-header{padding:18px 24px;background:#f8f9fa;border-bottom:1px solid #e9ecef}
.panel-header h2{font-size:18px;color:#333}
.panel-body{padding:24px}
.tabs{display:flex;gap:10px;margin-bottom:20px;border-bottom:2px solid #e9ecef}
.tab{padding:10px 20px;border:none;background:none;cursor:pointer;font-size:14px;color:#666;border-bottom:3px solid transparent;margin-bottom:-2px}
.tab:hover{color:#667eea}
.tab.active{color:#667eea;border-bottom-color:#667eea;font-weight:600}
.tab-content{display:none}
.tab-content.active{display:block}
.config-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
.config-item{background:#f8f9fa;padding:16px;border-radius:8px;border-left:4px solid #667eea}
.config-item label{display:block;font-weight:600;color:#333;margin-bottom:8px;font-size:13px}
.config-item input,.config-item select,.config-item textarea{width:100%;padding:8px 12px;border:1px solid #ddd;border-radius:6px;font-size:14px;font-family:inherit}
.config-item textarea{font-family:"Courier New",monospace;min-height:80px;resize:vertical}
.config-item input:focus,.config-item select:focus,.config-item textarea:focus{outline:none;border-color:#667eea}
.config-item .desc{margin-top:6px;font-size:12px;color:#888;line-height:1.5}
.btn{padding:10px 24px;border:none;border-radius:6px;font-size:14px;cursor:pointer;font-weight:600}
.btn-primary{background:#667eea;color:#fff}
.btn-primary:hover{background:#5568d3}
.btn-secondary{background:#e9ecef;color:#495057}
.btn-secondary:hover{background:#dee2e6}
.log-container{background:#1e1e1e;border-radius:8px;padding:16px;height:500px;overflow-y:auto;font-family:Consolas,Monaco,"Courier New",monospace;font-size:13px;line-height:1.6;color:#d4d4d4;white-space:pre-wrap;word-break:break-all}
.log-container::-webkit-scrollbar{width:8px}
.log-container::-webkit-scrollbar-thumb{background:#555;border-radius:4px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px}
.stat-card{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:20px;border-radius:10px}
.stat-card .label{font-size:13px;opacity:.9;margin-bottom:8px}
.stat-card .value{font-size:20px;font-weight:700;word-break:break-all}
.toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:8px;color:#fff;font-size:14px;z-index:1000;opacity:0;transform:translateX(100px);transition:all .3s}
.toast.show{opacity:1;transform:translateX(0)}
.toast.success{background:#28a745}
.toast.error{background:#dc3545}
@media(max-width:768px){.config-grid{grid-template-columns:1fr}}
</style></head><body>
<div class="container">
<div class="header"><h1>🚀 Traffic Keeper 管理界面</h1>
<div class="sub">飞牛 NAS 流量平衡脚本 | <span id="server-time"></span></div></div>
<div class="panel"><div class="panel-body">
<div class="stats" id="stats-box">
<div class="stat-card"><div class="label">生成日期</div><div class="value" id="stat-date">-</div></div>
<div class="stat-card"><div class="label">生成时间</div><div class="value" id="stat-time">-</div></div>
<div class="stat-card"><div class="label">下载次数</div><div class="value" id="stat-count">-</div></div>
<div class="stat-card"><div class="label">下载流量</div><div class="value" id="stat-size">-</div></div>
<div class="stat-card"><div class="label">累计耗时</div><div class="value" id="stat-dur">-</div></div>
</div></div></div>
<div class="panel"><div class="panel-body">
<div class="tabs">
<button class="tab active" data-tab="config">⚙️ 配置管理</button>
<button class="tab" data-tab="logs">📜 终端日志</button></div>
<div class="tab-content active" id="tab-config">
<form id="config-form" class="config-grid"></form>
<div style="margin-top:20px;text-align:right">
<button type="button" class="btn btn-secondary" onclick="loadConfig()">🔄 重新读取</button>
<button type="button" class="btn btn-primary" onclick="saveConfig()">💾 保存配置</button></div>
<div style="margin-top:12px;font-size:12px;color:#888">💡 配置保存后，下一轮任务循环自动生效（无需重启容器）</div></div>
<div class="tab-content" id="tab-logs">
<div style="margin-bottom:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap">
<button type="button" class="btn btn-secondary" onclick="toggleAutoScroll()" id="scroll-btn">🔽 自动滚动</button>
<button type="button" class="btn btn-secondary" onclick="clearLogs()">🗑️ 清空显示</button>
<span style="font-size:12px;color:#888">实时显示终端输出</span></div>
<div class="log-container" id="log-container"></div></div>
</div></div></div>
<div class="toast" id="toast"></div>
<script>
const FIELD_META={LIMIT_RATE:{label:"下载限速",type:"text",desc:"如 5M / 500K / 1G，留空或 0 表示不限速"},
SLEEP_MAX:{label:"最大休眠时间(秒)",type:"number",desc:"每轮任务之间最大间隔"},
SLEEP_MIN:{label:"最小休眠时间(秒)",type:"number",desc:"每轮任务之间最小间隔"},
DYNAMIC_SLEEP:{label:"动态休眠",type:"select",options:[["true","开启"],["false","关闭"]],desc:"开启后随机在最小/最大之间取值"},
DYNAMIC_SLEEP_MIN_BYTES:{label:"动态休眠阈值(字节)",type:"number",desc:"单次下载小于此值时本轮不启用动态休眠"},
RUN_TIMES_MAX:{label:"每轮最大下载次数",type:"number",desc:"每轮任务最多执行多少次下载"},
CONNECT_TIMEOUT:{label:"连接超时(秒)",type:"number",desc:"curl 连接超时时间"},
MAX_TIME:{label:"单次下载最大时间(秒)",type:"number",desc:"单次下载的最大总时长"},
RETRY:{label:"重试次数",type:"number",desc:"curl 失败重试次数"},
RETRY_DELAY:{label:"重试间隔(秒)",type:"number",desc:"重试之间等待的秒数"},
FETCH_INTERVAL:{label:"链接抓取间隔(秒)",type:"number",desc:"每隔多久重新抓取一次下载链接"},
FETCH_MIN_FILE_BYTES:{label:"最小文件大小(字节)",type:"number",desc:"抓取链接时过滤小文件的阈值"},
USER_AGENT:{label:"User-Agent",type:"text",desc:"HTTP 请求标识"},
MAX_DAILY_BYTES:{label:"单日最大下载量(字节)",type:"number",desc:"达到上限后今日暂停下载"},
DOWNLOAD_URLS:{label:"下载链接列表",type:"textarea",desc:"多个链接用英文逗号分隔"}};
document.querySelectorAll('.tab').forEach(b=>{b.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.tab-content').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById('tab-'+b.dataset.tab).classList.add('active');if(b.dataset.tab==='logs')startLogStream();}});
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function renderConfig(cfg){const f=document.getElementById('config-form');f.innerHTML='';for(const key of Object.keys(FIELD_META)){const m=FIELD_META[key];const v=cfg[key]!==undefined?cfg[key]:'';const item=document.createElement('div');item.className='config-item';let ih='';if(m.type==='textarea'){ih=`<textarea name="${key}">${escapeHtml(v)}</textarea>`}else if(m.type==='select'){const opts=m.options.map(([o,l])=>`<option value="${escapeHtml(o)}"${o===v?' selected':''}>${escapeHtml(l)}</option>`).join('');ih=`<select name="${key}">${opts}</select>`}else{ih=`<input type="${m.type}" name="${key}" value="${escapeHtml(v)}">`}item.innerHTML=`<label>${m.label}</label>${ih}<div class="desc">${m.desc}</div>`;f.appendChild(item)}}
function loadConfig(){fetch('/api/config').then(r=>r.json()).then(d=>{renderConfig(d);showToast('配置已重新读取','success')}).catch(e=>showToast('读取失败: '+e,'error'))}
function saveConfig(){const f=document.getElementById('config-form');const inputs=f.querySelectorAll('input,select,textarea');const data={};inputs.forEach(el=>{data[el.name]=el.value});fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)}).then(r=>r.json()).then(res=>{if(res.success)showToast('✅ 配置保存成功！下一轮任务自动生效','success');else showToast('保存失败: '+(res.error||'未知错误'),'error')}).catch(e=>showToast('保存失败: '+e,'error'))}
function showToast(msg,type){const t=document.getElementById('toast');t.textContent=msg;t.className='toast '+type;setTimeout(()=>t.classList.add('show'),10);setTimeout(()=>t.classList.remove('show'),3000)}
function updateStats(){fetch('/api/stats').then(r=>r.json()).then(d=>{document.getElementById('stat-date').textContent=d.DATE||'-';document.getElementById('stat-time').textContent=d.GENERATE_TIME||'-';document.getElementById('stat-count').textContent=d.COUNT||'0';document.getElementById('stat-size').textContent=d._SIZE_HUMAN||'-';document.getElementById('stat-dur').textContent=d._DURATION_HUMAN||'-';}).catch(()=>{})}
let logContainer,autoScroll=true,eventSource=null;
function toggleAutoScroll(){autoScroll=!autoScroll;document.getElementById('scroll-btn').textContent=autoScroll?'🔽 自动滚动':'⏸ 已暂停滚动'}
function startLogStream(){if(eventSource)return;logContainer=document.getElementById('log-container');fetch('/api/logs').then(r=>r.json()).then(d=>{logContainer.textContent=d.lines.join('\n');if(autoScroll)logContainer.scrollTop=logContainer.scrollHeight});try{eventSource=new EventSource('/api/logs/stream');eventSource.onmessage=(e)=>{if(!logContainer.textContent)logContainer.textContent=e.data;else logContainer.textContent+='\n'+e.data;if(autoScroll)logContainer.scrollTop=logContainer.scrollHeight};eventSource.onerror=()=>{setTimeout(()=>{if(eventSource){eventSource.close();eventSource=null}},2000)}}catch(e){console.error(e)}}
function clearLogs(){document.getElementById('log-container').textContent=''}
function updateTime(){document.getElementById('server-time').textContent=new Date().toLocaleString('zh-CN')}
loadConfig();updateStats();updateTime();setInterval(updateStats,10000);setInterval(updateTime,1000);
</script></body></html>
"""

# -------- 日志文件尾行监控（供 SSE 使用） --------
class LogWatcher:
    """监控日志文件，发现新行时推送到订阅者"""
    def __init__(self, path):
        self.path = path
        self._fp = None
        self._inode = None
        self._open()

    def _open(self):
        try:
            self._fp = open(self.path, "r", encoding="utf-8", errors="replace")
            self._fp.seek(0, 2)  # 跳到文件末尾
            try:
                self._inode = os.fstat(self._fp.fileno()).st_ino
            except Exception:
                self._inode = None
        except Exception:
            self._fp = None
            self._inode = None

    def check_reopen(self):
        """如果文件被重建（如被 tail 截断），重新打开"""
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
        """读取自上次以来新增的行"""
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
    # 禁用默认日志输出（避免污染 console.log）
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
        # 解析 URL（去掉查询字符串）
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
        elif path == "/api/logs":
            try:
                self._send_json({"lines": get_log_tail(2000)})
            except Exception as e:
                self._send_json({"lines": [], "error": str(e)}, 500)
        elif path == "/api/logs/stream":
            # SSE 实时日志流
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()

                watcher = LogWatcher(LOG_FILE)
                # 先发一次已有内容
                for line in get_log_tail(500):
                    self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                self.wfile.flush()

                # 轮询新行
                while True:
                    time.sleep(1.0)
                    lines = watcher.read_new_lines()
                    for line in lines:
                        try:
                            self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                        except Exception:
                            return  # 连接断开
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
