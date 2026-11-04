<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="Biểu tượng NTFS for Mac">

# NTFS for Mac

**Đọc và ghi ổ Windows (NTFS) ngay trong Finder — miễn phí, mã nguồn mở.**

[![Phiên bản mới nhất](https://img.shields.io/github/v/release/dovancuongadhp/ntfs-for-mac?label=release)](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest)
[![Lượt tải](https://img.shields.io/github/downloads/dovancuongadhp/ntfs-for-mac/total)](https://github.com/dovancuongadhp/ntfs-for-mac/releases)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?logo=apple)](#yêu-cầu)
[![Giấy phép: GPL v2+](https://img.shields.io/badge/license-GPL--2.0--or--later-green)](LICENSE)

[**⬇ Tải NTFS-for-Mac.dmg**](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest/download/NTFS-for-Mac.dmg)
· [Có gì mới](https://github.com/dovancuongadhp/ntfs-for-mac/releases)
· [**English**](README.md)

</div>

---

Mac đọc được ổ Windows (NTFS) nhưng không ghi được. NTFS for Mac giải quyết chuyện đó: cắm USB, ổ cứng di
động hay phân vùng Boot Camp do Windows định dạng vào là có thể sao chép, đổi tên, xoá và sắp xếp tệp trong
Finder như mọi ổ khác.

Không phải cấu hình, không phải khởi động lại, không phải cài thêm phần mềm nào: kéo app vào Applications, bật
một lần là xong.

## Mục lục

- [Ứng dụng làm được gì](#ứng-dụng-làm-được-gì)
- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Sử dụng hằng ngày](#sử-dụng-hằng-ngày)
- [Định dạng ổ](#định-dạng-ổ)
- [File Transfer (beta)](#file-transfer-beta)
- [Khi ổ chỉ mở được ở chế độ chỉ đọc](#khi-ổ-chỉ-mở-được-ở-chế-độ-chỉ-đọc)
- [Những gì chưa làm được](#những-gì-chưa-làm-được)
- [Cập nhật và gỡ bỏ](#cập-nhật-và-gỡ-bỏ)
- [Câu hỏi thường gặp](#câu-hỏi-thường-gặp)
- [Báo lỗi](#báo-lỗi)

## Ứng dụng làm được gì

- **Ghi vào ổ NTFS ngay trong Finder** — sao chép, di chuyển, đổi tên, xoá, tạo thư mục như với ổ của Mac.
- **Nằm trên thanh menu** — xem các ổ, dung lượng đã dùng và ổ có ghi được không; mở, gắn hoặc đẩy ổ ra chỉ
  với một cú bấm. Muốn giữ ổ nào ở chế độ chỉ đọc cũng được.
- **Quản lý và định dạng ổ** — cửa sổ giống Disk Utility hiện mọi ổ cùng các phân vùng, và định dạng một phân
  vùng hoặc cả ổ ngoài thành NTFS, exFAT, FAT32 hay APFS. Ổ của chính máy Mac được bảo vệ.
- **Bảo vệ dữ liệu** — khi ghi có thể làm hỏng ổ (ví dụ Windows đang ngủ đông, hoặc ổ bị rút mà chưa đẩy ra),
  ổ được mở ở chế độ chỉ đọc và app hướng dẫn cách khắc phục.
- **Không sinh tệp `._`** — thẻ Finder và các thông tin khác của Mac được lưu bên trong ổ, nên trên Windows
  không thấy các tệp `._` lạ.
- **Tiếng Việt và tiếng Anh** — theo ngôn ngữ của máy, hoặc tự chọn trong Cài đặt.
- **Miễn phí** — không dùng thử, không thuê bao, không quảng cáo, không thu thập dữ liệu.

## Yêu cầu

- **macOS 26 (Tahoe) trở lên.**
- Mọi máy Mac, chip Apple silicon hay Intel đều được.

## Cài đặt

1. **Tải** [`NTFS-for-Mac.dmg`](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest/download/NTFS-for-Mac.dmg)
   rồi mở ra.
2. **Kéo NTFS for Mac vào thư mục Applications.**
3. **Mở ứng dụng.** App chưa được Apple công chứng (notarize), nên lần đầu macOS sẽ chặn:
   1. Bấm **Xong** trong hộp thoại cảnh báo.
   2. Mở **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, kéo xuống dưới và bấm **Vẫn mở**.

   Hoặc, nếu bạn quen dùng Terminal, chạy lệnh này một lần:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/NTFS for Mac.app"
   ```
4. **Bật NTFS for Mac.** App cho biết NTFS for Mac đã bật chưa, kèm nút mở đúng chỗ trong Cài đặt hệ thống:
   **Cài đặt chung → Mục đăng nhập & tiện ích mở rộng → Tiện ích mở rộng hệ thống tệp**. Bật **NTFS for Mac**.
5. **Cắm ổ vào.** Ổ hiện trong Finder và ghi được ngay. Nếu ổ đã cắm từ trước, bấm **Gắn** cạnh tên ổ trên
   thanh menu.

## Sử dụng hằng ngày

NTFS for Mac nằm trên thanh menu (không có biểu tượng trên Dock). Bấm vào biểu tượng để xem các ổ NTFS:

| Bạn thấy | Dùng để |
| --- | --- |
| Trạng thái | **Đọc và ghi**, **Chỉ đọc — lý do**, **Chưa gắn**… |
| Thanh dung lượng | Ổ đã đầy tới đâu |
| **Cho phép ghi** | Tắt để giữ ổ ở chế độ chỉ đọc. Được ghi nhớ riêng cho từng ổ |
| Nút thư mục | Mở ổ trong Finder |
| **Gắn** | Dùng ổ đang cắm nhưng chưa được gắn |
| Nút đẩy ra | Đẩy ổ ra an toàn |

**Mở NTFS for Mac…** mở cửa sổ chính, có mọi ổ ở thanh bên và một trang cho từng ổ. **Cài đặt…** cho phép mở
app khi đăng nhập, chọn ngôn ngữ và kiểm tra NTFS for Mac đã bật chưa.

> [!IMPORTANT]
> Luôn **đẩy ổ ra** (trong Finder hoặc trên thanh menu) trước khi rút, để mọi thay đổi được lưu hết vào ổ.

## Định dạng ổ

Trong cửa sổ chính, chọn một phân vùng hoặc cả ổ rồi bấm **Định dạng…**. Có thể chọn NTFS, exFAT, FAT32 hoặc
APFS; khi xoá cả ổ thì chọn thêm GPT hoặc MBR.

> [!WARNING]
> Định dạng sẽ xoá sạch mọi thứ trên phân vùng hoặc ổ đó. Hãy chép ra những gì cần giữ trước.

App cẩn thận để không xoá nhầm:

- App liệt kê chính xác phần nào sẽ bị xoá, và bạn phải gõ tên ổ để xác nhận.
- Nếu ổ bị rút ra hoặc thay đổi giữa chừng, app dừng lại và không xoá gì.
- Ổ trong máy Mac và ổ đang chạy macOS không định dạng được.
- Định dạng NTFS sẽ hỏi mật khẩu máy Mac bằng hộp thoại quen thuộc của macOS. App không bao giờ thấy mật khẩu đó.

## File Transfer (beta)

NTFS for Mac **2.2.0**, đang có bản [beta](https://github.com/dovancuongadhp/ntfs-for-mac/releases), thêm trang
**File Transfer**: hai ngăn duyệt tệp cạnh nhau để chép qua lại giữa mọi ổ và thư mục, có danh sách tiến trình,
tạm dừng và tiếp tục, thử lại tệp lỗi, và hỏi bạn khi tệp hay thư mục đã có sẵn. Đây là bản beta: hãy thử với
những tệp bạn đã có bản sao lưu.

## Khi ổ chỉ mở được ở chế độ chỉ đọc

NTFS for Mac không bao giờ ghi vào ổ có thể đang không an toàn. Khi ổ hiện **Chỉ đọc**, lý do được ghi ngay
bên cạnh:

| Trạng thái | Vì sao | Cách xử lý |
| --- | --- | --- |
| Windows đang ngủ đông | Windows đang ngủ đông hoặc bật Khởi động nhanh (Fast Startup) nên vẫn giữ ổ | Vào Windows, giữ **Shift** khi bấm **Shut Down** (hoặc tắt Fast Startup), rồi cắm lại ổ |
| Chưa được đẩy ra an toàn | Ổ bị rút mà chưa đẩy ra, hoặc Windows chưa tắt đúng cách | Cắm vào Windows rồi tắt máy bình thường, hoặc bấm **Vẫn cho ghi…** (những thay đổi Windows chưa kịp lưu có thể bị mất) |
| Ổ cần được kiểm tra | Windows yêu cầu kiểm tra ổ | Chạy `chkdsk /f` cho ổ trên Windows rồi cắm lại |
| Ổ bị chống ghi | Công tắc khoá trên ổ hoặc thẻ nhớ đang bật | Gạt công tắc khoá sang vị trí mở |
| Lỗi ghi | Ghi bị lỗi nên đã dừng để bảo vệ tệp của bạn | Đẩy ổ ra, kiểm tra lại cáp hoặc chính ổ |
| Đã tắt ghi | Bạn đã tắt **Cho phép ghi** cho ổ này | Bật lại **Cho phép ghi** |
| Chỉ đọc (trình điều khiển của macOS) | NTFS for Mac chưa được bật | Bật lên (bước 4 trong [Cài đặt](#cài-đặt)) |

## Những gì chưa làm được

- Đổi kích thước, thêm hoặc xoá phân vùng (chỉ định dạng một phân vùng hoặc xoá cả ổ).
- Sửa ổ bị hỏng (hãy dùng `chkdsk` trên Windows).
- Đổi phân quyền tệp của Windows.
- Mở ổ mã hoá BitLocker hoặc tệp mã hoá EFS.

## Cập nhật và gỡ bỏ

**Cập nhật:** NTFS for Mac tự kiểm tra phiên bản mới trong **Cài đặt**. Bạn cũng có thể tải DMG mới rồi kéo app
vào Applications, chọn thay thế bản cũ.

**Gỡ bỏ:** thoát app (menu → **Thoát**) rồi kéo **NTFS for Mac** từ Applications vào Thùng rác. Chỉ còn lại vài
tệp cài đặt nhỏ.

## Câu hỏi thường gặp

<details>
<summary><b>Ghi vào ổ có an toàn không?</b></summary>

Việc đọc và ghi NTFS do [ntfs-3g](https://github.com/tuxera/ntfs-3g) đảm nhận, thư viện đã được dùng trên Linux
hơn mười năm, và NTFS for Mac từ chối ghi khi ổ không ở trạng thái sạch (xem
[Khi ổ chỉ mở được ở chế độ chỉ đọc](#khi-ổ-chỉ-mở-được-ở-chế-độ-chỉ-đọc)). Như với mọi công cụ ổ đĩa, hãy sao
lưu tệp quan trọng và luôn đẩy ổ ra trước khi rút.
</details>

<details>
<summary><b>Có cần cài macFUSE, kernel extension hay tắt SIP không?</b></summary>

Không. NTFS for Mac dùng cơ chế thêm hệ thống tệp của chính Apple (FSKit). Mọi thứ nằm gọn trong app.
</details>

<details>
<summary><b>Vì sao macOS báo không mở được ứng dụng?</b></summary>

App chưa được Apple công chứng. Làm theo bước 3 trong [Cài đặt](#cài-đặt) một lần, sau đó app mở bình thường.
</details>

<details>
<summary><b>Có chạy trên macOS 15 Sequoia hoặc cũ hơn không?</b></summary>

Không. App cần macOS 26 trở lên.
</details>

<details>
<summary><b>Ổ không hiện ra, hoặc hiện "Không hỗ trợ".</b></summary>

Thanh menu chỉ liệt kê ổ NTFS, nên trước hết hãy xem định dạng của ổ trong cửa sổ chính. **Không hỗ trợ — ổ mã
hóa BitLocker hoặc bị hỏng** nghĩa là ổ đang mã hoá BitLocker (tắt BitLocker trên Windows) hoặc bị lỗi (chạy
`chkdsk /f` cho ổ trên Windows).
</details>

<details>
<summary><b>Có thật sự miễn phí không?</b></summary>

Có. Đây là phần mềm mã nguồn mở theo giấy phép GNU GPL v2 trở lên: không dùng thử, không quảng cáo, không thu
thập dữ liệu.
</details>

## Báo lỗi

Hãy [mở issue](https://github.com/dovancuongadhp/ntfs-for-mac/issues/new) và cho biết:

- phiên bản macOS và dòng máy Mac,
- phiên bản NTFS for Mac (**Cài đặt → Giới thiệu**),
- bạn đã làm gì, mong đợi điều gì và thực tế xảy ra điều gì.

Nếu được, dán thêm kết quả của lệnh Terminal này, chạy ngay sau khi lỗi xảy ra:

```sh
log show --last 10m --predicate 'subsystem BEGINSWITH "com.docuong.ntfsformac"'
```

---

NTFS for Mac là phần mềm tự do theo [Giấy phép Công cộng GNU phiên bản 2 trở lên](LICENSE), xây dựng trên
[ntfs-3g](https://github.com/tuxera/ntfs-3g). Dành cho lập trình viên: xem [CONTRIBUTING.vi.md](CONTRIBUTING.vi.md)
để tự build và tham gia đóng góp.

NTFS, Windows và BitLocker là thương hiệu của Microsoft Corporation. macOS và Finder là thương hiệu của Apple Inc.
Dự án này không liên kết với và không được Microsoft hay Apple bảo trợ.
