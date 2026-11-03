# NTFS for Mac 1.0.2 — Giao diện quản lý ổ và Format

Ngày: 2026-11-03
Trạng thái: Đã duyệt thiết kế, chờ review tài liệu
Nhánh: `release-1.0.2`

## 1. Mục tiêu

Bản 1.0.2 biến NTFS for Mac từ một tiện ích menu bar thành ứng dụng quản lý ổ đầy đủ, tương tự Paragon NTFS / Tuxera nhưng giao diện hiện đại theo macOS 26:

- Cửa sổ chính kiểu Disk Utility: sidebar ổ vật lý → phân vùng, khung chi tiết, thanh công cụ.
- Hiện **mọi** ổ (NTFS, exFAT, FAT32, APFS…), không chỉ NTFS.
- Gắn, tháo, eject, mở trong Finder.
- Format một phân vùng sang NTFS, exFAT, FAT32 hoặc APFS.
- Format cả ổ vật lý (tạo lại bảng phân vùng GPT hoặc MBR).

Nguyên tắc bắt buộc:

- **Tuyệt đối không gây mất dữ liệu ngoài ý muốn.** Mọi thao tác xóa phải qua nhiều lớp kiểm tra (mục 5).
- Không phụ thuộc Apple: không kernel extension, không entitlement trả phí. Chỉ dùng công cụ có sẵn trong macOS (`diskutil`, DiskArbitration) và mã ntfs-3g đã đóng gói.
- Bản 1.0.2 **không** thay đổi extension FSKit và lõi đọc-ghi NTFS.

Ngoài phạm vi 1.0.2:

- Kiểm tra / sửa lỗi NTFS.
- Tùy chọn riêng mới cho từng ổ (không tự gắn, Spotlight…). Công tắc "Cho phép ghi" hiện có được giữ nguyên.
- Tạo ảnh đĩa (DMG); ảnh đĩa và ổ ảo bị ẩn khỏi danh sách.
- Tăng tốc đọc-ghi (write-behind, read-ahead) — để bản 1.0.3.

## 2. Giao diện

### 2.1 Cửa sổ chính

Bố cục kiểu Disk Utility (phương án A đã chọn):

- **Sidebar**, nhóm theo vị trí:
  - "Ổ ngoài": mỗi ổ vật lý (tên model, nút ⏏) với các phân vùng thụt vào bên dưới, kèm nhãn định dạng.
  - "Trong máy": ổ trong máy, có biểu tượng khóa; chỉ để xem.
  - Phân vùng APFS hiện trực tiếp các ổ con bên trong dưới ổ vật lý chứa nó (ẩn khái niệm container).
- **Thanh công cụ:** Gắn/Tháo, Eject, Mở Finder, Format…. Nút không áp dụng được thì mờ đi.
- **Khung chi tiết khi chọn phân vùng:**
  - Biểu tượng, tên, nhãn định dạng, nhãn trạng thái (Đọc & ghi, Chỉ đọc, Chưa gắn…).
  - Thanh dung lượng (đã dùng / trống / tổng).
  - Bảng thông tin: nơi gắn, driver, kích thước cluster (nếu biết), mã phân vùng.
  - Với ổ NTFS: công tắc "Cho phép ghi" và banner khi ổ bị gắn chỉ đọc (kèm "Vẫn cho ghi"), giữ hành vi hiện tại.
- **Khung chi tiết khi chọn ổ vật lý:**
  - Biểu tượng, tên model, kết nối, loại bảng phân vùng, mã ổ.
  - Bản đồ phân vùng: thanh màu chia theo tỉ lệ từng phân vùng, kèm chú thích.
  - Bảng thông tin: dung lượng, kết nối, bảng phân vùng, số phân vùng.
  - Format… lúc này là format cả ổ.

### 2.2 Hộp thoại format

Hiện dạng sheet trên cửa sổ chính:

- Tiêu đề "Format “<tên>”?".
- **Cảnh báo đỏ** ghi rõ: dung lượng dữ liệu sẽ mất (hoặc "Không xác định được dữ liệu — hãy coi như có dữ liệu quan trọng" nếu chưa gắn), mã phân vùng/ổ, dung lượng, ổ chứa nó, và những phân vùng **không** bị ảnh hưởng.
- Trường: Tên, Định dạng; khi format cả ổ thêm Bảng phân vùng (GPT mặc định / MBR).
- Mục "Nâng cao" thu gọn: kích thước cluster (mặc định Tự động); riêng NTFS có Format nhanh / Format đầy đủ (ghi số 0 toàn bộ).
- Ô xác nhận: phải gõ đúng tên phân vùng (hoặc tên ổ khi format cả ổ) thì nút đỏ "Xóa và format" mới bật.
- Khi đang chạy: hiện từng bước (Đang tháo…, Đang format…, Đang gắn…); không hủy được sau khi bắt đầu ghi.

Kiểm tra tên theo định dạng:

| Định dạng | Giới hạn tên |
|---|---|
| FAT32 | ≤ 11 ký tự ASCII, tự viết hoa, không chứa `" * / : < > ? \ \|` |
| exFAT | ≤ 15 ký tự |
| NTFS | ≤ 128 ký tự |
| APFS | ≤ 255 byte UTF-8 |

APFS chỉ có khi ổ dùng GPT (hoặc khi format cả ổ, lúc đó bắt buộc GPT).

### 2.3 Menu bar

Giữ menu bar nhưng gọn lại:

- Danh sách ổ NTFS kèm trạng thái; mỗi ổ có Eject và Mở Finder.
- Banner chỉ đọc kèm "Vẫn cho ghi" như hiện tại.
- "Mở NTFS for Mac…", Cài đặt, Thoát.
- **Không có Format** trên menu bar: thao tác nguy hiểm chỉ làm trong cửa sổ chính.

### 2.4 Cách app xuất hiện

- App vẫn là `LSUIElement` (chỉ menu bar). Khi cửa sổ chính mở, chuyển sang `.regular` (có icon Dock, menu đầy đủ); đóng cửa sổ thì về `.accessory`.
- Mở app từ Finder/Launchpad → tự mở cửa sổ chính. Chạy khi đăng nhập → chỉ hiện menu bar.
- Giao diện tiếng Việt và tiếng Anh như hiện tại.

## 3. Kiến trúc

Mọi phần mới nằm trong target App. Extension và Core không đổi (trừ công cụ `ntfs-format` ở mục 4.3).

| Thành phần | Vai trò |
|---|---|
| `DiskInventory` | Thay `DiskMonitor`. Theo dõi DiskArbitration, dựng cây `PhysicalDisk` → `Partition`, cập nhật khi cắm/rút/gắn/tháo. |
| `MountController` | Giữ nguyên. NTFS gắn bằng extension; định dạng khác gắn qua DiskArbitration bình thường. |
| `FormatSafety` | Logic thuần, không phụ thuộc UI: quyết định ổ/phân vùng nào được format/tháo, sinh cảnh báo, so khớp dấu vân tay. |
| `FormatPlanner` | Từ yêu cầu đã xác thực, dựng danh sách bước và lệnh cụ thể (`diskutil`, `ntfs-format`). Thuần, test được. |
| `FormatRunner` | Thực thi kế hoạch: tháo, chạy lệnh, báo tiến trình, đọc lại trạng thái. |
| Views | `MainWindow` (sidebar, chi tiết, toolbar), `FormatSheet`, menu bar gọn. |

### 3.1 Mô hình dữ liệu

`PhysicalDisk`:

- `bsdName` (vd. `disk5`), tên model, dung lượng.
- Bảng phân vùng: GPT / MBR / không có.
- `isInternal`, giao tiếp (USB, Thunderbolt…), `isEjectable`, `isWritable`.
- Danh sách `Partition`.

`Partition`:

- `bsdName` (vd. `disk5s3`), tên, định dạng (volume kind + content hint), dung lượng, vị trí bắt đầu trên ổ.
- Mount (đường dẫn, loại file system, chỉ đọc, tổng/trống) như `NTFSDisk.Mount` hiện tại.
- UUID phân vùng / volume, `preferenceKey` (giữ cách tính hiện tại để không mất cài đặt "Cho phép ghi").
- Vai trò APFS (System, Data, Backup…) nếu có.

Lọc:

- Ẩn ổ ảo (`DeviceProtocol` = Virtual Interface) và ảnh đĩa, trừ khi bật cờ chỉ có trong build test (mục 7).
- Ẩn phân vùng EFI và phân vùng phụ của hệ thống trong sidebar (vẫn hiện trên bản đồ phân vùng).

Logic NTFS hiện có (`MountPolicy`, tự gắn, lý do chỉ đọc, `VolumePreferences`) chuyển sang đọc từ các `Partition` có định dạng NTFS; hành vi không đổi.

## 4. Luồng format

### 4.1 Format một phân vùng

1. Người dùng chọn phân vùng → Format… (chỉ bật khi `FormatSafety` cho phép).
2. Khi mở sheet, lưu **dấu vân tay**: `bsdName`, UUID, dung lượng, `bsdName` ổ chứa, vị trí bắt đầu.
3. Người dùng chọn tên, định dạng, tùy chọn nâng cao, gõ tên để xác nhận.
4. Thực hiện:
   1. Đọc lại mô tả DiskArbitration; so với dấu vân tay. Lệch → hủy, không ghi gì.
   2. Tháo phân vùng (DiskArbitration, **không force**). Bị từ chối (ổ đang dùng) → dừng, báo "Hãy đóng các ứng dụng đang dùng ổ".
   3. exFAT / FAT32 / APFS: `diskutil eraseVolume <FS> <tên> <bsdName>`.
   4. NTFS: chạy `ntfs-format` với quyền admin (mục 4.3).
   5. Đọc lại; phân vùng NTFS mới tự gắn bằng extension qua `MountPolicy` như khi cắm ổ.

### 4.2 Format cả ổ

1. Dấu vân tay của ổ: `bsdName`, dung lượng, model, danh sách phân vùng.
2. Tháo mọi phân vùng của ổ (**không force**).
3. `diskutil eraseDisk <FS> <tên> <GPT|MBR> <bsdName>`.
4. Nếu chọn NTFS: `eraseDisk` với exFAT làm định dạng tạm, đọc lại bản đồ phân vùng để xác định phân vùng dữ liệu duy nhất (không phải EFI), rồi chạy luồng 4.1 bước 4.4 cho phân vùng đó. Nếu bước NTFS lỗi, ổ vẫn ở exFAT và dùng được; app báo rõ.

### 4.3 Công cụ `ntfs-format`

Công cụ dòng lệnh mới đóng gói trong app (`Contents/Helpers/`), ký cùng app, xây từ mã `mkntfs` đã có trong Core. Chạy qua `do shell script … with administrator privileges` như cách mount hiện tại.

Vì chạy với quyền root, công cụ tự kiểm tra lại (phòng thủ nhiều lớp), mọi giá trị nhận từ tham số:

- Thiết bị là phân vùng (`/dev/rdiskNsM`), không phải ổ nguyên.
- Dung lượng và vị trí bắt đầu khớp giá trị được truyền vào.
- Ổ chứa không phải ổ trong máy, không phải ổ khởi động, phân vùng không đang được gắn.

Sau đó:

- Chạy mkntfs lên phân vùng với vị trí bắt đầu (`-p`), kích thước sector (`-s`), tên (`-L`), cluster (`-c` nếu chọn), `-Q` nếu format nhanh.
- Với ổ MBR: đổi mã loại phân vùng thành `0x07` (sau khi kiểm tra mục MBR khớp vị trí và dung lượng phân vùng).
- Trả mã lỗi rõ ràng cho từng trường hợp để app hiển thị.

Tham số được truyền qua `quoted form` của AppleScript; tên người dùng nhập không thể chèn lệnh.

### 4.4 Trong khi format

- Sheet hiện bước hiện tại. Sau khi bắt đầu ghi: không hủy, không đóng cửa sổ.
- Thoát app khi đang format → `applicationShouldTerminate` trả `.terminateCancel` và báo cần chờ.
- Mỗi lần format ghi log: ổ, dấu vân tay, định dạng, lệnh, kết quả.

## 5. Quy tắc an toàn (`FormatSafety`)

Luôn chặn format (và tháo, với ổ hệ thống):

- Ổ trong máy (`DeviceInternal` = true).
- Ổ khởi động và mọi ổ chứa ổ con hệ thống macOS (vai trò APFS System/Data/Preboot/Recovery/VM, hoặc gắn tại `/`).
- Ổ chứa chính app đang chạy (`Bundle.main.bundleURL`).
- Phương tiện chỉ đọc.
- Ổ đang có thao tác khác (gắn, eject, format) chạy dở.

Cảnh báo thêm, vẫn cho format:

- Ổ chứa bản sao lưu Time Machine (vai trò APFS Backup hoặc có `Backups.backupdb`).
- Phân vùng chưa gắn nên không biết dung lượng đã dùng.

Nguyên tắc:

- Không bao giờ dùng tùy chọn force của `diskutil` hay DiskArbitration.
- Kiểm tra dấu vân tay ngay trước khi ghi; trong `ntfs-format` kiểm tra lại lần nữa.
- Bước xác nhận luôn yêu cầu gõ đúng tên.

## 6. Xử lý lỗi

- Lỗi hiện dạng banner trong khung chi tiết của ổ, lời lẽ dễ hiểu kèm hướng xử lý:
  - Ổ đang được dùng → đóng ứng dụng đang dùng ổ rồi thử lại.
  - Hủy hộp thoại mật khẩu → không có gì thay đổi.
  - Ổ bị rút giữa chừng → ổ có thể chưa dùng được, hãy format lại.
  - `diskutil` / `ntfs-format` lỗi → thông điệp tóm tắt; chi tiết trong log.
- Dấu vân tay lệch → "Ổ đã thay đổi kể từ khi mở hộp thoại; không có gì bị xóa."

## 7. Kiểm thử

Tự động:

- `FormatSafety`: dữ liệu mẫu mô tả DiskArbitration cho ổ trong máy, ổ ngoài, ổ khởi động, APFS các vai trò, Time Machine, chỉ đọc, dấu vân tay lệch → kiểm tra từng trường hợp chặn/cho phép/cảnh báo.
- Kiểm tra tên theo định dạng.
- `FormatPlanner`: lệnh sinh ra cho mọi tổ hợp (phân vùng / cả ổ, GPT / MBR, bốn định dạng), kể cả tên có ký tự đặc biệt, dấu nháy, tiếng Việt.
- `DiskInventory`: dựng cây từ mô tả mẫu (GPT, MBR, APFS container).
- `ntfs-format`: kiểm tra từ chối khi tham số không khớp, chạy trên file ảnh đĩa.

Tích hợp (script mới, mở rộng `scripts/integration-test.sh`):

- Tạo file ảnh đĩa, gắn bằng `hdiutil attach -nomount`, bật cờ cho phép ổ ảo (chỉ có trong build test, bản phát hành không có).
- Chạy thật mọi luồng: từng định dạng × GPT/MBR × phân vùng/cả ổ.
- Kiểm tra ổ gắn lại được, ghi/đọc file khớp checksum; NTFS kiểm tra thêm bằng `NTFSVolumeHandle` trong Core.

Thủ công:

- Chỉ dùng USB trống. **Không** format "New Volume" hay "SSD-PUBLIC" (có dữ liệu của người dùng).
- Kiểm tra ổ sau khi format trên Windows nếu có.

Hồi quy: Core (63 test), App (11 test), `scripts/integration-test.sh`.

## 8. Phát hành

- `MARKETING_VERSION` = 1.0.2.
- README (vi/en) cập nhật kèm ảnh chụp giao diện mới.
- DMG từ `scripts/build-local.sh`; merge `release-1.0.2` vào `main`, tag `v1.0.2`, GitHub release.
