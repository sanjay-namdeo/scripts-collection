# Termux + PRoot Ubuntu & Antigravity CLI Setup Guide

A complete step-by-step guide for installing, configuring, and optimizing a 64-bit Linux environment with **PRoot Ubuntu**, **Antigravity CLI (`agy`)**, customized terminal colors, and remote SSH access on Android (e.g. Moto G5 running 64-bit ROM / `aarch64`).

---

## Table of Contents
1. [Architecture & Prerequisites](#1-architecture--prerequisites)
2. [Step 1: Install PRoot & Ubuntu in Termux](#2-step-1-install-proot--ubuntu-in-termux)
3. [Step 2: Setup Ubuntu Environment & Runtime Tools](#3-step-2-setup-ubuntu-environment--runtime-tools)
4. [Step 3: Install & Configure Antigravity CLI (`agy`)](#4-step-3-install--configure-antigravity-cli-agy)
5. [Step 4: Auto-Launch Ubuntu on Termux Startup](#5-step-4-auto-launch-ubuntu-on-termux-startup)
6. [Step 5: Enable Terminal Colors & Themes](#6-step-5-enable-terminal-colors--themes)
7. [Step 6: Remote SSH Setup (Phone to PC)](#7-step-6-remote-ssh-setup-phone-to-pc)
8. [Tips & Troubleshooting](#8-tips--troubleshooting)

---

## 1. Architecture & Prerequisites

Check your device architecture in Termux:
```bash
uname -m
```
- **`aarch64`**: 64-bit ARM architecture. Supported for standard 64-bit Linux containers and `agy` binaries.
- Standard Android uses Bionic libc; running standard Linux binaries requires **`proot-distro`** (GNU/Linux glibc container).

---

## 2. Step 1: Install PRoot & Ubuntu in Termux

Inside **native Termux**, run:

```bash
# Update Termux packages
pkg update && pkg upgrade -y

# Install proot-distro and SSH/network utilities
pkg install proot-distro openssh curl wget tar nano -y

# Install Ubuntu
proot-distro install ubuntu

# Log into Ubuntu container
proot-distro login ubuntu
```

---

## 3. Step 2: Setup Ubuntu Environment & Runtime Tools

Inside the **PRoot Ubuntu** shell (`root@localhost:~#`), install base runtime libraries and development tools:

```bash
apt update && apt upgrade -y
apt install -y curl wget git ca-certificates libglib2.0-0 nano
```

---

## 4. Step 3: Install & Configure Antigravity CLI (`agy`)

1. **Obtain the Linux ARM64 (`aarch64`) binary** of `agy` and save it to your phone storage (e.g. `Downloads`).
2. Grant Termux access to storage (run inside native Termux):
   ```bash
   termux-setup-storage
   ```
3. Move the binary into your PRoot Ubuntu installation:
   ```bash
   # Inside PRoot Ubuntu:
   mkdir -p /root/.local/bin

   # Copy from Android Downloads folder
   cp /data/data/com.termux/files/home/storage/downloads/agy /root/.local/bin/agy

   # Make it executable
   chmod +x /root/.local/bin/agy

   # Add ~/.local/bin to PATH
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc
   source /root/.bashrc
   ```
4. **Launch and Authenticate**:
   ```bash
   agy
   ```

---

## 5. Step 4: Auto-Launch Ubuntu on Termux Startup

To have Termux automatically open into Ubuntu whenever you open the app:

Run inside **native Termux**:

```bash
# Auto-launch Ubuntu on Termux open
echo "proot-distro login ubuntu" >> ~/.bashrc
```

> **Note:** If you want Termux to exit completely when you type `exit` in Ubuntu, use:
> ```bash
> echo "proot-distro login ubuntu; exit" >> ~/.bashrc
> ```

---

## 6. Step 5: Enable Terminal Colors & Themes

### A. Colorful Ubuntu Prompt & `ls` Colors
Run inside **PRoot Ubuntu**:

```bash
cat << 'EOF' >> ~/.bashrc

# Enable 256-color support
export TERM=xterm-256color

# Colorized prompt: Green username@hostname, Blue directory path
export PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '

# Colorized aliases
alias ls='ls --color=auto'
alias ll='ls -lh --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
EOF

source ~/.bashrc
```

### B. Termux Dark Theme (Dracula Palette)
Run inside **native Termux** (press `Ctrl+C` on startup or exit Ubuntu):

```bash
mkdir -p ~/.termux
cat << 'EOF' > ~/.termux/colors.properties
background = #1e1f29
foreground = #f8f8f2
cursor = #bbbbbb
color0 = #000000
color1 = #ff5555
color2 = #50fa7b
color3 = #f1fa8c
color4 = #bd93f9
color5 = #ff79c6
color6 = #8be9fd
color7 = #bfbfbf
color8 = #4d4d4d
color9 = #ff6e67
color10 = #5af78e
color11 = #f4f99d
color12 = #caa9fa
color13 = #ff92d0
color14 = #8be9fd
color15 = #e6e6e6
EOF

# Apply the theme immediately
termux-reload-settings
```

---

## 7. Step 6: Remote SSH Setup (Phone to PC)

Running `agy` on your computer and controlling it from your phone avoids mobile RAM constraints.

1. **On your PC**:
   ```bash
   # Start the SSH server
   sudo systemctl start ssh
   ```
2. **On your Phone (Termux)**:
   ```bash
   # Connect directly to the PC session
   ssh sanjay-namdeo@192.168.1.36 -t ~/.local/bin/agy
   ```

---

## 8. Tips & Troubleshooting

- **Bypass Auto-login to Ubuntu**: Press `Ctrl + C` immediately after opening Termux.
- **Memory Management**: If Android kills Termux due to RAM limits (OOM), disable background battery optimizations for Termux in Android Settings.
- **Run agy from native Termux as an alias**:
  ```bash
  alias agy="proot-distro login ubuntu -- /root/.local/bin/agy"
  ```
