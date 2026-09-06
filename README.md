# Script copy Data tới nhiều ổ USB

Xem hướng dẫn chi tiết ở HUONG_DAN_SU_DUNG.md
Xem hướng dẫn test ở HUONG_DAN_TEST.md

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

Trong GUI, `Chế độ chạy` cho phép chọn `CopyWorkflow`, chỉ chạy
`check_copy_hash`, chỉ chạy `Check-UsbDisk`, hoặc chỉ chạy `Mp3FatSort`.
`HashLastN` chỉ bật khi `Enable check_copy_hash` được chọn.
