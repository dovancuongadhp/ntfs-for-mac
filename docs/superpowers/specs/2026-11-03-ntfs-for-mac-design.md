# NTFS for Mac — Thiết kế

Ngày: 2026-11-03
Trạng thái: Đã duyệt thiết kế, chờ review tài liệu

## 1. Mục tiêu

Ứng dụng macOS mã nguồn mở, miễn phí, cho phép **đọc và ghi** ổ đĩa định dạng NTFS (Windows) ngay trong Finder.

Yêu cầu bắt buộc:

- Ổ NTFS hiện trong Finder và thao tác như ổ bình thường (copy, kéo thả, đổi tên, xóa, tạo thư mục).
- Cắm ổ NTFS vào là **tự động mount đọc-ghi**, không cần thao tác; có thể tắt chế độ ghi cho từng ổ.
- **Cài đặt:** kéo `NTFS for Mac.app` từ DMG vào thư mục Applications.
- **Gỡ bỏ:** xóa ứng dụng hoặc kéo vào Thùng rác. Không có trình cài đặt, kernel extension hay phần mềm phụ thuộc nào phải cài riêng.
- Có biểu tượng ứng dụng riêng.
- Giao diện tiếng Việt và tiếng Anh, tự theo ngôn ngữ hệ thống.
- Phát hành công khai, ký bằng Developer ID và notarize với Apple.

Không làm trong phiên bản đầu (v1):

- Format ổ sang NTFS.
- Sửa lỗi ổ đĩa (thay cho `chkdsk`).
- Chỉnh sửa phân quyền NTFS (ACL) chi tiết.
- Cửa sổ quản lý file riêng (Finder đảm nhận việc này).
- Ổ mã hóa BitLocker và file mã hóa EFS.

## 2. Hướng kỹ thuật

Dùng **phần mở rộng FSKit** (khung hệ thống file chạy ở chế độ người dùng của Apple) nhúng trong ứng dụng, với lõi đọc-ghi NTFS là thư viện **`libntfs-3g`**.

Lý do chọn:

- Phần mở rộng FSKit nằm trong `.app`, nên kéo vào là cài và xóa là gỡ.
- Không cần kernel extension, macFUSE hay khởi động lại máy.
- `ntfs-3g` đã được kiểm chứng nhiều năm trên Linux, an toàn hơn nhiều so với tự viết lõi NTFS.

Các phương án đã loại:

- **macFUSE + ntfs-3g:** bắt buộc cài macFUSE riêng, vi phạm yêu cầu cài/gỡ bằng kéo thả.
- **Giả lập ổ mạng nội bộ (SMB/NFS trên localhost):** Finder hiển thị như ổ mạng, chậm, dễ lỗi khi rút ổ hoặc khi máy ngủ, và cần tiến trình nền chạy quyền admin.

Giấy phép: phần lớn mã nguồn `ntfs-3g` dùng GPL-2.0-or-later, nên toàn bộ dự án phát hành theo **GPL-2.0-or-later**.

Hệ điều hành tối thiểu: **macOS 26**. FSKit trên các bản trước còn thiếu API đọc-ghi hiệu năng cao và chưa ổn định.

### Rủi ro cần kiểm chứng sớm (thử nghiệm ở Giai đoạn 0)

1. **Phần mở rộng FSKit bên thứ ba có tự động được chọn khi cắm ổ hay không**, thay cho trình đọc NTFS chỉ đọc có sẵn của macOS. Nếu không, phương án dự phòng là ứng dụng trên thanh menu eject bản mount chỉ đọc của hệ thống rồi mount lại bằng phần mở rộng của mình (người dùng vẫn không cần thao tác).
2. **Ứng dụng có được phép yêu cầu mount bằng phần mở rộng FSKit mà không cần quyền admin hay không** (qua DiskArbitration hoặc `mount -F`).
3. **Có ký được phần mở rộng FSKit bằng tài khoản phát triển miễn phí để thử trên máy cá nhân hay không**, hay bắt buộc phải có tài khoản Apple Developer trả phí.

## 3. Kiến trúc

Người dùng chỉ thấy một gói `NTFS for Mac.app`, bên trong gồm ba khối:

```
NTFS for Mac.app
├── Contents/MacOS/NTFS for Mac          ← Ứng dụng chính (SwiftUI)
├── Contents/Extensions/NTFSExtension.appex  ← Phần mở rộng FSKit
│     └── liên kết tĩnh NTFSCore (libntfs-3g + lớp nối C)
└── Contents/Resources                   ← Icon, bản dịch vi/en
```

### 3.1 Ứng dụng chính (`NTFSForMac`, SwiftUI)

- **Biểu tượng trên thanh menu** (`MenuBarExtra`): liệt kê các ổ NTFS đang cắm.
  - Mỗi ổ hiển thị tên, dung lượng đã dùng/tổng, và trạng thái: "Đọc và ghi", "Chỉ đọc — <lý do>", hoặc "Không hỗ trợ — <lý do>".
  - Mỗi ổ có nút Eject và công tắc "Tự mount đọc-ghi" riêng.
- **Cửa sổ chào mừng và cài đặt:**
  - Hiện ở lần chạy đầu, hoặc khi phát hiện phần mở rộng chưa được bật.
  - Hướng dẫn bằng hình cách bật phần mở rộng tại System Settings → General → Login Items & Extensions → File System Extensions, kèm nút mở thẳng đến trang này.
  - Phần cài đặt gồm: khởi động cùng máy, ngôn ngữ, thông tin phiên bản và giấy phép.
- **Theo dõi ổ đĩa (`DiskMonitor`):** dùng DiskArbitration để nhận sự kiện cắm/rút ổ, nhận diện NTFS và điều phối việc mount.
- **Khởi động cùng máy:** đăng ký bằng `SMAppService.mainApp`. Đăng ký này mất theo khi xóa ứng dụng.
- **Thiết lập theo từng ổ:** lưu trong `UserDefaults` của ứng dụng, khóa theo UUID của volume NTFS.

### 3.2 Phần mở rộng FSKit (`NTFSExtension`)

- Cài đặt `FSUnaryFileSystem` (có probe: nhận diện chữ ký NTFS ở boot sector) và một lớp con của `FSVolume`.
- Cài đặt các thao tác FSKit: lookup, liệt kê thư mục, đọc/ghi thuộc tính, tạo/xóa file và thư mục, đổi tên, đọc/ghi dữ liệu, symlink (chỉ đọc), thống kê volume, sync và unmount.
- Đọc-ghi dữ liệu dùng API đọc-ghi hiệu năng cao của FSKit trên macOS 26 khi phù hợp; nếu không thì đi qua lớp nối của `NTFSCore`.
- Mọi lời gọi xuống `NTFSCore` được thực hiện tuần tự trên một hàng đợi riêng cho mỗi volume, vì `libntfs-3g` không an toàn khi gọi từ nhiều luồng cùng lúc.

### 3.3 Lõi NTFS (`NTFSCore`)

- `libntfs-3g` được nhúng vào mã nguồn với một phiên bản phát hành cố định (git submodule hoặc thư mục vendor) và biên dịch thành thư viện tĩnh.
- **Lớp nối C (`ntfs_bridge`)** gồm:
  - Một bộ `ntfs_device_operations` tùy biến: chuyển các lệnh đọc/ghi/seek/sync của `ntfs-3g` thành lời gọi đến tài nguyên thiết bị (`FSBlockDeviceResource`) do FSKit cấp, thông qua con trỏ hàm do Swift đăng ký. Lõi vì thế không phụ thuộc FSKit.
  - Một bộ thứ hai đọc-ghi file ảnh đĩa thường, dùng cho kiểm thử.
  - API gọn cho Swift: mount/unmount, kiểm tra trạng thái volume, các thao tác trên inode, thư mục và dữ liệu. Lỗi được trả về dưới dạng `errno`.
- Đưa sang Swift bằng module map. Phía Swift có một lớp bọc mỏng (`NTFSVolumeHandle`) dùng kiểu Swift và `throws`.

## 4. Luồng hoạt động

### 4.1 Khi cắm ổ

1. DiskArbitration báo `DiskMonitor` có ổ mới.
2. `DiskMonitor` đọc boot sector để xác định đó là NTFS.
3. Nếu ổ bị tắt "Tự mount đọc-ghi": để macOS mount chỉ đọc như mặc định, rồi kết thúc.
4. Nếu macOS đã mount bằng trình đọc chỉ đọc của hệ thống: unmount bản đó.
5. Yêu cầu mount bằng phần mở rộng FSKit (cơ chế cụ thể được chốt sau Giai đoạn 0).
6. Phần mở rộng mở volume qua `NTFSCore` và kiểm tra trạng thái (mục 4.2), rồi mount đọc-ghi hoặc chỉ đọc.
7. Ứng dụng cập nhật trạng thái trên thanh menu. Nếu ổ bị mount chỉ đọc, gửi thông báo giải thích lý do.

### 4.2 Các trường hợp tự động chuyển sang chỉ đọc

| Tình huống | Hành vi | Thông báo cho người dùng |
|---|---|---|
| Windows đang ngủ đông hoặc bật Fast Startup | Chỉ đọc | Tắt hẳn Windows, hoặc tắt Fast Startup |
| Volume bị đánh dấu dirty / journal chưa sạch | Chỉ đọc | Chạy `chkdsk` trên Windows |
| BitLocker | Không mount | Ổ đã mã hóa BitLocker, không được hỗ trợ |
| Lõi NTFS gặp lỗi I/O hoặc cấu trúc khi đang ghi | Chuyển ngay sang chỉ đọc | Đã chuyển sang chỉ đọc để bảo vệ dữ liệu |
| Người dùng đã tắt ghi cho ổ này | Chỉ đọc | (không thông báo) |

### 4.3 Khi eject

- Ghi hết dữ liệu còn trong bộ nhớ (`ntfs_umount` → sync thiết bị) trước khi báo hệ thống là đã unmount xong.
- Nếu ổ bị rút đột ngột: lần cắm sau ổ sẽ bị coi là dirty, nên được mount chỉ đọc theo bảng ở mục 4.2.

### 4.4 Tên file và tính năng NTFS

- Tên file Unicode, kể cả tiếng Việt có dấu. Chuẩn hóa NFC/NFD để tương thích với Finder.
- Hỗ trợ file lớn hơn 4 GB và sparse file.
- File ẩn và file hệ thống của Windows: mặc định ẩn trong Finder.
- Symlink và junction: chỉ đọc.
- File nén NTFS: đọc được.
- File mã hóa EFS: báo lỗi không đọc được.
- Quyền POSIX hiển thị: chủ sở hữu là người dùng hiện tại, file `0644` và thư mục `0755` (không ánh xạ ACL ở v1).

## 5. Giao diện, icon, đóng gói

- **Icon:** ổ đĩa cách điệu kèm biểu tượng cửa sổ Windows và mũi tên hai chiều. Có đủ kích thước trong `AppIcon` của Asset Catalog, cùng một biểu tượng template đơn sắc cho thanh menu.
- **Bản dịch:** dùng String Catalog (`Localizable.xcstrings`) với hai ngôn ngữ `vi` và `en`, trong đó `en` là ngôn ngữ phát triển.
- **DMG:** nền có mũi tên hướng dẫn kéo icon ứng dụng vào alias thư mục Applications.
- **Script build (`scripts/release.sh`):** build Release → ký Developer ID (Hardened Runtime) → notarize (`notarytool`) → staple → tạo DMG. Có thể chuyển lên GitHub Actions khi có chứng chỉ.
- **Gỡ bỏ:** kéo ứng dụng vào Thùng rác. Chỉ còn lại file thiết lập nhỏ trong `~/Library/Preferences`, giống mọi ứng dụng macOS khác.

## 6. Cấu trúc mã nguồn

```
ntfs-for-mac/
├── NTFSForMac.xcodeproj
├── App/                    # Ứng dụng SwiftUI (thanh menu, chào mừng, DiskMonitor)
├── Extension/              # Phần mở rộng FSKit
├── Core/
│   ├── vendor/ntfs-3g/     # Mã nguồn ntfs-3g, phiên bản cố định
│   ├── bridge/             # ntfs_bridge.c/.h + module.modulemap
│   └── Swift/              # NTFSVolumeHandle
├── Tests/
│   ├── CoreTests/          # Kiểm thử lõi trên file ảnh đĩa
│   └── Integration/        # Script tích hợp với hdiutil
├── Resources/              # Icon, String Catalog, nền DMG
├── scripts/                # build, release, tạo ảnh đĩa kiểm thử
├── docs/
└── LICENSE                 # GPL-2.0-or-later
```

## 7. Kiểm thử

1. **Lõi NTFS (tự động, XCTest/Swift Testing):** chạy trên file ảnh đĩa do `mkntfs` (build từ cùng mã nguồn ntfs-3g) tạo ra.
   - Các thao tác: tạo, ghi, đọc, ghi đè, cắt ngắn, đổi tên, di chuyển, xóa, tạo/xóa thư mục.
   - Tên tiếng Việt có dấu (NFC và NFD), file lớn hơn 4 GB (sparse), 10.000 file nhỏ.
   - Volume bị đánh dấu dirty hoặc có cờ ngủ đông thì phải mở chỉ đọc.
2. **Tích hợp (script):** `hdiutil attach -nomount` ảnh đĩa → mount qua phần mở rộng thật → copy một cây thư mục lớn → so SHA-256 → unmount → mount lại → so lại → kiểm tra bằng `ntfsfix -n`.
3. **Thủ công trước mỗi bản phát hành:** USB thật (MBR và GPT), ghi trên Mac rồi cắm sang Windows chạy `chkdsk /scan` để xác nhận không có lỗi.

## 8. Thứ tự triển khai

0. **Thử nghiệm FSKit:** một phần mở rộng tối thiểu mount được ảnh đĩa NTFS ở chế độ chỉ đọc. Trả lời ba rủi ro ở mục 2 và chốt cơ chế tự động mount.
1. **NTFSCore:** build `libntfs-3g` cho arm64 và x86_64, viết lớp nối, cùng bộ kiểm thử lõi.
2. **NTFSExtension:** đầy đủ thao tác đọc-ghi, xử lý các trường hợp chỉ đọc, eject an toàn, kèm kiểm thử tích hợp.
3. **Ứng dụng:** thanh menu, `DiskMonitor`, tự động mount, cửa sổ chào mừng, thiết lập theo từng ổ.
4. **Hoàn thiện:** icon, bản dịch vi/en, DMG, script ký và notarize, README, LICENSE.
