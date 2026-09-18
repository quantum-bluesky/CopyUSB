# Build YAFS Release cho CopyUSB

## Một lệnh tạo gói app đầy đủ

Bấm `Build-CopyUSB.cmd` tại gốc repo để build bản 1.1.0, hoặc chỉ định version mới:

```powershell
.\Build-CopyUSB.ps1 -Version 1.1.1
```

Script build YAFS và Xerces ở chế độ Release, liên kết tĩnh `/MT`, chạy kiểm tra,
rồi đưa kết quả vào `dist\CopyUSB-1.1.1.zip`. Installer bật CheckAndSort khi có YAFS.
Không ghi đè ZIP đã phát hành; tăng version khi có thay đổi.

## Máy build và máy sử dụng

Máy build cần Windows x64, Visual Studio 2022 hoặc Build Tools 2022 với workload
**Desktop development with C++**, Windows SDK và **C++ CMake tools for Windows**.
Có thể dùng CMake 3.15+ trên PATH nếu VS chưa có CMake. Script tự tìm compiler bằng
vswhere, không cần mở Developer Command Prompt, không dùng đường dẫn máy cá nhân.
Cần mã nguồn ở `yafs` và `xerces-c-3.3.0` (hoặc truyền đường dẫn riêng cho Build-Yafs).
Script không tự tải hay cài phần mềm qua mạng.

Máy sử dụng không cần Visual Studio, CMake, DLL Xerces hoặc VC++ Redistributable
riêng cho YAFS. `yafs.exe` vẫn dùng các DLL hệ thống Windows.
Bản mặc định **x86** nhằm dùng chung cho Windows 10/11 x64 và Windows 10 x86.
Có thể chọn `-Architecture x64` cho máy Windows x64. Không cam kết chạy trên mọi
hệ điều hành/CPU; Windows ARM64, Windows cũ và máy áp chính sách chặn ứng dụng
chưa được xác nhận. CopyUSB vẫn cần PowerShell/Windows Forms; thao tác FAT trực tiếp
có thể yêu cầu quyền admin và chỉ hỗ trợ hệ thống file mà YAFS hiện có hỗ trợ.

## Chỉ build YAFS

```powershell
.\Build-Yafs.ps1 -Version 1.0.0 -Architecture x86
.\Build-Yafs.ps1 -Version 1.0.0 -Architecture x64
# Hoặc dùng nguồn ngoài repo:
.\Build-Yafs.ps1 -Version 1.0.1 -YafsSourceDirectory D:\Source\yafs -XercesSourceDirectory D:\Source\xerces-c-3.3.0
# Đóng gói lại từ bản đã build:
.\Build-Distribution.ps1 -Version 1.1.2 -YafsDirectory .\dist\yafs\1.0.0-x86
```

Có ZIP độc lập `dist\yafs\YAFS-<version>-<architecture>.zip` kèm SHA-256.
Thư mục để đưa vào CopyUSB nằm tại `dist\yafs\<version>-<architecture>`:

- `yafs.exe`, XSD, license của YAFS và Xerces, NOTICE.
- `build-info.json`: kiến trúc, phiên bản, SHA-256 và DLL phụ thuộc.
- `help.stdout.txt`, `help.stderr.txt`: kết quả kiểm tra chạy chương trình.
- `source.zip`: mã nguồn tương ứng của YAFS, Xerces và công thức build để build lại.
  Giữ file này trong gói phân phối cùng các license.

Cache build nằm riêng theo kiến trúc trong `dist\yafs\build-x86`/`build-x64`.
Nếu đổi hẳn compiler hoặc nguồn, dùng `-OutputDirectory` mới để không lẫn cache.
Nếu build bị ngắt sau khi tạo thư mục release, dùng output mới hoặc kiểm tra và
đổi tên thư mục release chưa hoàn tất trước khi chạy lại.

## Kiểm tra tự động

Build thất bại nếu compiler/linker báo lỗi, phát hiện DLL ngoài danh sách DLL
Windows cho phép, không chạy được `yafs -h`, hoặc không parse và chuyển mã XML
UTF-8 tiếng Việt bằng Xerces. Runtime của YAFS, smoke test và Xerces đều dùng `/MT`.
Kiểm tra khởi động đặt PATH chỉ còn Windows, không truyền đường dẫn thiết bị.
Đây không thay thế thử nghiệm trên máy Windows sạch và USB thử nghiệm; không chạy
sort/format/write lên USB tự động trong quá trình build.
