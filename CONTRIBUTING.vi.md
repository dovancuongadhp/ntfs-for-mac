# Phát triển NTFS for Mac

NTFS for Mac được xây dựng thế nào, cách tự build và cách tham gia đóng góp. Hướng dẫn sử dụng app nằm ở
[README](README.vi.md). [English](CONTRIBUTING.md)

## Cách hoạt động

```
NTFS for Mac.app
├── Contents/MacOS/NTFS for Mac                ← ứng dụng thanh menu và quản lý ổ (SwiftUI)
├── Contents/Helpers/ntfs-format, ntfs-mkfs, libNTFSDiskOpen.dylib    ← công cụ định dạng NTFS
└── Contents/Extensions/NTFSExtension.appex    ← tiện ích hệ thống tệp FSKit
        └── NTFSCore → libntfs-3g              ← lõi đọc ghi NTFS
```

- **Ứng dụng thanh menu** theo dõi ổ đĩa qua DiskArbitration, nhận diện ổ NTFS từ boot sector, quyết định ổ có
  an toàn để gắn đọc-ghi hay không, rồi yêu cầu FSKit gắn ổ bằng tiện ích mở rộng.
- **Tiện ích FSKit** (`ntfsrw`) chạy ở chế độ người dùng, chuyển các thao tác của Finder thành lời gọi tới
  libntfs-3g để đọc ghi trực tiếp cấu trúc NTFS trên thiết bị. Thuộc tính mở rộng của macOS được lưu thành
  alternate data stream của NTFS, nên không sinh tệp `._`.
- **Định dạng** dùng `diskutil` cho exFAT, FAT32, APFS và bảng phân vùng. Với NTFS, công cụ `ntfs-format` kiểm tra
  lại phân vùng, chặn không cho phân vùng bị gắn trong lúc làm việc, rồi mở ổ rời thông qua macOS trước khi chạy
  `mkntfs` của ntfs-3g. macOS từ chối mở trực tiếp ổ đó, kể cả với quản trị viên. Xoá cả ổ thành NTFS sẽ xoá
  thành exFAT bằng `diskutil` trước, rồi chuyển phân vùng sang NTFS.
- **File Transfer** (2.2.1) là bộ chép tệp nằm trong app (`Core/Sources/NTFSTransfer`): tệp được ghi dưới
  tên tạm, có thể kiểm tra lại bằng SHA-256, rồi mới đổi tên khi xong.

## Tự build từ mã nguồn

Yêu cầu: **Xcode 26** trở lên. Chỉ cần [XcodeGen](https://github.com/yonaskolb/XcodeGen) khi sửa `project.yml`
(hoặc thêm tệp mã nguồn cho app).

ntfs-3g là git submodule, nên hãy clone kèm submodule:

```sh
git clone --recursive https://github.com/dovancuongadhp/ntfs-for-mac.git
# hoặc với bản clone sẵn có: git submodule update --init
```

**Không có tài khoản Apple Developer:** chạy `scripts/build-local.sh`. Script tạo app ký ad hoc và
`build/NTFS-for-Mac.dmg`, dùng được trên chính máy của bạn. Xcode không chịu ký tiện ích mở rộng khi chưa chọn
team, nên hãy dùng script thay vì build trong Xcode.

**Có tài khoản**, để debug trong Xcode và phát hành công khai:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # đặt DEVELOPMENT_TEAM bằng Team ID của bạn
xcodegen generate                                        # chỉ cần sau khi sửa project.yml
open NTFSForMac.xcodeproj                                # build và chạy scheme NTFSForMac
```

Hãy chép app đã build vào `/Applications` trước khi bật tiện ích, vì macOS chỉ hiện tiện ích của các app đã cài.
Thay app bằng một bản ký khác sẽ huỷ đăng ký tiện ích cho tới khi bạn bật lại.

| Lệnh | Chức năng |
| --- | --- |
| `swift test --package-path Core` | Unit test cho các package lõi (cầu nối libntfs-3g, định dạng, chép tệp), dùng ảnh đĩa tạo tự động |
| `xcodebuild -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO test` | Unit test của ứng dụng |
| `scripts/build-local.sh` | Build Release và DMG cho máy của bạn: ký bằng chứng chỉ "Apple Development" miễn phí nếu có, nếu không thì ký ad hoc |
| `scripts/integration-test.sh` | Gắn một ảnh NTFS thử qua tiện ích đã cài và kiểm tra dữ liệu còn nguyên sau khi gắn lại |
| `scripts/format-integration-test.sh` | Chỉ định dạng ảnh đĩa tạm (không bao giờ đụng tới ổ thật) bằng công cụ đã build và `diskutil`, rồi kiểm tra kết quả |
| `scripts/make-dmg.sh [app] [dmg]` | Đóng gói app thành DMG kéo-thả để cài (mặc định dùng bản Release chưa ký) |
| `scripts/release.sh` | Archive, ký Developer ID, công chứng, staple và tạo DMG cuối cùng |
| `scripts/unregister-build-copies.sh` | Gỡ các bản trong `build/` khỏi danh sách tiện ích của Cài đặt hệ thống (mỗi lần build lại thêm một bản). Hai script trên tự chạy nó; sau khi build hoặc chạy test bằng Xcode thì chạy tay |
| `swift scripts/make-icon.swift` | Tạo lại biểu tượng ứng dụng |

## Cấu trúc dự án

| Đường dẫn | Nội dung |
| --- | --- |
| `App/` | Ứng dụng thanh menu và quản lý ổ: danh sách ổ (DiskArbitration), gắn ổ, định dạng, cài đặt từng ổ, File Transfer, cửa sổ chính và các trang |
| `Extension/` | Tiện ích hệ thống tệp FSKit (`ntfsrw`) |
| `Core/` | Swift package: ntfs-3g (`CNTFS`), API Swift bọc ngoài (`NTFSCore`), nhận diện boot sector (`NTFSProbe`), công cụ định dạng NTFS (`NTFSFormat`, `ntfs-format`), bộ chép tệp (`NTFSTransfer`) và các định danh dùng chung giữa app và tiện ích (`NTFSShared`) |
| `AppTests/` | Unit test của ứng dụng |
| `scripts/` | Script build, đóng gói, phát hành và kiểm thử tích hợp |
| `docs/` | Tài liệu thiết kế, kế hoạch triển khai và ghi chú phát hành |

## Phiên bản

Phiên bản được đánh số `chính.phụ.sửa-lỗi`. Giống macOS, mỗi phiên bản chính có thêm một tên riêng, ở đây là tên
một loài hoa bằng tiếng Anh và không bao giờ dùng lại. Các bản cập nhật phụ (thêm tính năng) và sửa lỗi giữ tên của
phiên bản chính. Mỗi bản phát hành ghi đủ số phiên bản kèm tên, để 2.0.0 và 2.0.1 không bao giờ bị nhầm:

| | Quy ước | Ví dụ |
| --- | --- | --- |
| Tên bản phát hành | NTFS for Mac *phiên bản* *Tên* | NTFS for Mac 2.1.0 Lotus |
| Tag Git | v*phiên bản* | v2.1.0 |
| Nhánh phát hành | release-*phiên bản*-*tên* | release-2.1.0-lotus |

Phiên bản chưa có tên thì bỏ phần tên: NTFS for Mac 1.0.1, nhánh `release-1.0.1`. Bản beta thêm `-beta.N` vào tag
(`v2.2.0-beta.1`) và được phát hành dưới dạng pre-release.

| Phiên bản | Tên | Điểm nổi bật |
| --- | --- | --- |
| 2.x | **Lotus** (hoa sen) | Quản lý ổ và định dạng ổ, kể cả NTFS; File Transfer (2.2.0) |
| 1.0.x | — | Bản đầu tiên: đọc và ghi ổ NTFS trong Finder |

Xem [nhật ký thay đổi](CHANGELOG.md) để biết mọi thay đổi.

## Đóng góp

Mọi đóng góp đều được hoan nghênh: báo lỗi, dịch thuật, tài liệu và mã nguồn.

1. Với thay đổi lớn hơn một bản sửa nhỏ, hãy mở issue trước để thống nhất hướng làm.
2. Fork repository và tạo nhánh mới từ `main`.
3. Chạy unit test (`swift test --package-path Core` và test của app ở trên); nếu sửa tiện ích mở rộng, chạy thêm
   `scripts/integration-test.sh`.
4. Mở pull request, mô tả bạn đã thay đổi gì và kiểm thử ra sao.

Muốn thêm hoặc sửa bản dịch, hãy mở `App/Localizable.xcstrings` bằng Xcode.

## Lời cảm ơn

- [ntfs-3g](https://github.com/tuxera/ntfs-3g) của Tuxera và cộng đồng đóng góp — lõi NTFS của ứng dụng này.
- [FSKit](https://developer.apple.com/documentation/fskit) của Apple, giúp hệ thống tệp chạy ở chế độ người dùng
  trên macOS trở thành hiện thực.

## Giấy phép

NTFS for Mac là phần mềm tự do phát hành theo **Giấy phép Công cộng GNU phiên bản 2 trở lên** (GPL-2.0-or-later),
cùng giấy phép với ntfs-3g. Xem [LICENSE](LICENSE).
