# Hướng Dẫn Test CopyUSB

## Mục đích
Tài liệu này mô tả cách test các thay đổi trong bộ script CopyUSB theo 3 mức:
- Test nhanh bằng phân tích tĩnh, không cần USB thật.
- Test chạy script với dữ liệu mẫu trong thư mục `Test`.
- Test thủ công với USB thật cho các chức năng liên quan đến copy, eject và remount.

## Chuẩn bị
- Mở PowerShell tại thư mục dự án `D:\CMD\CopyUSB`.
- Nếu cần cho phép chạy script trong phiên hiện tại:
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  ```
- Nếu test các chức năng format, fix filesystem hoặc remount, nên mở PowerShell bằng quyền Administrator.

## 1. Test nhanh cờ RemountDrive
Mục tiêu: xác nhận `master_copy_check_eject.ps1` đã gate đúng các nhánh remount bằng `RemountDrive`.

Chạy:
```powershell
pwsh .\Test\Test-RemountDriveFlag.ps1
```

Kết quả mong đợi:
- Có dòng `PASS: RemountDrive flag contract is present in master_copy_check_eject.ps1`.
- Bảng kết quả phải có:
  - `RemountDrive=0` => `Capture=Skipped`, `AdminWarning=Skipped`, `AutoRemountBeforeCopy=Skipped`, `AutoRemountAfterFailure=Skipped`
  - `RemountDrive=1` => `Capture=Enabled`, `AdminWarning=Conditional`, `AutoRemountBeforeCopy=Enabled`, `AutoRemountAfterFailure=Enabled`

Ý nghĩa:
- Đây là test mô phỏng, không cần USB thật.
- Test này phù hợp khi vừa sửa logic điều kiện liên quan đến remount.

## 2. Test parse PowerShell sau khi sửa script
Mục tiêu: phát hiện nhanh lỗi cú pháp trước khi chạy thật.

Ví dụ với script chính:
```powershell
$p='D:\CMD\CopyUSB\master_copy_check_eject.ps1'
$null=$tokens=$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors) | Out-Null
if($errors.Count -eq 0){ 'PARSE_OK' } else { $errors | ForEach-Object { $_.Message } }
```

Kết quả mong đợi:
- In ra `PARSE_OK`.

Áp dụng tương tự cho script mới hoặc script vừa chỉnh sửa.

## 3. Test với dữ liệu mẫu trong thư mục Test
Mục tiêu: kiểm tra luồng copy/check cơ bản bằng dữ liệu mẫu sẵn có trong repo.

Các thư mục mẫu hiện có:
- `D:\CMD\CopyUSB\Test\Test1`
- `D:\CMD\CopyUSB\Test\Test2`
- `D:\CMD\CopyUSB\Test\Test3`
- `D:\CMD\CopyUSB\Test\Test4`

Ví dụ chạy thử một bộ dữ liệu mẫu:
```powershell
pwsh .\master_copy_check_eject.ps1 -SourceRoot "D:\CMD\CopyUSB\Test\Test3" -EjectScriptPath '' -SkipEject -RemountDrive 0
```

Lưu ý:
- Lệnh trên vẫn cần USB đích thật nếu muốn chạy trọn luồng copy.
- Dùng `-EjectScriptPath ''` để tránh gọi eject script trong lúc test.
- Giữ `-RemountDrive 0` khi chưa muốn đụng vào nhánh remount.

Khi muốn rà từng bộ test con trong thư mục `Test`, có thể chạy:
```powershell
Get-ChildItem 'D:\CMD\CopyUSB\Test' -Directory | ForEach-Object {
    pwsh .\master_copy_check_eject.ps1 -SourceRoot $_.FullName -EjectScriptPath '' -SkipEject -RemountDrive 0
}
```

Kỳ vọng:
- Script nhận đúng `SourceRoot`.
- Không chạy capture remount và không tự remount khi `-RemountDrive 0`.
- Nếu không có USB hợp lệ, script sẽ dừng sớm với log phù hợp. Đây là hành vi bình thường trong môi trường không có thiết bị thật.

## 4. Test thủ công với USB thật, không bật remount
Mục tiêu: xác nhận hành vi mặc định an toàn sau thay đổi mới.

Chạy:
```powershell
pwsh .\master_copy_check_eject.ps1 -SourceRoot "D:\CMD\CopyUSB\Test\Test3" -DestDrives F: -SkipEject -RemountDrive 0
```

Kiểm tra:
- Phần cấu hình đầu phiên có `RemountDrive    : 0`.
- Log có dòng `RemountDrive=0 -> bỏ qua capture thông tin remount và tự động remount.`
- Không có bước gọi `Remount-Usb.ps1 -Mode Capture`.
- Nếu USB mất mount giữa chừng, script không tự remount mà chỉ ghi log bỏ qua auto-remount.

## 5. Test thủ công với USB thật, bật remount
Mục tiêu: xác nhận nhánh remount vẫn hoạt động khi chủ động bật.

Chạy:
```powershell
pwsh .\master_copy_check_eject.ps1 -SourceRoot "D:\CMD\CopyUSB\Test\Test3" -DestDrives F: -SkipEject -RemountDrive 1
```

Kiểm tra:
- Phần cấu hình đầu phiên có `RemountDrive    : 1`.
- Có bước `Capture thông tin remount cho các ổ USB hợp lệ...`
- Khi chạy không phải Administrator và có script remount, sẽ hiện cảnh báo cần quyền admin cho remount.
- Nếu mô phỏng được tình huống USB rớt/mất mount trong lúc copy, script sẽ thử gọi `Remount-Usb.ps1`.

Lưu ý:
- Nhánh này phụ thuộc thiết bị thật và chưa nên xem là ổn định tuyệt đối nếu chưa test đủ trên phần cứng mục tiêu.

## 6. Checklist khi review kết quả test
- Có lỗi parse PowerShell không.
- Log đầu phiên có đúng giá trị tham số đang test không.
- Khi `RemountDrive=0`, có thật sự bỏ qua capture và auto-remount không.
- Khi `RemountDrive=1`, có giữ được hành vi remount cũ không.
- Có phát sinh thay đổi ngoài phạm vi mong muốn ở copy/check/eject không.
- Log có đủ rõ để phân biệt giữa "không bật remount" và "bật remount nhưng remount thất bại" không.

## 7. Khi nào cần chạy loại test nào
- Sửa tài liệu hoặc điều kiện `if` nhỏ quanh remount: chạy mục 1 và mục 2.
- Sửa luồng copy/check/eject nhưng không đổi thiết bị: chạy mục 2 và mục 3.
- Sửa `Remount-Usb.ps1` hoặc logic gọi remount: chạy mục 1, mục 2, mục 4 và mục 5.
- Trước khi dùng thực tế hàng loạt: nên test ít nhất 1 USB thật với `RemountDrive 0`, sau đó mới cân nhắc test `RemountDrive 1`.
