# NTFS for Mac

Đọc và ghi ổ Windows (NTFS) ngay trong Finder trên macOS — miễn phí, mã nguồn mở.
Read and write Windows (NTFS) drives right in Finder on macOS — free and open source.

[Tiếng Việt](#tiếng-việt) · [English](#english)

---

## Tiếng Việt

### Tính năng

- Cắm ổ NTFS vào là ổ hiện trong Finder và **ghi được ngay**: sao chép, đổi tên, xoá, tạo thư mục như ổ bình thường.
- Biểu tượng trên thanh menu liệt kê các ổ NTFS, cho phép **tắt ghi cho từng ổ** (chỉ đọc), gắn lại và đẩy ra.
- Tự chuyển sang chỉ đọc và báo lý do khi ổ không an toàn để ghi: Windows đang ngủ đông (Fast Startup), nhật ký chưa xử lý xong, ổ bị đánh dấu cần kiểm tra, hoặc lỗi đọc/ghi.
- Giao diện tiếng Việt và tiếng Anh theo ngôn ngữ hệ thống (đổi được trong Cài đặt).
- Chạy dưới dạng FSKit extension của Apple — không cần kext, không cần tắt SIP, không cần macFUSE.

### Yêu cầu

- macOS 26 trở lên, Mac Apple silicon hoặc Intel.

### Cài đặt

1. Tải `NTFS-for-Mac-x.y.z.dmg` ở trang Releases, mở ra.
2. **Kéo NTFS for Mac vào thư mục Applications.**
3. Mở ứng dụng. Lần đầu, bấm **Mở Cài đặt hệ thống** rồi bật **NTFS for Mac** trong
   *Cài đặt chung → Mục đăng nhập & tiện ích mở rộng → Tiện ích mở rộng hệ thống tệp*.
4. Cắm ổ NTFS. Nếu ổ đã cắm từ trước, bấm **Gắn** trong menu của ứng dụng.

### Gỡ bỏ

Thoát ứng dụng (menu → Thoát) rồi kéo **NTFS for Mac** từ Applications vào Thùng rác. Không còn gì sót lại ngoài một tệp cài đặt nhỏ trong `~/Library/Preferences`.

### Lưu ý

- Luôn **đẩy ổ ra** trước khi rút để mọi thay đổi được ghi hết.
- Nếu ổ hiện “Chỉ đọc — Windows đang ngủ đông”: khởi động Windows, tắt hẳn bằng cách giữ Shift khi bấm Shut Down (hoặc tắt Fast Startup), rồi cắm lại.
- Phiên bản 1 **chưa hỗ trợ**: định dạng ổ, sửa lỗi ổ (dùng `chkdsk` trên Windows), sửa quyền ACL, ổ mã hoá BitLocker, tệp mã hoá EFS.

### Báo lỗi

Mở issue kèm phiên bản macOS và log lấy bằng:

```sh
log show --last 10m --predicate 'subsystem BEGINSWITH "com.docuong.ntfsformac"'
```

---

## English

### Features

- Plug in an NTFS drive and it shows up in Finder, **writable right away**: copy, rename, delete and create folders as on any other drive.
- A menu bar icon lists NTFS drives and lets you **turn off writing per drive** (read-only), remount and eject.
- Falls back to read-only, and tells you why, when writing would be unsafe: Windows is hibernated (Fast Startup), the journal was not replayed, the volume is marked for checking, or an I/O error occurred.
- Vietnamese and English UI, following the system language (can be changed in Settings).
- Runs as an Apple FSKit extension — no kext, no SIP changes, no macFUSE.

### Requirements

- macOS 26 or later, Apple silicon or Intel.

### Install

1. Download `NTFS-for-Mac-x.y.z.dmg` from Releases and open it.
2. **Drag NTFS for Mac into Applications.**
3. Open the app. The first time, click **Open System Settings** and switch on **NTFS for Mac** under
   *General → Login Items & Extensions → File System Extensions*.
4. Plug in an NTFS drive. If it was already connected, click **Mount** in the app's menu.

### Uninstall

Quit the app (menu → Quit) and drag **NTFS for Mac** from Applications to the Trash. Only a small preferences file in `~/Library/Preferences` remains.

### Notes

- Always **eject** a drive before unplugging it so every change is written.
- If a drive shows “Read-only — Windows is hibernated”: start Windows, shut it down fully by holding Shift while clicking Shut Down (or turn off Fast Startup), then plug it in again.
- Version 1 does **not** support formatting, repairing volumes (use `chkdsk` on Windows), editing ACLs, BitLocker-encrypted drives or EFS-encrypted files.

---

## Building from source

Requirements: Xcode 26 or later; [XcodeGen](https://github.com/yonaskolb/XcodeGen) only after editing `project.yml`.

ntfs-3g is a git submodule, so clone with it:

```sh
git clone --recursive https://github.com/dovancuongadhp/ntfs-for-mac.git
# or, in an existing clone: git submodule update --init
```

Without an Apple Developer account, `scripts/build-local.sh` builds an ad hoc signed app and `build/NTFS-for-Mac.dmg`.
Install it from the DMG and enable the extension; this works on your own Mac. (Xcode itself refuses to sign the
extension without a team, so run the script rather than building in Xcode.)

With an account, for debugging in Xcode and for public releases:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM to your Team ID
xcodegen generate                                        # only needed after editing project.yml
open NTFSForMac.xcodeproj                                # build and run the NTFSForMac scheme
```

Copy the built app to `/Applications` before enabling the extension; macOS only offers extensions from installed apps.
Replacing the app with a differently signed copy unregisters the extension until it is enabled again.

| Command | What it does |
| --- | --- |
| `swift test --package-path Core` | Unit tests for the NTFS core (libntfs-3g bridge), using generated disk images |
| `xcodebuild -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO test` | App unit tests |
| `scripts/build-local.sh` | Ad hoc signed Release build and DMG, no developer account needed |
| `scripts/integration-test.sh` | Mounts a scratch NTFS image through the installed extension and checks data survives a remount |
| `scripts/make-dmg.sh [app] [dmg]` | Packages an app into a drag-to-install DMG (defaults to the unsigned Release build) |
| `scripts/release.sh` | Archive, Developer ID signing, notarization, stapling and the final DMG |
| `swift scripts/make-icon.swift` | Regenerates the app icon |

### Layout

- `Core/` — Swift package: vendored [ntfs-3g](https://github.com/tuxera/ntfs-3g) (`CNTFS`), a typed Swift API over it (`NTFSCore`), boot-sector probing (`NTFSProbe`) and identifiers shared by the app and extension (`NTFSShared`).
- `Extension/` — the FSKit file system extension (`ntfsrw`).
- `App/` — the menu bar app: disk monitoring (DiskArbitration), mounting, per-drive settings, welcome and settings windows.

## License

GPL-2.0-or-later, the same as ntfs-3g. See [LICENSE](LICENSE).
