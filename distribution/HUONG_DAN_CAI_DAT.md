# Cài đặt CopyUSB

1. Giải nén toàn bộ ZIP vào một thư mục (không chạy ngay bên trong ZIP).
2. Đóng CopyUSB và các console đang copy, bấm đúp `Install.cmd`.
3. Mở shortcut **CopyUSB** trên Desktop hoặc Start Menu. Có thể click phải vào
   folder nguồn → CopyUSB (Windows 11 có thể cần **Show more options**).

Cài vào `%LOCALAPPDATA%\CopyUSB`, không cần quyền admin hay Internet.
Yêu cầu Windows 10/11 với Windows PowerShell 5.1, Windows Forms và Storage module.
Chính sách công ty có thể chặn script; installer không thay đổi chính sách hệ thống.

## Cập nhật

Nhận ZIP mới, giải nén, đóng ứng dụng rồi chạy `Install.cmd` như lần đầu, bằng
cùng tài khoản Windows. Đây là gói đầy đủ, không cần cài các bản trung gian.
Installer kiểm tra SHA-256 của từng file trước khi chuyển sang bản mới.
Các phiên bản cũ được giữ trong `versions`; log và cache remount dùng chung ở
thư mục cài đặt. XML cây thư mục nằm trong từng phiên bản.
Nếu cần quay lại, đóng ứng dụng và chép nội dung `previous.txt` sang `current.txt`.
Không xóa thư mục phiên bản đang dùng; các bản cũ chiếm thêm dung lượng.

## Tính năng và quyền

Gói mặc định là Core: copy, sync, hash, kiểm tra đĩa và eject. CheckAndSort mặc định
tắt vì không có YAFS; không chọn chế độ Mp3FatSort trong gói này.
Gói có YAFS Release bật lại CheckAndSort. Sắp xếp FAT trực tiếp, sửa lỗi đĩa,
format và remount có thể cần tài khoản admin; cài đặt cho user không cấp các quyền này.

## Dành cho người đóng gói

Tại thư mục mã nguồn:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Distribution.ps1 -Version 1.0.0
# Lần thay đổi kế tiếp:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Distribution.ps1 -Version 1.0.1
# Gói đầy đủ khi đã có YAFS Release cùng DLL, COPYING, XSD và thông báo license:
.\Build-Distribution.ps1 -Version 1.1.0 -YafsDirectory C:\Build\yafs-release
```

Kết quả ở `dist\CopyUSB-<version>.zip`, kèm SHA-256 của ZIP. Chỉ gửi ZIP cho user;
thư mục `build-*` giữ lại để kiểm tra. Script dùng danh sách file ứng dụng rõ ràng,
không mang theo dữ liệu Test, log, cache thiết bị, output hay các tool ngoài luồng.
Muốn thêm thành phần ứng dụng, cập nhật `$files` trong Build-Distribution.ps1.
Installer chỉ chép các file có trong manifest. Hash phát hiện file hỏng, không phải
chữ ký xác thực nhà phát hành; chỉ cài gói từ nguồn tin cậy.

YAFS trong repo hiện liên kết DLL Debug, cần runtime Visual Studio Debug nên không
phù hợp máy người dùng. Builder từ chối đóng gói binary đó. Cần build Release và
kiểm thử trên máy sạch trước khi phân phối gói YAFS; nếu dùng VC runtime động,
máy đích cần Visual C++ Redistributable tương ứng. Không kèm runtime Debug.

Gỡ cài: dùng Register-CopyUSBContextMenu.ps1 trong phiên bản đang cài với
`-Action Uninstall`, xóa hai shortcut CopyUSB, rồi xóa thư mục cài đặt sau khi
đã lưu log cần giữ.

Bản đã cài tại đường dẫn cũ `%LOCALAPPDATA%\Programs\CopyUSB` vẫn được cập nhật tại đó nếu đọc được `current.txt`. Nếu không tạo được shortcut/menu, installer báo cảnh báo và in lệnh mở ứng dụng thủ công; ứng dụng vẫn được cài. Khi lỗi cài đặt, thông báo ghi rõ bước và đường dẫn.

## Build gói đầy đủ có YAFS

Từ mã nguồn, chạy `powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-CopyUSB.ps1 -Version 1.1.0`
(hoặc bấm Build-CopyUSB.cmd). Máy build cần Visual Studio 2022 C++, Windows SDK,
CMake và nguồn Xerces. Máy sử dụng không cần cài các công cụ này: YAFS mới liên kết
tĩnh Xerces và C++ runtime. Bản x86 mặc định dùng chung trên Windows x86/x64.
Bản Debug trong tools/yafs chỉ là bản cũ; script mới build vào dist/yafs và không
chép DLL Debug vào gói. Mã nguồn tương ứng và license nằm cùng YAFS trong source.zip.