"""Small desktop front end for the USB fleet controller (Python/Tk, Windows/macOS)."""
from __future__ import annotations

import json
from pathlib import Path
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from fleet import FleetController, FleetError, PinStore, authenticate, discover, read_script


class FleetApp:
    def __init__(self, root, auto_scan=True):
        self.root = root
        self.root.title("HPhone Touch — Điều phối USB")
        self.root.geometry("1100x660")
        self.root.minsize(850, 540)
        self.controller = FleetController(workers=4)
        self.pins = PinStore(Path.home() / ".hphone-touch" / "ssh-host-keys")
        self.events = queue.Queue()
        self.busy = False
        self.closed = False
        self.credentials_dialog = None
        self.pending_credentials = None
        self.path = tk.StringVar()
        self.remote_name = tk.StringVar(value="hello.lua")
        self.status = tk.StringVar(value="Cắm iPhone, mở khóa và Tin cậy PC, sau đó quét USB.")
        self._build()
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(100, self.drain)
        if auto_scan:
            self.scan()

    def _build(self):
        box = ttk.Frame(self.root, padding=16)
        box.pack(fill="both", expand=True)
        ttk.Label(box, text="HPhone Touch", font=("Segoe UI", 20, "bold")).pack(anchor="w")
        ttk.Label(box, text="Điều khiển các máy đã cài HPhone Touch qua USB · tối đa 4 thao tác đồng thời").pack(anchor="w", pady=(4, 12))
        toolbar = ttk.Frame(box)
        toolbar.pack(fill="x", pady=(0, 10))
        self.buttons = []
        for label, command in (("Quét USB", self.scan), ("Chọn tất cả", self.select_all),
                               ("Kết nối máy đã chọn", self.connect), ("Ngắt kết nối", self.disconnect),
                               ("Cập nhật trạng thái", lambda: self.dispatch("status")), ("Xuất báo cáo", self.export)):
            button = ttk.Button(toolbar, text=label, command=command)
            button.pack(side="left", padx=(0, 6))
            self.buttons.append(button)
        tablebox = ttk.Frame(box)
        tablebox.pack(fill="both", expand=True)
        columns = ("name", "model", "ios", "udid", "state", "jobs", "version")
        self.table = ttk.Treeview(tablebox, columns=columns, show="headings", selectmode="extended", height=12)
        for key, label, width in (("name", "Thiết bị", 130), ("model", "Model", 95), ("ios", "iOS", 70),
                                  ("udid", "UDID", 250), ("state", "Trạng thái", 160), ("jobs", "Script", 65), ("version", "Bản", 70)):
            self.table.heading(key, text=label)
            self.table.column(key, width=width, minwidth=50, stretch=key in ("name", "udid", "state"))
        self.table.pack(side="left", fill="both", expand=True)
        scroll = ttk.Scrollbar(tablebox, orient="vertical", command=self.table.yview)
        scroll.pack(side="right", fill="y")
        self.table.configure(yscrollcommand=scroll.set)
        self.table.bind("<<TreeviewSelect>>", self.show_record)
        self.table.bind("<Double-1>", lambda _: self.connect())
        self.detail = tk.Text(box, height=4, wrap="word", font=("Consolas", 10), state="disabled")
        self.detail.pack(fill="x", pady=10)
        local = ttk.LabelFrame(box, text="Script trên PC", padding=10)
        local.pack(fill="x", pady=(0, 10))
        ttk.Entry(local, textvariable=self.path).pack(side="left", fill="x", expand=True)
        self.pick_button = ttk.Button(local, text="Chọn .lua…", command=self.pick)
        self.pick_button.pack(side="left", padx=8)
        self.upload_button = ttk.Button(local, text="Tải lên các máy đã chọn", command=lambda: self.dispatch("upload"))
        self.upload_button.pack(side="left")
        self.upload_run_button = ttk.Button(local, text="Tải lên & chạy", command=lambda: self.dispatch("upload_run"))
        self.upload_run_button.pack(side="left", padx=(8, 0))
        actions = ttk.Frame(box)
        actions.pack(fill="x")
        ttk.Label(actions, text="Script đã có trên iPhone:").pack(side="left")
        ttk.Entry(actions, textvariable=self.remote_name, width=30).pack(side="left", padx=8)
        self.run_button = ttk.Button(actions, text="▶ Chạy trên các máy đã chọn", command=lambda: self.dispatch("run"))
        self.run_button.pack(side="left")
        self.stop_button = ttk.Button(actions, text="■ Dừng script trên các máy đã chọn", command=lambda: self.dispatch("stop"))
        self.stop_button.pack(side="left", padx=8)
        self.buttons.extend((self.pick_button, self.upload_button, self.upload_run_button, self.run_button, self.stop_button))
        ttk.Label(box, textvariable=self.status, wraplength=1000).pack(anchor="w", pady=(12, 0))

    def selected(self):
        result = list(self.table.selection())
        if not result:
            messagebox.showinfo("HPhone Touch", "Chọn ít nhất một iPhone trong bảng.")
        return result

    def select_all(self):
        self.table.selection_set(self.table.get_children())

    def _start(self, message, worker):
        if self.busy or self.closed:
            return False
        self.busy = True
        self.status.set(message)
        for button in self.buttons:
            button.configure(state="disabled")

        def run():
            try:
                worker()
            except FleetError as error:
                self.events.put(("error", error.safe_message))
            except Exception:
                self.events.put(("error", "Thao tác không hoàn tất. Kiểm tra phụ thuộc Python, cáp USB và trạng thái iPhone."))
            finally:
                self.events.put(("done", None))

        threading.Thread(target=run, name="hphone-desktop", daemon=True).start()
        return True

    def scan(self):
        def worker():
            devices = discover()
            self.controller.update_devices(devices)
            self.events.put(("records", self.controller.export()))
            self.events.put(("status", f"Tìm thấy {len(devices)} iPhone qua USB. Mỗi máy cần kết nối riêng một lần trong phiên này."))
        self._start("Đang quét các kết nối USB…", worker)

    def refresh(self, records=None):
        selection = set(self.table.selection())
        for row in records if records is not None else self.controller.export():
            values = tuple(row.get(key, "") for key in ("name", "model", "ios", "udid", "state", "jobs", "version"))
            if self.table.exists(row["udid"]):
                self.table.item(row["udid"], values=values)
            else:
                self.table.insert("", "end", iid=row["udid"], values=values)
        self.table.selection_set([item for item in selection if self.table.exists(item)])

    def show_record(self, _=None):
        chosen = self.table.selection()
        rows = [row for row in self.controller.export() if row["udid"] in chosen]
        self.detail.configure(state="normal")
        self.detail.delete("1.0", "end")
        for row in rows:
            self.detail.insert("end", f"{row.get('name', 'iPhone')} · {row['udid']} · {row.get('state', '')}\n")
            if row.get("error"):
                self.detail.insert("end", row["error"] + "\n")
        self.detail.configure(state="disabled")

    def connect(self):
        selected = self.selected()
        if not selected or self.busy or self.credentials_dialog is not None:
            return
        self._next_credentials(selected)

    def _next_credentials(self, remaining):
        if not remaining or self.closed:
            return
        udid, *rest = remaining
        row = next((r for r in self.controller.export() if r["udid"] == udid), {})
        dialog = tk.Toplevel(self.root)
        self.credentials_dialog = dialog
        dialog.title("SSH riêng cho iPhone này")
        dialog.transient(self.root)
        dialog.resizable(False, False)
        box = ttk.Frame(dialog, padding=20)
        box.pack(fill="both", expand=True)
        ttk.Label(box, text=row.get("name", "iPhone"), font=("Segoe UI", 13, "bold")).pack(anchor="w")
        ttk.Label(box, text=udid).pack(anchor="w", pady=(4, 12))
        ttk.Label(box, text="Tài khoản SSH").pack(anchor="w")
        username = tk.StringVar(value="mobile")
        ttk.Combobox(box, textvariable=username, values=("mobile", "root"), state="readonly", width=35).pack(fill="x", pady=(4, 10))
        ttk.Label(box, text="Mật khẩu SSH của chính máy này").pack(anchor="w")
        secret = tk.StringVar()
        password = ttk.Entry(box, textvariable=secret, show="•", width=38)
        password.pack(fill="x", pady=(4, 10))
        ttk.Label(box, text="Mật khẩu chỉ dùng để đọc token/cổng qua USB.\nKhông lưu mật khẩu hoặc token vào báo cáo.").pack(anchor="w", pady=(0, 10))
        buttons = ttk.Frame(box)
        buttons.pack(fill="x")

        def dismiss(next_device=False):
            secret.set("")
            self.credentials_dialog = None
            dialog.destroy()
            if next_device:
                self._next_credentials(rest)

        def submit():
            credential = secret.get()
            user = username.get()
            if not credential:
                return
            dismiss()

            def worker():
                try:
                    session = authenticate(udid, user, credential, self.pins)
                    self.controller.attach(session)
                    self.events.put(("records", self.controller.export()))
                    self.events.put(("status", "Đã kết nối USB: " + row.get("name", udid)))
                except FleetError as error:
                    self.events.put(("error", error.safe_message))
                finally:
                    self.events.put(("next_credentials", rest))

            self._start("Đang xác thực SSH và kiểm tra HPhone Touch…", worker)

        ttk.Button(buttons, text="Kết nối", command=submit).pack(side="left")
        ttk.Button(buttons, text="Bỏ qua máy này", command=lambda: dismiss(True)).pack(side="left", padx=8)
        ttk.Button(buttons, text="Hủy", command=dismiss).pack(side="left")
        dialog.protocol("WM_DELETE_WINDOW", dismiss)
        dialog.bind("<Return>", lambda _: submit())
        dialog.grab_set()
        password.focus_set()

    def disconnect(self):
        if self.busy:
            return
        for udid in self.selected():
            self.controller.detach(udid)
        self.refresh()
        self.status.set("Đã xóa token phiên của các máy đã chọn khỏi bộ nhớ công cụ.")

    def pick(self):
        path = filedialog.askopenfilename(title="Chọn Lua", filetypes=[("Lua script", "*.lua")])
        if path:
            self.path.set(path)
            self.remote_name.set(Path(path).name)

    def dispatch(self, action):
        selected = self.selected()
        if not selected or self.busy:
            return
        name, content = self.remote_name.get().strip(), None
        if action in ("upload", "upload_run"):
            try:
                name, content = read_script(self.path.get())
            except FleetError as error:
                messagebox.showerror("HPhone Touch", error.safe_message)
                return
            except OSError:
                messagebox.showerror("HPhone Touch", "Không đọc được script trên PC. Chọn tệp .lua trước.")
                return

        def progress(result):
            self.events.put(("records", self.controller.export()))
            self.events.put(("progress", result))

        def worker():
            results = self.controller.batch(selected, action, name=name, content=content, progress=progress)
            passed = sum(result["ok"] for result in results)
            self.events.put(("status", f"Hoàn tất {passed}/{len(results)} máy. Các máy lỗi được ghi riêng trong bảng; không tự chạy lại thao tác."))
        self._start(f"Đang xử lý {len(selected)} iPhone qua USB…", worker)

    def export(self):
        path = filedialog.asksaveasfilename(title="Báo cáo trạng thái", initialfile="hphone-fleet.json", defaultextension=".json", filetypes=[("JSON", "*.json")])
        if path:
            try:
                Path(path).write_text(json.dumps(self.controller.export(), ensure_ascii=False, indent=2), encoding="utf-8")
                self.status.set("Đã xuất báo cáo trạng thái; không chứa mật khẩu, token hay log script.")
            except OSError:
                messagebox.showerror("HPhone Touch", "Không ghi được tệp báo cáo.")

    def drain(self):
        if self.closed:
            return
        while True:
            try:
                event, value = self.events.get_nowait()
            except queue.Empty:
                break
            if event == "records":
                self.refresh(value)
            elif event == "status":
                self.status.set(value)
            elif event == "error":
                self.status.set(value)
                messagebox.showerror("HPhone Touch", value)
            elif event == "progress":
                self.show_record()
            elif event == "next_credentials":
                self.pending_credentials = value
            elif event == "done":
                self.busy = False
                for button in self.buttons:
                    button.configure(state="normal")
        if self.pending_credentials and not self.busy:
            selected = self.pending_credentials
            self.pending_credentials = None
            self._next_credentials(selected)
        self.root.after(100, self.drain)

    def close(self):
        self.closed = True
        self.controller.close()
        self.root.destroy()


def main():
    root = tk.Tk()
    if len(sys.argv) == 3 and sys.argv[1] == "--self-test":
        root.withdraw()
        app = FleetApp(root, auto_scan=False)
        app.controller.update_devices([{"udid":"0"*40,"name":"iPhone test","model":"iPhone8,1","ios":"15.8.4","paired":True}])
        app.refresh()
        app.select_all()
        app.show_record()
        root.update_idletasks()
        result = {"widgets_created":True,"device_rows":len(app.table.get_children()),"selected_rows":len(app.table.selection()),"network_requests":0}
        try:
            import paramiko
            from pymobiledevice3.lockdown import create_using_usbmux
            from pymobiledevice3.usbmux import list_devices
            result["dependencies_loaded"] = callable(create_using_usbmux) and callable(list_devices) and callable(paramiko.Transport)
        except Exception as error:
            result["dependencies_loaded"] = False
            result["dependency_error"] = type(error).__name__ + ": " + str(error)
        Path(sys.argv[2]).write_text(json.dumps(result,indent=2),encoding="utf-8")
        app.close()
        return
    FleetApp(root)
    root.mainloop()


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()
    main()
