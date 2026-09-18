# Script copy Data tới nhiều ổ USB

Xem hướng dẫn chi tiết ở HUONG_DAN_SU_DUNG.md
Xem hướng dẫn test ở HUONG_DAN_TEST.md

## Đóng gói, cài đặt và cập nhật

Chạy `powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Distribution.ps1 -Version 1.0.0`
để tạo ZIP trong `dist`. Máy đích giải nén rồi bấm `Install.cmd`; mỗi bản cập nhật
dùng cùng thao tác. Xem [hướng dẫn cài đặt](distribution/HUONG_DAN_CAI_DAT.md).
`Build-CopyUSB.cmd` / `Build-CopyUSB.ps1` chỉ đóng gói app, không build YAFS.
Không truyền `-YafsDirectory` sẽ tạo gói Core. Để kèm YAFS đã build:

```powershell
.\Build-CopyUSB.ps1 -Version 1.1.1 -YafsDirectory D:\Source\yafs\dist\1.2.0-x86
```

Build YAFS riêng tại repo `yafs` bằng `Build-Yafs.ps1`; repo đó chứa sẵn mã nguồn
Xerces và hướng dẫn `BUILD_WINDOWS.md`. Máy đóng gói CopyUSB không cần Visual Studio
hay CMake. Một bản YAFS có thể dùng lại cho nhiều bản CopyUSB.

## Giao diện Windows và context menu

Chạy `CopyUSB-GUI.ps1` để mở GUI với đầy đủ tham số của
`master_copy_check_eject.ps1`. GUI mở console PowerShell riêng để các prompt
Y/N vẫn dùng được, đồng thời hiển thị log cập nhật liên tục và không tự thoát
sau khi copy kết thúc.

Đăng ký lệnh click phải vào folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Register-CopyUSBContextMenu.ps1 -Action Install
```

Hoặc chạy `install_copyusb_context_menu.bat`. Sau đó click phải vào folder,
chọn `CopyUSB: copy folder tới USB`; GUI sẽ tự điền folder nguồn và quét các
USB đang mount. Dùng `uninstall_copyusb_context_menu.bat` để gỡ lệnh.

Trong GUI, nút `Eject USB` nằm cạnh `Quét USB` và eject toàn bộ drive đang có
trong ô `DestDrives (USB)`. Nút này tự khóa trong lúc flow đang chạy; GUI cũng
không cho đóng cửa sổ khi tiến trình eject chưa hoàn tất.

Trong GUI, `Chế độ chạy` cho phép chọn `CopyWorkflow`, chỉ chạy
`check_copy_hash`, chỉ chạy `Check-UsbDisk`, hoặc chỉ chạy `Mp3FatSort`.
`HashLastN` chỉ bật khi `Enable check_copy_hash` được chọn.
Checkbox `Force format USB/thẻ nhớ <64GB` bật `-ForceFormatMemoryCard`; thiết bị
removable dưới 64GB sẽ được format trước khi copy (trên 32GB dùng exFAT).
Khi chọn `SyncWorkflow`, `SyncMode=Mirror` là mặc định và dùng `/MIR` để xóa
file/thư mục dư ở đích; có thể đổi sang `UpdateOnly` để giữ lại dữ liệu dư.
Trước khi sync, flow chụp các file ở cuối danh sách đích, loại các file sẽ bị
`Mirror` xóa, rồi đưa phần còn lại vào manifest. Sau sync bước hash kiểm tra cả
hai nhóm, nhằm phát hiện hiện tượng thẻ nhớ ghi đè vòng lên dữ liệu cũ.
Khi dừng bằng `Ctrl+C`, đóng console PowerShell hoặc đóng GUI, process chạy và
các process con sẽ được dọn theo cây PID.
Khi SyncWorkflow kết thúc, console riêng sẽ giữ lại và chờ Enter để xem log;
chạy với `-NoPause` nếu muốn tự động thoát.
