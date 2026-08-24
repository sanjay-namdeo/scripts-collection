#!/usr/bin/env python3
"""
diagnose_network_drops.py
=========================
Advanced Linux Network & Packet Drop Diagnostic Tool.
Analyzes packet drops, network drops, latency jitter, kernel/NIC drops,
and TCP connection stability between Source IP and Target IP:Port.
Analyzes packet drops, network drops, latency jitter, Wi-Fi power-saving,
gateway vs WAN drops, hop-by-hop loss, kernel/NIC drops, and TCP stability.

Usage:
    ./diagnose_network_drops.py -s <source_ip> -d <target_ip> -p <port> [options]
    ./diagnose_network_drops.py -d <target_ip_or_host> [options]
    or run interactively without arguments:
    ./diagnose_network_drops.py
"""

import sys
import os
import time
import socket
import argparse
import subprocess
import statistics
import json
import re
import signal
from datetime import datetime

# ANSI Terminal Colors
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RESET = '\033[0m'

def colorize(text, color):
    if sys.stdout.isatty():
        return f"{color}{text}{Colors.RESET}"
    return text

def print_header(title):
    width = 75
    width = 78
    print("\n" + colorize("=" * width, Colors.CYAN))
    print(colorize(f" {title.upper()} ".center(width, "="), Colors.CYAN + Colors.BOLD))
    print(colorize("=" * width, Colors.CYAN))

def print_sub_header(title):
    print(f"\n{colorize('--- ' + title + ' ---', Colors.BOLD + Colors.BLUE)}")

def run_cmd(cmd, timeout=10):
    """Executes a shell command safely and returns (exit_code, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def parse_proc_netstat():
    """Reads TCP statistics from /proc/net/snmp and /proc/net/netstat."""
    stats = {}
    try:
        if os.path.exists("/proc/net/snmp"):
            with open("/proc/net/snmp", "r") as f:
                lines = f.readlines()
            for i in range(0, len(lines), 2):
                header_parts = lines[i].strip().split()
                value_parts = lines[i+1].strip().split()
                proto = header_parts[0].rstrip(":")
                for k, v in zip(header_parts[1:], value_parts[1:]):
                    try:
                        stats[f"{proto}_{k}"] = int(v)
                    except ValueError:
                        pass
                        
        if os.path.exists("/proc/net/netstat"):
            with open("/proc/net/netstat", "r") as f:
                lines = f.readlines()
            for i in range(0, len(lines), 2):
                header_parts = lines[i].strip().split()
                value_parts = lines[i+1].strip().split()
                proto = header_parts[0].rstrip(":")
                for k, v in zip(header_parts[1:], value_parts[1:]):
                    try:
                        stats[f"{proto}_{k}"] = int(v)
                    except ValueError:
                        pass
    except Exception:
        pass
    return stats

def get_routing_info(target_ip, source_ip=None):
    """Finds outgoing interface and gateway to target IP."""
    """Finds outgoing interface, gateway, and resolved source IP to target."""
    cmd = f"ip route get {target_ip}"
    if source_ip:
        cmd += f" from {source_ip}"
    code, out, _ = run_cmd(cmd)
    
    iface = None
    gateway = None
    resolved_src = None
    
    if code == 0 and out:
        tokens = out.split()
        if "dev" in tokens:
            iface = tokens[tokens.index("dev") + 1]
        if "via" in tokens:
            gateway = tokens[tokens.index("via") + 1]
        if "src" in tokens:
            resolved_src = tokens[tokens.index("src") + 1]
            
    return iface, gateway, resolved_src

def check_nic_and_kernel_health(iface):
    """Checks Linux NIC ring buffers, link errors, softnet drops, and conntrack limits."""
def check_nic_and_kernel_health(iface, gateway=None):
    """Checks Linux NIC ring buffers, link errors, Wi-Fi power-save, softnet drops, and conntrack limits."""
    results = {}
    print_sub_header(f"Phase 1: Local System & Interface Diagnostics ({iface or 'default'})")
    print_sub_header(f"Phase 1: Local System, NIC & Wi-Fi Health ({iface or 'default'})")
    
    # 1. Interface Errors via ip -s link
    # 1. Interface Errors via /sys/class/net or ip -s link
    if iface:
        code, out, _ = run_cmd(f"ip -s link show {iface}")
        if code == 0:
            results['ip_link'] = out
            lines = out.splitlines()
            rx_dropped, tx_dropped, rx_errors, tx_errors = 0, 0, 0, 0
            for i, line in enumerate(lines):
                if "RX:" in line and i + 1 < len(lines):
                    parts = lines[i+1].split()
                    if len(parts) >= 4:
                        rx_errors = int(parts[2])
                        rx_dropped = int(parts[3])
                if "TX:" in line and i + 1 < len(lines):
                    parts = lines[i+1].split()
                    if len(parts) >= 4:
                        tx_errors = int(parts[2])
                        tx_dropped = int(parts[3])
        rx_dropped, tx_dropped, rx_errors, tx_errors = 0, 0, 0, 0
        stat_dir = f"/sys/class/net/{iface}/statistics"
        if os.path.exists(stat_dir):
            try:
                with open(f"{stat_dir}/rx_dropped") as f: rx_dropped = int(f.read().strip())
                with open(f"{stat_dir}/tx_dropped") as f: tx_dropped = int(f.read().strip())
                with open(f"{stat_dir}/rx_errors") as f: rx_errors = int(f.read().strip())
                with open(f"{stat_dir}/tx_errors") as f: tx_errors = int(f.read().strip())
            except Exception:
                pass
        else:
            code, out, _ = run_cmd(f"ip -s link show {iface}")
            if code == 0:
                lines = out.splitlines()
                for i, line in enumerate(lines):
                    if "RX:" in line and i + 1 < len(lines):
                        parts = lines[i+1].split()
                        if len(parts) >= 4:
                            rx_errors = int(parts[2])
                            rx_dropped = int(parts[3])
                    if "TX:" in line and i + 1 < len(lines):
                        parts = lines[i+1].split()
                        if len(parts) >= 4:
                            tx_errors = int(parts[2])
                            tx_dropped = int(parts[3])
            
            status_color = Colors.GREEN if (rx_dropped == 0 and tx_dropped == 0 and rx_errors == 0 and tx_errors == 0) else Colors.YELLOW
            print(f"[*] Interface {colorize(iface, Colors.BOLD)} Link Counters:")
            print(f"    - RX Errors: {rx_errors:<6} RX Dropped: {colorize(str(rx_dropped), status_color)}")
            print(f"    - TX Errors: {tx_errors:<6} TX Dropped: {colorize(str(tx_dropped), status_color)}")
            results['nic_counters'] = {'rx_err': rx_errors, 'rx_drop': rx_dropped, 'tx_err': tx_errors, 'tx_drop': tx_dropped}
        status_color = Colors.GREEN if (rx_dropped == 0 and tx_dropped == 0 and rx_errors == 0 and tx_errors == 0) else Colors.YELLOW
        print(f"[*] Interface {colorize(iface, Colors.BOLD)} Link Counters:")
        print(f"    - RX Errors: {rx_errors:<6} RX Dropped: {colorize(str(rx_dropped), status_color)}")
        print(f"    - TX Errors: {tx_errors:<6} TX Dropped: {colorize(str(tx_dropped), status_color)}")
        results['nic_counters'] = {'rx_err': rx_errors, 'rx_drop': rx_dropped, 'tx_err': tx_errors, 'tx_drop': tx_dropped}

        # Ethtool ring buffer checks if tool available
        code, out, _ = run_cmd(f"ethtool -S {iface}")
        if code == 0:
            suspicious_keys = ['drop', 'discard', 'overrun', 'fifo', 'err', 'loss', 'miss']
            found_drops = []
            for line in out.splitlines():
                k_v = line.strip().split(":")
                if len(k_v) == 2:
                    k, v = k_v[0].strip(), k_v[1].strip()
                    if any(sk in k.lower() for sk in suspicious_keys):
                        try:
                            val_int = int(v)
                            if val_int > 0:
                                found_drops.append((k, val_int))
                        except ValueError:
                            pass
            if found_drops:
                print(f"    {colorize('[!]', Colors.YELLOW)} Ethtool Hardware Drop Counters Detected:")
                print(f"    {colorize('[!][Ethtool] Hardware Drop Counters Detected:', Colors.YELLOW)}")
                for k, v in found_drops[:8]:
                    print(f"        • {k}: {colorize(str(v), Colors.RED)}")
                results['ethtool_drops'] = found_drops
            else:
                print(f"    {colorize('✔', Colors.GREEN)} Ethtool hardware error/drop counters are 0.")
    
    # 2. CPU Softnet drops (/proc/net/softnet_stat)

    # 2. Wi-Fi Power Management & Signal Check
    is_wifi = iface and (iface.startswith("wl") or os.path.exists(f"/sys/class/net/{iface}/wireless"))
    if is_wifi:
        print(f"[*] Wireless Interface Detected ({iface}):")
        code, out, _ = run_cmd(f"iw dev {iface} get power_save")
        power_save = None
        if code == 0 and out:
            power_save = out.split()[-1]
            if power_save == "on":
                print(f"    {colorize('[!][Wi-Fi Power Save] Active (Power Management: ON)', Colors.YELLOW)}")
                print(f"        {colorize('→ Wi-Fi power-saving is known on Linux to cause 100-300ms latency spikes and periodic packet drops.', Colors.YELLOW)}")
            elif power_save == "off":
                print(f"    {colorize('✔', Colors.GREEN)} Wi-Fi Power Management is OFF (Low-latency mode active).")
        
        # Check signal strength
        code, out, _ = run_cmd(f"iw dev {iface} link")
        if code == 0 and out:
            sig_match = re.search(r'signal:\s*(-?\d+\s*dBm)', out)
            rate_match = re.search(r'tx bitrate:\s*([0-9.]+\s*[A-Za-z/]+)', out)
            sig_str = sig_match.group(1) if sig_match else "Unknown"
            rate_str = rate_match.group(1) if rate_match else "Unknown"
            print(f"    - Signal Strength: {colorize(sig_str, Colors.BOLD)} | TX Bitrate: {rate_str}")
            results['wifi'] = {'power_save': power_save, 'signal': sig_str, 'bitrate': rate_str}

    # 3. CPU Softnet drops (/proc/net/softnet_stat)
    if os.path.exists("/proc/net/softnet_stat"):
        try:
            with open("/proc/net/softnet_stat", "r") as f:
                softnet_lines = f.readlines()
            total_dropped = 0
            total_squeezed = 0
            for line in softnet_lines:
                cols = line.split()
                if len(cols) >= 3:
                    total_dropped += int(cols[1], 16)
                    total_squeezed += int(cols[2], 16)
            
            softnet_status = Colors.GREEN if total_dropped == 0 else Colors.RED
            print(f"[*] Kernel CPU Softnet Processing:")
            print(f"    - Packets dropped by CPU budget (netdev_max_backlog): {colorize(str(total_dropped), softnet_status)}")
            print(f"    - Packets dropped by CPU backlog (netdev_max_backlog): {colorize(str(total_dropped), softnet_status)}")
            print(f"    - Out of quota / SoftIRQ squeezed (net.core.netdev_budget): {total_squeezed}")
            results['softnet'] = {'dropped': total_dropped, 'squeezed': total_squeezed}
        except Exception:
            pass

    # 3. Conntrack saturation check
    # 4. Conntrack saturation check
    conntrack_count_file = "/proc/sys/net/netfilter/nf_conntrack_count"
    conntrack_max_file = "/proc/sys/net/netfilter/nf_conntrack_max"
    if os.path.exists(conntrack_count_file) and os.path.exists(conntrack_max_file):
        try:
            with open(conntrack_count_file, "r") as f:
                c_count = int(f.read().strip())
            with open(conntrack_max_file, "r") as f:
                c_max = int(f.read().strip())
            usage_pct = (c_count / c_max) * 100 if c_max > 0 else 0
            c_color = Colors.GREEN if usage_pct < 80 else (Colors.YELLOW if usage_pct < 95 else Colors.RED)
            print(f"[*] Conntrack State Table: {colorize(f'{c_count}/{c_max} ({usage_pct:.1f}%)', c_color)}")
            results['conntrack'] = {'count': c_count, 'max': c_max, 'usage_pct': usage_pct}
        except Exception:
            pass

    # 5. ARP / Neighbor Gateway check
    if gateway:
        code, out, _ = run_cmd(f"ip neigh show {gateway}")
        if code == 0 and out:
            gw_state = out.split()[-1]
            if gw_state in ["FAILED", "INCOMPLETE"]:
                print(f"    {colorize('[!][ARP / Neighbor] Default Gateway ' + gateway + ' state is ' + gw_state, Colors.RED)}")
            else:
                print(f"    {colorize('✔', Colors.GREEN)} ARP Gateway neighbor entry: {gateway} ({gw_state})")
            results['arp_gateway'] = gw_state
            
    return results

def test_icmp_ping(target_ip, source_ip=None, count=10):
    """Tests ICMP packet loss and round-trip latency."""
    print_sub_header(f"Phase 2: ICMP Layer Packet Loss & Latency Test ({count} packets)")
def test_dual_icmp_ping(target_ip, gateway=None, source_ip=None, count=5):
    """Tests ICMP packet loss to both Gateway (LAN) and Target (End-to-End) concurrently."""
    print_sub_header(f"Phase 2: Dual Gateway vs. Target ICMP Isolation ({count} packets)")
    results = {'gateway': None, 'target': None}

    # 1. Gateway Ping (LAN Isolation)
    if gateway:
        print(f"[*] Probing Local Gateway ({gateway}) to isolate LAN vs WAN loss...")
        code, out, _ = run_cmd(f"ping -c {count} -W 1 {gateway}", timeout=count + 4)
        gw_res = {'sent': count, 'received': 0, 'loss_pct': 100.0, 'rtt_avg': None}
        if code == 0 or out:
            loss_m = re.search(r'(\d+)% packet loss', out)
            if loss_m: gw_res['loss_pct'] = float(loss_m.group(1))
            rtt_m = re.search(r'min/avg/max/(?:mdev|stddev)\s*=\s*[0-9.]+/([0-9.]+)', out)
            if rtt_m: gw_res['rtt_avg'] = float(rtt_m.group(1))
        
        gw_col = Colors.GREEN if gw_res['loss_pct'] == 0 else Colors.RED
        gw_loss_str = f"{gw_res['loss_pct']} %"
        print(f"    - Gateway ({gateway}): Loss = {colorize(gw_loss_str, gw_col)} | Avg Latency = {gw_res['rtt_avg'] or 'N/A'} ms")
        results['gateway'] = gw_res

    # 2. Target Ping
    print(f"[*] Probing Target IP ({target_ip})...")
    cmd = f"ping -c {count} -W 1 "
    if source_ip:
        cmd += f"-I {source_ip} "
    if source_ip: cmd += f"-I {source_ip} "
    cmd += target_ip
    
    code, out, _ = run_cmd(cmd, timeout=count + 5)
    result = {
        'sent': count,
        'received': 0,
        'loss_pct': 100.0,
        'rtt_min': None,
        'rtt_avg': None,
        'rtt_max': None,
        'rtt_mdev': None,
        'raw': out
    }
    
    code, out, _ = run_cmd(cmd, timeout=count + 4)
    tgt_res = {'sent': count, 'received': 0, 'loss_pct': 100.0, 'rtt_min': None, 'rtt_avg': None, 'rtt_max': None, 'rtt_mdev': None}
    if code == 0 or out:
        loss_match = re.search(r'(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets\s+)?received.*?(?:(\d+(?:\.\d+)?)%\s+packet loss)', out)
        if loss_match:
            result['sent'] = int(loss_match.group(1))
            result['received'] = int(loss_match.group(2))
            result['loss_pct'] = float(loss_match.group(3))
        
        rtt_match = re.search(r'min/avg/max/(?:mdev|stddev)\s*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)', out)
        if rtt_match:
            result['rtt_min'] = float(rtt_match.group(1))
            result['rtt_avg'] = float(rtt_match.group(2))
            result['rtt_max'] = float(rtt_match.group(3))
            result['rtt_mdev'] = float(rtt_match.group(4))
        loss_m = re.search(r'(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets\s+)?received.*?(?:(\d+(?:\.\d+)?)%\s+packet loss)', out)
        if loss_m:
            tgt_res['sent'] = int(loss_m.group(1))
            tgt_res['received'] = int(loss_m.group(2))
            tgt_res['loss_pct'] = float(loss_m.group(3))
        rtt_m = re.search(r'min/avg/max/(?:mdev|stddev)\s*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)', out)
        if rtt_m:
            tgt_res['rtt_min'] = float(rtt_m.group(1))
            tgt_res['rtt_avg'] = float(rtt_m.group(2))
            tgt_res['rtt_max'] = float(rtt_m.group(3))
            tgt_res['rtt_mdev'] = float(rtt_m.group(4))

    loss_val = result["loss_pct"]
    loss_col = Colors.GREEN if loss_val == 0 else (Colors.YELLOW if loss_val < 10 else Colors.RED)
    print(f"[*] Packets: Sent={result['sent']}, Received={result['received']}, Loss={colorize(f'{loss_val} %', loss_col + Colors.BOLD)}")
    if result['rtt_avg'] is not None:
        rtt_avg_str = f"{result['rtt_avg']} ms"
        print(f"[*] Latency: Min={result['rtt_min']} ms, Avg={colorize(rtt_avg_str, Colors.BOLD)}, Max={result['rtt_max']} ms, Jitter (mdev)={result['rtt_mdev']} ms")
    else:
        print(f"    {colorize('[!]', Colors.YELLOW)} ICMP response not received. Target or intermediate firewall might be blocking ICMP.")
    t_loss = tgt_res["loss_pct"]
    t_col = Colors.GREEN if t_loss == 0 else (Colors.YELLOW if t_loss < 10 else Colors.RED)
    print(f"    - Target ({target_ip}): Loss = {colorize(f'{t_loss} %', t_col + Colors.BOLD)} | Avg Latency = {tgt_res['rtt_avg'] or 'N/A'} ms")
    results['target'] = tgt_res

    return result
    # LAN vs WAN Isolation Summary
    if results['gateway'] and results['gateway']['loss_pct'] > 0:
        print(f"    {colorize('▶ Isolation Analysis: Packet drops originate on the LOCAL LAN / Wi-Fi / Gateway.', Colors.RED + Colors.BOLD)}")
    elif results['gateway'] and results['gateway']['loss_pct'] == 0 and t_loss > 0:
        print(f"    {colorize('▶ Isolation Analysis: Local LAN is 100% CLEAN. Packet drops are in the WAN / ISP / Remote Server.', Colors.YELLOW + Colors.BOLD)}")

    return results

def test_path_mtu(target_ip, source_ip=None):
    """Tests Path MTU and detects DF-bit (Don't Fragment) blackholing."""
    print_sub_header("Phase 3: Path MTU & Fragmentation Blackhole Detection")
    print(f"[*] Testing Path MTU & Fragmentation Blackhole Detection...")
    test_sizes = [1472, 1400, 1300, 1000, 500]
    discovered_mtu = None
    
    for size in test_sizes:
        cmd = f"ping -M do -s {size} -c 2 -W 1 "
        if source_ip:
            cmd += f"-I {source_ip} "
        cmd = f"ping -M do -s {size} -c 1 -W 1 "
        if source_ip: cmd += f"-I {source_ip} "
        cmd += target_ip
        code, out, _ = run_cmd(cmd, timeout=3)
        if "0% packet loss" in out or "1 packets received" in out or "2 received" in out:
        if "0% packet loss" in out or "1 packets received" in out or "1 received" in out:
            discovered_mtu = size + 28
            print(f"    {colorize('✔', Colors.GREEN)} Max ICMP payload {size} bytes (MTU {discovered_mtu}) passed without fragmentation.")
            print(f"    {colorize('✔', Colors.GREEN)} Max ICMP payload {size} bytes (MTU {discovered_mtu}) passed cleanly without fragmentation.")
            break
        elif "Frag needed" in out or "Message too long" in out:
            print(f"    {colorize('✘', Colors.YELLOW)} Payload {size} bytes: Fragmentation needed / MTU exceeded.")
        else:
            print(f"    {colorize('✘', Colors.RED)} Payload {size} bytes: Dropped or timed out.")
            print(f"    {colorize('✘', Colors.YELLOW)} Payload {size} bytes: Fragmentation needed / Path MTU exceeded.")
            
    if discovered_mtu:
        if discovered_mtu >= 1500:
            print(f"[*] PMTU Status: Standard MTU (1500 bytes) works cleanly.")
        else:
            print(f"[*] {colorize('WARNING:', Colors.YELLOW)} Path MTU is reduced ({discovered_mtu} bytes). Ensure TCP MSS Clamping or lower MTU is configured to avoid transaction drops on large payloads.")
    else:
        print(f"[*] Path MTU Ping Test Inconclusive (ICMP with DF-bit dropped or blocked).")
    if discovered_mtu and discovered_mtu < 1500:
        print(f"    {colorize('[!] Path MTU is reduced (' + str(discovered_mtu) + ' bytes). Ensure TCP MSS Clamping is active.', Colors.YELLOW)}")
    return discovered_mtu

def test_tcp_port_transactions(target_ip, port, source_ip=None, count=30, interval=0.2, timeout=2.0):
def test_hop_by_hop_mtr(target_ip):
    """Traces hop-by-hop packet loss using MTR or tracepath."""
    print_sub_header("Phase 3: Hop-by-Hop Path Loss & Jitter Analysis")
    code, out, _ = run_cmd(f"mtr -r -c 5 -n {target_ip}", timeout=15)
    if code == 0 and out:
        print(out)
        return out
    
    code, out, _ = run_cmd(f"tracepath -n {target_ip}", timeout=10)
    if code == 0 and out:
        print("\n".join(out.splitlines()[:12]))
        return out
        
    code, out, _ = run_cmd(f"traceroute -n -w 1 -q 2 {target_ip}", timeout=10)
    if code == 0 and out:
        print("\n".join(out.splitlines()[:12]))
        return out
    
    print("    Hop trace utilities (mtr/tracepath/traceroute) not found.")
    return None

def test_dns_health(target_host):
    """Tests repeated DNS resolution stability and latency jitter."""
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', target_host):
        return None
        
    print_sub_header(f"Phase 4: DNS Resolution Stability & Latency Probes")
    print(f"[*] Testing 5 consecutive DNS lookups for '{colorize(target_host, Colors.BOLD)}'...")
    latencies = []
    failures = 0
    
    for _ in range(5):
        t_start = time.perf_counter()
        try:
            socket.gethostbyname(target_host)
            latencies.append((time.perf_counter() - t_start) * 1000.0)
        except Exception:
            failures += 1
        time.sleep(0.05)
        
    avg_dns = statistics.mean(latencies) if latencies else None
    if avg_dns is not None:
        dns_col = Colors.GREEN if avg_dns < 50 else Colors.YELLOW
        print(f"    - DNS Lookup Avg Latency: {colorize(f'{avg_dns:.1f} ms', dns_col)}")
    if failures > 0:
        print(f"    {colorize(f'[!][DNS Flapping] Detected {failures}/5 DNS resolution failures.', Colors.RED)}")
    else:
        print(f"    {colorize('✔', Colors.GREEN)} All DNS lookups resolved consistently.")
        
    return {'avg_ms': avg_dns, 'failures': failures}

def test_tcp_port_transactions(target_ip, port, source_ip=None, count=30, duration=0, interval=0.2, timeout=2.0, verbose=False):
    """
    Performs active TCP SYN connection handshake tests from Source IP to Target IP:Port.
    Measures drop rate, connection refused rate, handshake RTT latency, and jitter.
    Measures drop rate, connection refused rate, handshake RTT latency, jitter, and burst patterns.
    """
    print_sub_header(f"Phase 4: Targeted Port-Level TCP Transaction Probes (Port {port})")
    print(f"[*] Probing {colorize(f'{target_ip}:{port}', Colors.BOLD)} from source {source_ip or 'auto'} ({count} probes, interval={interval}s, timeout={timeout}s)...")
    print_sub_header(f"Phase 5: Targeted Port-Level TCP Transaction Probes (Port {port})")
    mode_str = f"{count} probes" if duration <= 0 else f"duration mode: {duration}s"
    print(f"[*] Probing {colorize(f'{target_ip}:{port}', Colors.BOLD)} (Timeout={timeout}s, Interval={interval}s, {mode_str})...")
    
    latencies = []
    successes = 0
    timeouts = 0
    refused = 0
    other_errors = 0
    error_details = []
    consecutive_drops = 0
    max_burst_drops = 0
    
    print("\n   Progress: [", end="", flush=True)
    print("   Progress: [", end="", flush=True)
    loop_start = time.time()
    probe_num = 0
    
    for i in range(count):
    while True:
        probe_num += 1
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        
        if source_ip:
            try:
                s.bind((source_ip, 0))
            except Exception as e:
                error_details.append(f"Bind error: {e}")
                pass
                
        t_start = time.perf_counter()
        ts_now = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
        try:
            s.connect((target_ip, port))
            t_rtt = (time.perf_counter() - t_start) * 1000.0
            latencies.append(t_rtt)
            successes += 1
            consecutive_drops = 0
            print(colorize(".", Colors.GREEN), end="", flush=True)
        except socket.timeout:
            timeouts += 1
            consecutive_drops += 1
            if consecutive_drops > max_burst_drops: max_burst_drops = consecutive_drops
            print(colorize("T", Colors.RED), end="", flush=True)
            error_details.append(f"Probe #{i+1}: Timeout (Drop / Silent Discard)")
            error_details.append(f"[{ts_now}] Probe #{probe_num}: Timeout (SYN Drop / No Response) after {timeout}s")
        except ConnectionRefusedError:
            refused += 1
            consecutive_drops += 1
            if consecutive_drops > max_burst_drops: max_burst_drops = consecutive_drops
            print(colorize("R", Colors.YELLOW), end="", flush=True)
            error_details.append(f"Probe #{i+1}: Connection Refused (TCP RST received)")
            error_details.append(f"[{ts_now}] Probe #{probe_num}: Connection Refused (TCP RST received)")
        except Exception as e:
            other_errors += 1
            consecutive_drops += 1
            if consecutive_drops > max_burst_drops: max_burst_drops = consecutive_drops
            print(colorize("E", Colors.RED), end="", flush=True)
            error_details.append(f"Probe #{i+1}: Error: {str(e)}")
            error_details.append(f"[{ts_now}] Probe #{probe_num}: Error: {str(e)}")
        finally:
            try:
                s.close()
            except Exception:
                pass
            try: s.close()
            except Exception: pass
            
        if duration > 0:
            if (time.time() - loop_start) >= duration:
                break
        else:
            if probe_num >= count:
                break
                
        if i < count - 1:
            time.sleep(interval)
        time.sleep(interval)
            
    print("] Done.\n")
    
    total_probes = probe_num
    drop_count = timeouts + other_errors
    total_failures = timeouts + refused + other_errors
    drop_pct = (drop_count / count) * 100.0
    failure_pct = (total_failures / count) * 100.0
    drop_pct = (drop_count / total_probes) * 100.0 if total_probes > 0 else 0.0
    failure_pct = (total_failures / total_probes) * 100.0 if total_probes > 0 else 0.0
    
    rtt_min = min(latencies) if latencies else None
    rtt_max = max(latencies) if latencies else None
    rtt_avg = statistics.mean(latencies) if latencies else None
    rtt_stddev = statistics.stdev(latencies) if len(latencies) > 1 else 0.0
    
    status_col = Colors.GREEN if drop_pct == 0 and refused == 0 else (Colors.YELLOW if drop_pct < 5 else Colors.RED)
    
    print(f"[*] TCP Transaction Results:")
    print(f"    - Total Probes Sent : {count}")
    print(f"    - Total Probes Sent     : {total_probes}")
    print(f"    - Successful Handshakes : {colorize(str(successes), Colors.GREEN)}")
    print(f"    - Dropped / Timed Out  : {colorize(str(timeouts), Colors.RED if timeouts > 0 else Colors.GREEN)}")
    print(f"    - Rejected (TCP RST)   : {colorize(str(refused), Colors.YELLOW if refused > 0 else Colors.GREEN)}")
    print(f"    - Packet / SYN Drop Rate: {colorize(f'{drop_pct:.1f}%', status_col + Colors.BOLD)}")
    if max_burst_drops > 1:
        print(f"    - Drop Pattern Detected : {colorize(f'Burst Flapping ({max_burst_drops} consecutive drops)', Colors.YELLOW)}")
    
    if latencies:
        print(f"[*] TCP Handshake (SYN -> SYN-ACK) RTT Latency:")
        print(f"    - Min Latency   : {rtt_min:.2f} ms")
        print(f"    - Avg Latency   : {colorize(f'{rtt_avg:.2f} ms', Colors.BOLD)}")
        print(f"    - Max Latency   : {rtt_max:.2f} ms")
        print(f"    - Jitter/StdDev : {rtt_stddev:.2f} ms")
        
    if error_details:
        print(f"\n    {colorize('Sample Failure Logs:', Colors.YELLOW)}")
        for err in error_details[:6]:
        print(f"\n    {colorize('Timestamped Failure Log (Sample):', Colors.YELLOW)}")
        for err in error_details[:8]:
            print(f"      • {err}")
        if len(error_details) > 8:
            print(f"      • ... and {len(error_details) - 8} more failed events.")
            
    return {
        'count': count,
        'count': total_probes,
        'successes': successes,
        'timeouts': timeouts,
        'refused': refused,
        'drop_pct': drop_pct,
        'failure_pct': failure_pct,
        'rtt_min': rtt_min,
        'rtt_avg': rtt_avg,
        'rtt_max': rtt_max,
        'rtt_stddev': rtt_stddev,
        'max_burst_drops': max_burst_drops,
        'error_details': error_details
    }

def inspect_active_socket_telemetry(target_ip, port):
    """Queries kernel TCP socket telemetry using `ss -ti` for active flows to target."""
    print_sub_header("Phase 5: Active TCP Socket Internal Telemetry (Kernel Metrics)")
    print_sub_header("Phase 6: Active TCP Socket Internal Telemetry & Metric Deltas")
    code, out, _ = run_cmd(f"ss -t -i -e dst {target_ip}:{port}")
    if code == 0 and out.strip():
        lines = out.strip().splitlines()
        print(f"[*] Found {len(lines)//2 if len(lines) > 1 else len(lines)} active TCP socket flows to {target_ip}:{port}:")
        for line in lines[:10]:
        for line in lines[:8]:
            highlighted = line
            for kw in ['rtt:', 'retrans:', 'lost:', 'snd_cwnd:', 'rcv_space:', 'bytes_acked:']:
                if kw in highlighted:
                    highlighted = highlighted.replace(kw, colorize(kw, Colors.CYAN))
            print(f"    {highlighted}")
        return out
    else:
        print(f"[*] No active long-lived TCP sockets currently connected to {target_ip}:{port}.")
        print(f"[*] No active persistent TCP sockets currently connected to {target_ip}:{port}.")
        return None

def compute_snmp_deltas(before_stats, after_stats):
    """Computes changes in kernel TCP metrics during the test."""
    interesting_keys = [
        ('Tcp_RetransSegs', 'TCP Segments Retransmitted (Packet Drops / Retransmits)'),
        ('Tcp_InErrs', 'TCP Inbound Errors (Checksum / Corrupted packets)'),
        ('Tcp_OutRsts', 'TCP Reset Sent (RST Packets)'),
        ('TcpExt_TCPTimeouts', 'TCP Retransmission Timeouts (Severe packet loss)'),
        ('TcpExt_TCPLostRetransmit', 'TCP Retransmission Lost'),
        ('TcpExt_TCPFastRetrans', 'TCP Fast Retransmissions (Packet reordering or single drops)'),
        ('TcpExt_TCPBacklogDrop', 'TCP Socket Backlog Queue Overflow Drops'),
        ('TcpExt_TCPReqQFullDrop', 'TCP SYN Listen Queue Full Drops (Accept queue overflow)'),
        ('TcpExt_TCPZeroWindow', 'TCP Zero Window Advertised (Receiver buffer full)'),
        ('TcpExt_TCPMemoryPressures', 'TCP Memory Pressure Events')
        ('TcpExt_TCPReqQFullDrop', 'TCP SYN Listen Queue Full Drops (Accept queue overflow)')
    ]
    
    deltas = {}
    for k, desc in interesting_keys:
        val_before = before_stats.get(k, 0)
        val_after = after_stats.get(k, 0)
        diff = val_after - val_before
        if diff > 0:
            deltas[k] = (diff, desc)
            
    return deltas

def generate_root_cause_analysis(results):
    """Analyzes collected metrics and generates prioritized root cause diagnosis & fixes."""
    print_header("Comprehensive Diagnosis & Root Cause Analysis")
    
    findings = []
    recommendations = []
    
    tcp = results.get('tcp_probe', {})
    icmp = results.get('icmp', {})
    tcp = results.get('tcp_probe') or {}
    icmp = results.get('icmp') or {}
    gateway_icmp = icmp.get('gateway') or {}
    target_icmp = icmp.get('target') or {}
    mtu = results.get('mtu')
    nic = results.get('nic', {})
    deltas = results.get('kernel_deltas', {})
    nic = results.get('nic') or {}
    deltas = results.get('kernel_deltas') or {}
    wifi = nic.get('wifi') or {}
    dns = results.get('dns') or {}
    
    # 1. TCP Drop Analysis
    # 1. Gateway vs WAN Loss Isolation
    if gateway_icmp.get('loss_pct', 0) > 0:
        findings.append((
            Colors.RED,
            f"Local Default Gateway Packet Loss ({gateway_icmp['loss_pct']}%)",
            "Packet loss originates at the first hop (Local Wi-Fi router, Ethernet cable, or LAN switch)."
        ))
        recommendations.append("• Check local LAN hardware: Swap Ethernet cable, restart Wi-Fi router, or inspect AP channel congestion.")
        
    if gateway_icmp.get('loss_pct', 0) == 0 and target_icmp.get('loss_pct', 0) > 0:
        findings.append((
            Colors.YELLOW,
            f"WAN / ISP / Remote Route Packet Loss ({target_icmp['loss_pct']}%)",
            "Local LAN is healthy; packet loss occurs in upstream ISP transit or remote server firewall."
        ))
        recommendations.append("• Review Phase 3 MTR results to identify the specific intermediate router introducing loss.")

    # 2. Wi-Fi Power Save
    if wifi.get('power_save') == 'on':
        findings.append((
            Colors.YELLOW,
            "Wi-Fi Power Management Active (power_save=on)",
            "Linux kernel puts wireless adapter to sleep during idle periods, introducing 100-300ms latency spikes and dropped SYN packets."
        ))
        recommendations.append(f"• Disable Wi-Fi Power Saving immediately: `sudo iw dev {results.get('interface') or 'wlan0'} set power_save off`")
        recommendations.append("• Persist in NetworkManager: Add `[connection]\nwifi.powersave = 2` to `/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf` and restart NetworkManager.")

    # 3. TCP Drop Analysis
    if tcp.get('timeouts', 0) > 0:
        findings.append((
            Colors.RED,
            f"TCP Handshake Timeout / Drop ({tcp['timeouts']}/{tcp['count']} probes dropped - {tcp['drop_pct']:.1f}% loss)",
            "The client sent TCP SYN packets that received no SYN-ACK response from the target."
        ))
        recommendations.append(
            "• Intermediate Firewall / NAT State Table: Firewalls (or iptables/conntrack) dropping idle TCP sessions or overflowing connection tracking tables."
        )
        recommendations.append(
            "• Target Server SYN Backlog: Target Linux server's `tcp_max_syn_backlog` or application `listen(backlog)` queue is saturated."
        )
        recommendations.append(
            "• Network Packet Loss: Intermediate router/switch packet discard due to congestion or faulty link."
            "• TCP Keepalive Tuning: Prevent stateful firewall/NAT drop on idle connections: `sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=10 net.ipv4.tcp_keepalive_probes=6`"
        )
        
    if tcp.get('refused', 0) > 0:
        findings.append((
            Colors.YELLOW,
            f"TCP Connection Refused (RST) ({tcp['refused']}/{tcp['count']} probes rejected)",
            "The target system actively sent TCP RST. The port is either closed, service restarted, or firewall rejects."
        ))
        recommendations.append(
            "• Target Application Health: The backend service on the target machine might be crashing, restarting, or rejecting new connections."
            "• Target Application Health: The backend service on the target machine might be crashing, restarting, or hitting max worker limits."
        )

    # Latency / Jitter Check
    if (tcp.get('rtt_stddev') or 0) > 20.0 or ((tcp.get('rtt_max') or 0) - (tcp.get('rtt_min') or 0)) > 50.0:
        findings.append((
            Colors.YELLOW,
            f"High TCP Latency Jitter (Min: {tcp.get('rtt_min'):.1f}ms, Max: {tcp.get('rtt_max'):.1f}ms, StdDev: {tcp.get('rtt_stddev'):.1f}ms)",
            "High variance in TCP connection establishment indicates network bufferbloat, route flapping, or CPU spikes."
        ))
        recommendations.append("• Enable FQ / BBR Congestion Control: `sysctl -w net.core.default_qdisc=fq` and `sysctl -w net.ipv4.tcp_congestion_control=bbr`")

    # 2. ICMP vs TCP Discrepancy
    if icmp.get('loss_pct', 0) == 0 and tcp.get('drop_pct', 0) > 0:
    # ICMP vs TCP Discrepancy
    if target_icmp.get('loss_pct', 0) == 0 and tcp.get('drop_pct', 0) > 0:
        findings.append((
            Colors.RED,
            "ICMP is 100% Healthy but TCP Transactions are Dropping",
            "Network layer routing is intact, but L4/Application layer is failing (Firewall state timeout, Target SYN drops, or Port-specific filtering)."
        ))

    # 3. Kernel Retransmission Deltas
    # Kernel Retransmission Deltas
    if deltas:
        print(f"\n[*] {colorize('Kernel TCP Events During Diagnostic Run:', Colors.BOLD)}")
        for k, (diff, desc) in deltas.items():
            print(f"    • {colorize(f'+{diff}', Colors.RED if 'Retrans' in k or 'Drop' in k else Colors.YELLOW)} : {desc} ({k})")
            
        if 'TcpExt_TCPBacklogDrop' in deltas or 'TcpExt_TCPReqQFullDrop' in deltas:
            findings.append((
                Colors.RED,
                "Kernel Socket Backlog Drops Detected",
                "Local Linux kernel is dropping incoming/outgoing socket queues due to full backlog."
            ))
            recommendations.append("• Increase kernel socket backlog: `sysctl -w net.core.somaxconn=65535` and `sysctl -w net.ipv4.tcp_max_syn_backlog=65535`")
            
        if 'Tcp_RetransSegs' in deltas or 'TcpExt_TCPTimeouts' in deltas:
            recommendations.append("• TCP Retransmissions detected in kernel stack. Check TCP keepalive settings to prevent silent NAT drop: `sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=10 net.ipv4.tcp_keepalive_probes=6`")

    # 4. NIC Hardware Drops
    nic_drops = nic.get('ethtool_drops', [])
    if nic_drops:
    # Path MTU
    if mtu and mtu < 1500:
        findings.append((
            Colors.YELLOW,
            "Local NIC Hardware Buffer Drops Detected",
            f"Interface recorded drops in hardware queues ({', '.join([k for k, _ in nic_drops[:3]])})."
            f"Reduced Path MTU ({mtu} bytes)",
            "Path MTU is smaller than standard 1500 bytes. Large payload packets may be dropped if DF bit is set."
        ))
        recommendations.append("• Increase NIC Ring Buffers: Check max ring buffer with `ethtool -g <iface>` and increase using `ethtool -G <iface> rx 4096 tx 4096`")
        recommendations.append("• Enable TCP MTU Probing: `sysctl -w net.ipv4.tcp_mtu_probing=1` or clamp MSS in iptables.")

    # DNS Flapping
    if dns.get('failures', 0) > 0:
        findings.append((
            Colors.RED,
            f"DNS Resolution Failures ({dns['failures']}/5 queries dropped)",
            "Intermittent DNS timeouts observed."
        ))
        recommendations.append("• Switch to reliable low-latency DNS resolvers (e.g., 1.1.1.1, 8.8.8.8) or inspect systemd-resolved.")

    # Display Findings
    if findings:
        print(f"\n{colorize('Identified Issues & Root Causes:', Colors.BOLD)}")
        for color, title, desc in findings:
            print(f"  {colorize('▶', color)} {colorize(title, color + Colors.BOLD)}")
            print(f"    {desc}")
    else:
        print(f"\n  {colorize('✔ All diagnostic checks passed with 0% packet drop and healthy latency!', Colors.GREEN + Colors.BOLD)}")

    # Display Actionable Linux Troubleshooting Steps
    print(f"\n{colorize('Recommended Actionable Next Steps:', Colors.BOLD + Colors.CYAN)}")
    print(f"\n{colorize('Recommended Actionable Next Steps & Fixes:', Colors.BOLD + Colors.CYAN)}")
    if recommendations:
        for rec in recommendations:
            print(f"  {rec}")
    else:
        port_arg = f"-p {results.get('port')}" if results.get('port') else ""
        print("  • Network and port connectivity are healthy. If intermittent drops still occur in production:")
        print("    1. Run this script in continuous mode: `./diagnose_network_drops.py -s <src> -d <dst> -p <port> -c 500 -i 0.1`")
        print(f"    1. Run this script in continuous duration mode: `./diagnose_network_drops.py -d {results.get('target_host')} {port_arg} -T 300 -i 0.1`")
        print("    2. Enable TCP Keepalives on your application socket to prevent intermediate firewall timeouts.")
        print("    3. Capture live TCP resets on the port: `sudo tcpdump -nn -i any 'tcp[tcpflags] & (tcp-rst|tcp-fin) != 0 and host <target_ip>'`")
        print(f"    3. Capture live TCP resets on the port: `sudo tcpdump -nn -i any 'tcp[tcpflags] & (tcp-rst|tcp-fin) != 0 and host {results.get('target_ip')}'`")

# Global results holder for SIGINT
_global_results = {}

def sigint_handler(sig, frame):
    print(f"\n\n{colorize('[!] Interrupted by user (SIGINT / Ctrl+C). Summarizing metrics gathered so far...', Colors.YELLOW)}")
    if _global_results:
        generate_root_cause_analysis(_global_results)
    sys.exit(0)

signal.signal(signal.SIGINT, sigint_handler)

def main():
    global _global_results
    parser = argparse.ArgumentParser(
        description="Comprehensive Linux Network & Packet Drop Diagnostic Tool for Transactions.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  ./diagnose_network_drops.py -d 192.168.1.100 -p 8080
  ./diagnose_network_drops.py -s 192.168.1.50 -d 10.0.0.5 -p 3306 -c 100 -i 0.1
  ./diagnose_network_drops.py -d 1.1.1.1 -p 443
  ./diagnose_network_drops.py -d google.com -c 50
  ./diagnose_network_drops.py -s 192.168.1.50 -d 10.0.0.5 -p 3306 -T 60 -i 0.1
  ./diagnose_network_drops.py --json
        """
    )
    parser.add_argument("-s", "--source-ip", help="Source IP to bind from (optional, auto-detected from route if omitted)")
    parser.add_argument("-d", "--target-ip", help="Target Server IP or Hostname")
    parser.add_argument("-p", "--port", type=int, help="Target Port number (e.g. 80, 443, 8080, 5432, 3306)")
    parser.add_argument("-d", "--target-ip", "--target", help="Target Server IP or Hostname")
    parser.add_argument("-p", "--port", type=int, help="Target Port number (e.g. 80, 443, 8080, 5432, 3306). Optional.")
    parser.add_argument("-c", "--count", type=int, default=30, help="Number of TCP probes to send (default: 30)")
    parser.add_argument("-T", "--duration", type=float, default=0, help="Duration in seconds to run probes (overrides -c)")
    parser.add_argument("-i", "--interval", type=float, default=0.2, help="Interval between probes in seconds (default: 0.2)")
    parser.add_argument("-t", "--timeout", type=float, default=2.0, help="Socket connect timeout in seconds (default: 2.0)")
    parser.add_argument("--no-mtr", action="store_true", help="Skip hop-by-hop traceroute (MTR)")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    
    args = parser.parse_args()
    
    target_ip = args.target_ip
    target_host = args.target_ip
    port = args.port
    source_ip = args.source_ip
    
    # Check if we need interactive input
    is_interactive = sys.stdin.isatty()
    
    if not target_ip:
    target_was_provided = bool(target_host)
    if not target_host:
        if is_interactive:
            try:
                target_ip = input(colorize("Enter Target IP or Hostname: ", Colors.BOLD + Colors.CYAN)).strip()
                target_host = input(colorize("Enter Target IP or Hostname (e.g. 1.1.1.1 or api.example.com): ", Colors.BOLD + Colors.CYAN)).strip()
            except (KeyboardInterrupt, EOFError):
                sys.exit(0)
        if not target_ip:
        if not target_host:
            print(colorize("Error: Target IP is required. Specify with -d <target_ip>", Colors.RED))
            sys.exit(1)
            
    if not port:
        if is_interactive:
            try:
                port_str = input(colorize("Enter Target Port (e.g. 80, 443, 8080, 3306): ", Colors.BOLD + Colors.CYAN)).strip()
                if port_str:
                    port = int(port_str)
            except (KeyboardInterrupt, EOFError):
                sys.exit(0)
            except ValueError:
                print(colorize("Error: Invalid port number.", Colors.RED))
                sys.exit(1)
        if not port:
            print(colorize("Error: Target Port is required. Specify with -p <port>", Colors.RED))
            sys.exit(1)
    if not target_was_provided and not port and is_interactive and not args.json:
        try:
            port_str = input(colorize("Enter Target TCP Port (e.g. 80, 443, 8080) [Press Enter to skip port test]: ", Colors.BOLD + Colors.CYAN)).strip()
            if port_str:
                port = int(port_str)
        except (KeyboardInterrupt, EOFError):
            sys.exit(0)
        except ValueError:
            print(colorize("Warning: Invalid port number. Proceeding without port-specific testing.", Colors.YELLOW))
            port = None
            
    try:
        resolved_target_ip = socket.gethostbyname(target_ip)
        resolved_target_ip = socket.gethostbyname(target_host)
    except socket.gaierror as e:
        print(colorize(f"Error: Unable to resolve hostname '{target_ip}': {e}", Colors.RED))
        print(colorize(f"Error: Unable to resolve hostname '{target_host}': {e}", Colors.RED))
        sys.exit(1)
        
    iface, gateway, route_src = get_routing_info(resolved_target_ip, source_ip)
    if not source_ip and route_src:
        source_ip = route_src

    if not args.source_ip and not args.target_ip and is_interactive:
        try:
            default_prompt = f" [Press Enter for auto-detected '{source_ip or '0.0.0.0'}']" if source_ip else ""
            src_input = input(colorize(f"Enter Source IP{default_prompt}: ", Colors.BOLD + Colors.CYAN)).strip()
            if src_input:
                source_ip = src_input
        except (KeyboardInterrupt, EOFError):
            sys.exit(0)

    print_header(f"Linux Network & Packet Drop Diagnostic: {source_ip or 'Default'} -> {resolved_target_ip}:{port}")
    print(f"[*] Timestamp       : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"[*] Source IP       : {source_ip or 'Auto-Bind'}")
    print(f"[*] Target Host/IP  : {target_ip} ({resolved_target_ip})")
    print(f"[*] Target Port     : {port}")
    print(f"[*] Outgoing Dev    : {iface or 'Unknown'} (Gateway: {gateway or 'Direct/Unknown'})")
    if not args.json:
        print_header(f"Linux Network & Packet Drop Diagnostic: {source_ip or 'Default'} -> {resolved_target_ip}{f':{port}' if port else ''}")
        print(f"[*] Timestamp       : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"[*] Source IP       : {source_ip or 'Auto-Bind'}")
        print(f"[*] Target Host/IP  : {target_host} ({resolved_target_ip})")
        print(f"[*] Target Port     : {port or 'None (Pure Network Path Mode)'}")
        print(f"[*] Outgoing Dev    : {iface or 'Unknown'} (Gateway: {gateway or 'Direct/Unknown'})")
    
    snmp_before = parse_proc_netstat()
    
    nic_results = check_nic_and_kernel_health(iface)
    icmp_results = test_icmp_ping(resolved_target_ip, source_ip=source_ip, count=min(5, args.count))
    nic_results = check_nic_and_kernel_health(iface, gateway=gateway)
    icmp_results = test_dual_icmp_ping(resolved_target_ip, gateway=gateway, source_ip=source_ip, count=min(5, args.count))
    mtu_results = test_path_mtu(resolved_target_ip, source_ip=source_ip)
    tcp_results = test_tcp_port_transactions(resolved_target_ip, port, source_ip=source_ip, count=args.count, interval=args.interval, timeout=args.timeout)
    active_sock = inspect_active_socket_telemetry(resolved_target_ip, port)
    
    mtr_results = None
    if not args.no_mtr:
        mtr_results = test_hop_by_hop_mtr(resolved_target_ip)
        
    dns_results = test_dns_health(target_host)
    
    tcp_results = None
    if port:
        tcp_results = test_tcp_port_transactions(resolved_target_ip, port, source_ip=source_ip, count=args.count, duration=args.duration, interval=args.interval, timeout=args.timeout)
        active_sock = inspect_active_socket_telemetry(resolved_target_ip, port)
    
    snmp_after = parse_proc_netstat()
    kernel_deltas = compute_snmp_deltas(snmp_before, snmp_after)
    
    results = {
        'timestamp': datetime.now().isoformat(),
        'source_ip': source_ip,
        'target_ip': resolved_target_ip,
        'target_host': target_ip,
        'target_host': target_host,
        'port': port,
        'interface': iface,
        'gateway': gateway,
        'nic': nic_results,
        'icmp': icmp_results,
        'mtu': mtu_results,
        'mtr': mtr_results,
        'dns': dns_results,
        'tcp_probe': tcp_results,
        'kernel_deltas': kernel_deltas
    }
    _global_results = results
    
    if args.json:
        print("\n" + json.dumps(results, indent=2))
    else:
        generate_root_cause_analysis(results)

if __name__ == "__main__":
    main()
