#!/usr/bin/env python3
import os
import re
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import font as tkfont

HOME = Path.home()
SUPPORT = HOME / ".local" / "share"
CONFIG = HOME / ".config"
BAD_DISCORD = {
    "discord", "null", "undefined", "username", "everyone", "here",
    "system", "webhook", "clyde", "unknown", "true", "false",
}


def resource(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def read_text(path, limit=8_000_000):
    try:
        size = path.stat().st_size
        if size <= 0 or size >= limit:
            return ""
        return path.read_bytes().decode("utf-8", "replace")
    except OSError:
        return ""


def walk(root, limit, allow):
    out = []
    if not root.is_dir():
        return out
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("app", "modules", "discord_desktop_core")]
        for name in filenames:
            path = Path(dirpath) / name
            if len(out) >= limit:
                return out
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if allow(path, size):
                out.append(path)
    return out


def groups(text, pattern):
    return [m.groups() for m in re.finditer(pattern, text, re.I | re.S)]


def scan(mode, target):
    rows = []
    seen = set()

    def add(kind, user, account, source, note):
        user = (user or "").strip()[:64]
        account = (account or "").strip()[:120]
        if not user and not account:
            return
        key = f"{kind}|{user}|{account}".lower()
        if key in seen:
            return
        seen.add(key)
        rows.append((kind, user, account, source, note))

    def add_mc(text, source):
        if not text:
            return
        for name, user in groups(text, r'"minecraftProfile"\s*:\s*\{.{0,500}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})".{0,800}?"username"\s*:\s*"([^"]{2,80})"'):
            add("Minecraft Java", name, user, source, "")
        for user, name in groups(text, r'"username"\s*:\s*"([^"]{2,80})".{0,800}?"minecraftProfile"\s*:\s*\{.{0,400}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})"'):
            add("Minecraft Java", name, user, source, "")
        for (name,) in groups(text, r'"displayName"\s*:\s*"([A-Za-z0-9_]{3,16})"'):
            add("Minecraft", name, "", source, "")
        for old, new in groups(text, r'"originalUsername"\s*:\s*"([A-Za-z0-9_]{3,16})".{0,300}?"minecraftUsername"\s*:\s*"([A-Za-z0-9_]{3,16})"'):
            add("Minecraft", new, old, source, "" if old == new else "[RENAMED]")
        for name, uuid in groups(text, r'\{[^{}]*"name"\s*:\s*"([A-Za-z0-9_]{3,16})"[^{}]*"uuid"\s*:\s*"([^"]+)"'):
            add("Minecraft", name, uuid, source, "(This username was found in the past on this PC)")
        for (name,) in groups(text, r"Loaded content for \[\s*([A-Za-z0-9_]{3,16})\s*\]"):
            add("Lunar", name, "", source, "")
        for (name,) in groups(text, r"Got Lunar Client Token for \s*([A-Za-z0-9_]{3,16})"):
            add("Lunar", name, "", source, "")
        for (name,) in groups(text, r"Auth config: mode=Authenticated,.*name=([A-Za-z0-9_]{3,16})"):
            add("Hytale", name, "", source, "")
        for (name,) in groups(text, r"--name\s+([A-Za-z0-9_]{3,16})"):
            add("Minecraft", name, "", source, "")

    mc_dirs = [
        HOME / ".minecraft", HOME / ".lunarclient", HOME / ".feather",
        SUPPORT / "minecraft", SUPPORT / "lunarclient", SUPPORT / "feather",
        SUPPORT / "PrismLauncher", SUPPORT / "PolyMC", SUPPORT / "MultiMC",
        SUPPORT / "modrinth", SUPPORT / "atlauncher", SUPPORT / "gdlauncher",
        SUPPORT / "Badlion Client", SUPPORT / "Minecraft Launcher",
        HOME / ".var/app/com.mojang.Minecraft/data/minecraft",
        HOME / ".var/app/com.mojang.Minecraft/.minecraft",
    ]
    direct = [
        "launcher_accounts.json", "launcher_profiles.json", "accounts.json",
        "usercache.json", "usernamecache.json",
    ]
    for folder in mc_dirs:
        for name in direct:
            path = folder / name
            if path.is_file():
                add_mc(read_text(path), str(path))
        for path in walk(folder, 80, lambda p, size: 0 < size < 8_000_000 and re.search(r"account|launcher_accounts|launcher_profiles|usercache|usernamecache|\.log$", p.name, re.I)):
            add_mc(read_text(path), str(path))

    if mode != "minecraft":
        steam_files = [
            HOME / ".steam/steam/config/loginusers.vdf",
            HOME / ".steam/root/config/loginusers.vdf",
            SUPPORT / "Steam/config/loginusers.vdf",
            HOME / ".var/app/com.valvesoftware.Steam/.steam/steam/config/loginusers.vdf",
        ]
        for steam in steam_files:
            text = read_text(steam, 2_000_000)
            if not text:
                continue
            for account, persona in groups(text, r'"AccountName"\s*"([^"]+)".{0,400}?"PersonaName"\s*"([^"]+)"'):
                add("Steam", persona, account, str(steam), "")
            for persona, account in groups(text, r'"PersonaName"\s*"([^"]+)".{0,400}?"AccountName"\s*"([^"]+)"'):
                add("Steam", persona, account, str(steam), "")
        discord_dirs = [
            CONFIG / "discord", CONFIG / "discordcanary", CONFIG / "discordptb",
            CONFIG / "discorddevelopment", CONFIG / "Vesktop", CONFIG / "vesktop",
            CONFIG / "ArmCord", CONFIG / "Vencord", CONFIG / "Lightcord",
            HOME / ".var/app/com.discordapp.Discord/config/discord",
        ]
        patterns = [
            (r'"username"\s*:\s*"([^"\\]{2,32})".{0,180}?"id"\s*:\s*"(\d{17,20})"', 0, 1),
            (r'"id"\s*:\s*"(\d{17,20})".{0,180}?"username"\s*:\s*"([^"\\]{2,32})"', 1, 0),
            (r'"username"\s*:\s*"([^"\\]{2,32})".{0,120}?"global_name"\s*:\s*"([^"\\]{1,64})"', 0, 1),
            (r'"global_name"\s*:\s*"([^"\\]{1,64})".{0,120}?"username"\s*:\s*"([^"\\]{2,32})"', 1, 0),
        ]
        for root in discord_dirs:
            if not root.is_dir():
                continue
            preferred = [root / p for p in ("Local Storage/leveldb", "Session Storage", "logs", "IndexedDB", "Network") if (root / p).is_dir()]
            scan_roots = preferred or [root]
            for scan_root in scan_roots:
                for path in walk(scan_root, 60, lambda p, size: 0 < size < 20_000_000 and p.suffix.lower() in {".ldb", ".log", ".old", ".sqlite", ".json"}):
                    text = read_text(path, 20_000_000)
                    if not text:
                        continue
                    for pattern, ui, ai in patterns:
                        for match in groups(text, pattern):
                            user = match[ui]
                            extra = "" if match[ai] == "null" else match[ai]
                            if user.lower() in BAD_DISCORD:
                                continue
                            add("Discord", user, extra, str(path), "")
        users = Path("/home")
        if users.is_dir():
            for user in users.iterdir():
                if user.name not in {"lost+found"} and user.is_dir():
                    add("Linux User", user.name, "", str(user), "")

    if mode == "target":
        query = target.strip()
        if not query:
            rows = []
        else:
            rows = [row for row in rows if any(query.lower() in part.lower() for part in row[:4])]
            seen_path = set()
            roots = [HOME / name for name in ("Desktop", "Documents", "Downloads")] + mc_dirs
            roots += [CONFIG / name for name in ("discord", "discordcanary", "discordptb", "Vesktop", "Vencord")]
            for root in roots:
                for path in walk(root, 40, lambda p, size: query.lower() in p.name.lower()):
                    if str(path) in seen_path:
                        continue
                    seen_path.add(str(path))
                    add("Target", query, str(path), "File name match", "")
                for path in walk(root, 80, lambda p, size: 0 < size < 8_000_000 and p.suffix.lower() in {".json", ".log", ".txt", ".ldb", ".vdf", ".old"}):
                    if str(path) in seen_path:
                        continue
                    text = read_text(path)
                    if query.lower() not in text.lower():
                        continue
                    seen_path.add(str(path))
                    add("Target", query, str(path), "Text match", "")

    store_dir = CONFIG / "AltChecker"
    store = store_dir / "previous.txt"
    old = []
    if store.is_file():
        old = [line for line in store.read_text("utf-8", "replace").splitlines() if line]
    names = []
    lines = []
    if mode == "target":
        lines += [f"Target: {target}", ""]
    if not rows:
        lines.append("No accounts found.")
    else:
        lines += [f"Accounts Found: {len(rows)}", ""]
        for kind, user, account, source, note in rows:
            past = bool(user) and user in old
            lines.append(kind)
            if user:
                lines.append(f" [Username] {user}")
                if user not in names:
                    names.append(user)
            if account:
                lines.append(f" [Account]  {account}")
            if note:
                lines.append(f" {note}")
            if past and "past" not in note.lower():
                lines.append(" (This username was found in the past on this PC)")
            if source:
                lines.append(f" {source}")
            lines.append("")
    try:
        store_dir.mkdir(parents=True, exist_ok=True)
        store.write_text("\n".join(sorted(set(old + names))), encoding="utf-8")
    except OSError:
        pass
    lines += [
        "USN Journal Information",
        "USN Journal is a Windows NTFS log. It does not exist on Linux.",
        "",
        "Scan Complete",
    ]
    return "\n".join(lines), names


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Alt Checker")
        self.configure(bg="#101010")
        self.geometry("560x680")
        self.minsize(480, 560)
        self.mode = "generic"
        self.scanning = False
        self.bg = "#101010"
        self.field = "#1c1c1c"
        self.muted = "#9a9a9a"
        try:
            self.icon = tk.PhotoImage(file=resource("AltChecker.png"))
            self.iconphoto(True, self.icon)
        except tk.TclError:
            self.icon = None
        self.ui_font = tkfont.Font(family="Sans", size=11)
        self.mono = tkfont.Font(family="Monospace", size=11)
        wrap = tk.Frame(self, bg=self.bg)
        wrap.pack(fill="both", expand=True, padx=20, pady=16)
        self.generic = self.card(wrap, "Generic", "Minecraft, Discord, Steam, and Linux users", "generic")
        self.minecraft = self.card(wrap, "Minecraft", "Vanilla, Lunar, Badlion, Feather, Prism", "minecraft")
        self.target_btn = self.card(wrap, "Target", "Find one username, any capitalization", "target")
        self.target = tk.Entry(wrap, bg=self.field, fg="white", insertbackground="white", relief="flat", font=self.ui_font)
        self.start = tk.Button(wrap, text="Start Scan", command=self.start_scan, bg="white", fg="#101010", activebackground="#dddddd", activeforeground="#101010", relief="flat", font=self.ui_font, pady=8)
        self.start.pack(fill="x", pady=(8, 6))
        self.status = tk.Label(wrap, text="Pick a scan. The username box only opens for Target Scan.", bg=self.bg, fg=self.muted, anchor="w", font=self.ui_font)
        self.status.pack(fill="x")
        box = tk.Frame(wrap, bg=self.field)
        box.pack(fill="both", expand=True, pady=8)
        self.results = tk.Text(box, bg=self.field, fg="white", insertbackground="white", relief="flat", font=self.mono, wrap="word")
        scroll = tk.Scrollbar(box, command=self.results.yview)
        self.results.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.results.pack(side="left", fill="both", expand=True)
        tk.Button(wrap, text="Copy Usernames", command=self.copy_names, bg="#2a2a2a", fg="white", activebackground="#3a3a3a", activeforeground="white", relief="flat", font=self.ui_font, pady=6).pack(fill="x")
        self.paint()

    def card(self, parent, title, subtitle, mode):
        button = tk.Button(parent, text=f"{title}\n{subtitle}", command=lambda: self.pick(mode), relief="flat", anchor="w", justify="left", padx=12, pady=6, font=self.ui_font)
        button.pack(fill="x", pady=4)
        return button

    def pick(self, mode):
        self.mode = mode
        self.paint()
        if mode == "target":
            self.target.focus_set()

    def paint(self):
        for button, mode in ((self.generic, "generic"), (self.minecraft, "minecraft"), (self.target_btn, "target")):
            selected = self.mode == mode
            button.configure(bg="white" if selected else "#1e1e1e", fg="#101010" if selected else "white", activebackground="white" if selected else "#2a2a2a", activeforeground="#101010" if selected else "white")
        if self.mode == "target":
            if not self.target.winfo_ismapped():
                self.target.pack(fill="x", pady=(4, 0), before=self.start, ipady=6)
        elif self.target.winfo_ismapped():
            self.target.pack_forget()

    def start_scan(self):
        if self.scanning:
            return
        query = self.target.get().strip()
        if self.mode == "target" and not query:
            self.status.configure(text="Type a username first.")
            self.target.focus_set()
            return
        self.scanning = True
        self.start.configure(state="disabled")
        self.status.configure(text="Scanning...")
        self.results.delete("1.0", "end")
        mode = self.mode
        def work():
            text, _names = scan(mode, query)
            self.after(0, lambda: self.finish(text))
        threading.Thread(target=work, daemon=True).start()

    def finish(self, text):
        self.results.insert("1.0", text)
        self.status.configure(text="Scan complete")
        self.start.configure(state="normal")
        self.scanning = False

    def copy_names(self):
        names = []
        for line in self.results.get("1.0", "end").splitlines():
            if line.startswith(" [Username] "):
                name = line[len(" [Username] "):]
                if name and name not in names:
                    names.append(name)
        if not names:
            self.status.configure(text="No username to copy.")
            return
        self.clipboard_clear()
        self.clipboard_append("\n".join(names))
        self.status.configure(text=f"Copied {len(names)} username(s).")


if __name__ == "__main__":
    App().mainloop()
