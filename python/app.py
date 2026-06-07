#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import signal
import time
import stat
import subprocess
import urllib.request
import urllib.error
import http.server
import socketserver
import threading
import platform
from pathlib import Path

# 环境变量配置
PORT = int(os.environ.get('PORT', 3000))       # http服务端口
SUB_PATH = os.environ.get('SUB_PATH', 'sub')   # 订阅token
config = {
    'UUID': os.environ.get('UUID', '74f12816-2d6e-4bc3-b241-3269614aa06f'), # 节点UUID，使用哪吒v1时在不不同的平台部署需要修改，否则agent会覆盖
    'NEZHA_SERVER': os.environ.get('NEZHA_SERVER', ''), # 哪吒面板地址，v1格式: nezha.xxx.com:8008  v0格式： nezha.xxx.com
    'NEZHA_PORT': os.environ.get('NEZHA_PORT', ''),     # 哪吒v1请留空，哪吒v0 agent端口
    'NEZHA_KEY': os.environ.get('NEZHA_KEY', ''),       # 哪吒v1的NZ_CLIENT_SECRET或哪吒v0-agent密钥
    'ARGO_DOMAIN': os.environ.get('ARGO_DOMAIN', 'kata.cfyou.kdns.fr'),   # 固定隧道域名,留空即启用临时隧道
    'ARGO_AUTH': os.environ.get('ARGO_AUTH', 'eyJhIjoiNTg2M2Y1OTJlMjkzMjg1MzgyZThlM2EzZDEzMmJjYWQiLCJ0IjoiZmFhOTBkNTAtZmI4Ni00Y2MwLTg2NzQtODRiZWRhMWUwZGZjIiwicyI6Ik1qY3lNbUkwWkRNdE56aGtaUzAwTlRoakxUbGpPV0l0TURBNU9UVmlaamsxTkRKaSJ9'),       # 固定隧道token或json,留空即启用临时隧道,json获取:https://json.zone.id
    'ARGO_PORT': os.environ.get('ARGO_PORT', '8001'),   # argo端口 使用固定隧道token,cloudflare后台设置的端口需和这里对应
    'CFIP': os.environ.get('CFIP', 'saas.sin.fan'),     # 优选域名或优选ip
    'CFPORT': os.environ.get('CFPORT', '443'),          # 优选域名或优选ip对应端口
    'NAME': os.environ.get('NAME', ''),                 # 节点备注
    'S5_PORT': os.environ.get('S5_PORT', ''),           # socks5端口,支持多端口玩具可填写，否则不动
    'HY2_PORT': os.environ.get('HY2_PORT', ''),         # Hy2 端口，支持多端口玩具可填写，否则不动
    'TUIC_PORT': os.environ.get('TUIC_PORT', ''),        # Tuic 端口，支持多端口玩具可填写，否则不动 
    'ANYTLS_PORT': os.environ.get('ANYTLS_PORT', ''),    # AnyTLS 端口,支持多端口玩具可填写，否则不动
    'REALITY_PORT': os.environ.get('REALITY_PORT', ''),      # Reality 端口,支持多端口玩具可填写，否则不动
    'ANYREALITY_PORT': os.environ.get('ANYREALITY_PORT', ''), # AnyReality 端口,支持多端口玩具可填写，否则不动
    'CHAT_ID': os.environ.get('CHAT_ID', ''),                 # TG chat_id，可在https://t.me/laowang_serv00_bot 获取
    'BOT_TOKEN': os.environ.get('BOT_TOKEN', ''),             # TG bot_token, 使用自己的bot需要填写,使用上方的bot不用填写,不会给别人发送
    'UPLOAD_URL': os.environ.get('UPLOAD_URL', ''),           # 节点上传地址，需部署merge-sub订阅器项目，例如：https://merge.xxx.com
    'FILE_PATH': os.environ.get('FILE_PATH', '.cache'),       # sub,.txt节点存放目录
    'DISABLE_ARGO': os.environ.get('DISABLE_ARGO', 'false'),  # 是否禁用argo, true为禁用,false为不禁用,默认开启
}

def sleep(ms):
    time.sleep(ms / 1000)

def get_architecture():
    """获取系统架构"""
    arch = platform.machine().lower()
    system = platform.system().lower()
    
    if system in ['linux', 'darwin']:
        if arch in ['x86_64', 'amd64']:
            return 'amd64'
        elif arch in ['aarch64', 'arm64']:
            return 'arm64'
    
    raise Exception(f"Unsupported architecture: {system} {arch}")

def download_file(url, dest_path):
    print(f"Downloading from: {url}")
    opener = urllib.request.build_opener()
    opener.addheaders = [
        ('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'),
        ('Accept', '*/*'),
        ('Connection', 'keep-alive')
    ]
    
    urllib.request.install_opener(opener)
    
    try:
        # 下载文件
        urllib.request.urlretrieve(url, dest_path)
        # print("Download completed!")
    except urllib.error.HTTPError as e:
        if os.path.exists(dest_path):
            os.unlink(dest_path)
        raise Exception(f"Download failed (HTTP {e.code}): {e.reason}")
    except urllib.error.URLError as e:
        if os.path.exists(dest_path):
            os.unlink(dest_path)
        raise Exception(f"Download failed (URL error): {str(e)}")
    except Exception as e:
        if os.path.exists(dest_path):
            os.unlink(dest_path)
        raise Exception(f"Download failed: {str(e)}")

def set_executable(file_path):
    """设置文件可执行权限"""
    try:
        current_permissions = os.stat(file_path).st_mode
        os.chmod(file_path, current_permissions | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except Exception as e:
        raise Exception(f"Failed to set executable permission: {str(e)}")

def delete_file(file_path):
    """删除文件"""
    try:
        if os.path.exists(file_path):
            os.unlink(file_path)
    except Exception as e:
        print(f"Failed to delete file {file_path}: {str(e)}")

class CustomHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    """自定义HTTP请求处理器"""
    
    def do_GET(self):
        if self.path == '/':
            self.handle_root()
        elif self.path == f'/{SUB_PATH}':
            self.handle_sub()
        elif self.path == '/ps':
            self.handle_ps()
        else:
            self.send_error(404, '404 Not Found')
    
    def handle_root(self):
        """处理根路径请求"""
        try:
            html_path = os.path.join(os.path.dirname(__file__), 'index.html')
            if os.path.exists(html_path):
                with open(html_path, 'r', encoding='utf-8') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                self.wfile.write(data.encode('utf-8'))
            else:
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
                self.wfile.write("Hello world!<br><br>You can access /{SUB_PATH}(Default: /sub) to get your nodes!".encode('utf-8'))
        except Exception as e:
            self.send_error(500, str(e))
    
    def handle_sub(self):
        """处理订阅路径请求"""
        sub_file_path = os.path.join(config['FILE_PATH'], 'sub.txt')
        try:
            if os.path.exists(sub_file_path):
                with open(sub_file_path, 'r', encoding='utf-8') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(data.encode('utf-8'))
            else:
                self.send_error(404, f'Sub file not found at: {sub_file_path}')
        except Exception as e:
            self.send_error(500, str(e))
    
    def handle_ps(self):
        """处理进程列表请求"""
        try:
            result = subprocess.run(['ps', 'aux'], capture_output=True, text=True, check=True)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(result.stdout.encode('utf-8'))
        except subprocess.CalledProcessError as e:
            self.send_error(500, f'Error executing ps command: {str(e)}')
    
    def log_message(self, format, *args):
        """覆盖日志方法，不输出访问日志"""
        pass

def start_http_server():
    """启动HTTP服务器"""
    handler = CustomHTTPRequestHandler
    
    # 创建服务器，允许地址重用
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(('0.0.0.0', PORT), handler)
    
    server_thread = threading.Thread(target=httpd.serve_forever)
    server_thread.daemon = True
    server_thread.start()
    
    return httpd

def cleanup(binary_path):
    """清理二进制文件"""
    delete_file(binary_path)

def main():
    """主函数"""
    binary_path = None
    httpd = None
    process = None
    
    try:
        # 启动HTTP服务器
        httpd = start_http_server()
        
        # 获取架构并下载
        arch = get_architecture()
        download_url = 'https://amd64.eooce.com/sbsh' if arch == 'amd64' else 'https://arm64.eooce.com/sbsh'
        
        # print(f"Using download link: {download_url}")
        binary_path = os.path.join(os.getcwd(), 'sbsh')
        
        download_file(download_url, binary_path)
        if not os.path.exists(binary_path):
            raise Exception('Download failed, file does not exist at the specified path')
        
        set_executable(binary_path)
        
        # 准备环境变量
        env = os.environ.copy()
        env.update({k: str(v) for k, v in config.items()})
        
        # 启动子进程
        process = subprocess.Popen(
            [binary_path],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1
        )
        
        # 实时输出子进程日志
        def log_output():
            for line in process.stdout:
                print(line, end='')
        
        log_thread = threading.Thread(target=log_output)
        log_thread.daemon = True
        log_thread.start()
        
        sleep(18000)
        print('\nLogs will be deleted in 90 seconds, you can copy the above nodes!')
        
        sleep(90000)
        
        cleanup(binary_path)
        
        # 清除控制台
        os.system('clear' if os.name == 'posix' else 'cls')
        
        print('✅  App is running')
        print(f'🌐  HTTP server is running on {PORT}')
        
        # 保持主线程运行
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("\nShutting down...")
            
    except Exception as e:
        print(f"\n❌ An error occurred: {str(e)}")
        if binary_path:
            cleanup(binary_path)
        sys.exit(1)
    finally:
        if process and process.poll() is None:
            process.terminate()
        if httpd:
            httpd.shutdown()

def signal_handler(signum, frame):
    print("\nReceived signal to terminate")
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    main()
