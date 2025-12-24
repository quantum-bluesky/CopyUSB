# Hướng Dẫn Sử Dụng CopyUSB

## Giới thiệu
Chào mừng bạn đến với bộ công cụ **CopyUSB**. Đây là tập hợp script PowerShell giúp copy dữ liệu (đặc biệt thư viện MP3) từ thư mục nguồn sang nhiều USB cùng lúc, kiểm tra tính toàn vẹn, và tháo thiết bị an toàn. Bộ công cụ này phù hợp cho việc nhân bản nội dung hàng loạt mà vẫn kiểm soát được dung lượng, tốc độ và độ tin cậy. Nội dung dưới đây mô tả cách dùng thực tế trên Windows.

> **Lưu ý trách nhiệm:** Script có thể xóa/format USB để chuẩn bị chép dữ liệu. Hãy kiểm tra kỹ tham số trước khi chạy và sao lưu dữ liệu quan trọng.

## Bắt đầu
### Yêu cầu hệ thống
- Windows 10/11 với PowerShell 5.1 trở lên (ưu tiên PowerShell 7+ nếu có).
- Quyền **Administrator** để thực hiện format, remount và thao tác thiết bị USB.
- Các tiện ích sẵn có trong Windows: `robocopy`, `diskpart`, cmdlet `Get-PnpDevice`/`Disable-PnpDevice` (để remount/reset driver).
- USB mục tiêu đủ dung lượng so với thư mục nguồn.

### Cài đặt
1. Tải mã nguồn từ kho lưu trữ về máy (zip hoặc `git clone`).
2. Giải nén và mở **Windows PowerShell** (nên chạy *Run as Administrator*).
3. Cho phép chạy script trong phiên hiện tại (không thay đổi hệ thống):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
4. Di chuyển tới thư mục chứa các file `*.ps1` của CopyUSB:
   ```powershell
   cd <đường-dẫn-thư-mục-CopyUSB>
   ```

### Tài khoản/Đăng nhập
CopyUSB không yêu cầu tài khoản hay đăng nhập. Chỉ cần phiên PowerShell có quyền Administrator.

## Tổng quan Giao diện
CopyUSB là công cụ dòng lệnh gồm các script chính:

- `master_copy_check_eject.ps1`: Quy trình tổng Copy → Check → (Remount nếu rớt USB) → Eject, chạy song song trên nhiều ổ.
- `check_copy_hash.ps1`: Kiểm tra nội dung thư mục nguồn/đích (tập trung file `.mp3`), hỗ trợ so sánh hash (MD5/SHA256).
- `Remount-Usb.ps1`: Lưu cache thông tin USB và remount lại ký tự ổ khi bị rút/không còn mount.
- `removedrv.ps1`: Tháo/eject tất cả USB đã xử lý.
- `Reset-UsbStorage.ps1`: Làm mới driver USB Storage khi cần làm sạch trạng thái thiết bị.

Tất cả script đều chạy từ PowerShell; không có giao diện đồ họa. Các tham số đều hiển thị rõ trong phần cấu hình mỗi khi chạy.

## Hướng dẫn Sử dụng Tính năng
### 1. Copy song song nhiều USB và kiểm tra tự động
**Mục đích:** Chuẩn bị USB (xóa/format khi cần), copy song song từ thư mục nguồn, kiểm tra hash tùy chọn, và eject an toàn.

**Thực hiện:**
1. Gắn các USB cần xử lý và ghi nhận ký tự ổ (ví dụ `F: G: H:`...).
2. Chạy lệnh:
   ```powershell
   .\master_copy_check_eject.ps1 -SourceRoot "D:\DuLieuNguon" -DestDrives F:,G:,H: -EnableHash -HashLastN 100 -HashAlgorithm SHA256 -LogDir .\logs
   ```
3. Xem lại cấu hình được in ra, gõ `Y` để tiếp tục (hoặc thêm `-AutoYes` để bỏ qua xác nhận).
4. Theo dõi log hiển thị; file log chi tiết được lưu trong thư mục `logs`.

**Mẹo/Lưu ý:**
- Script tự kiểm tra dung lượng, ưu tiên xóa file thừa hoặc quick format FAT32 nếu ổ đủ lớn; ổ >32GB có thể không format FAT32 được trên Windows.
- Khi phát hiện USB bị rút trong lúc copy, script sẽ thử remount (dựa trên `Remount-Usb.ps1`) rồi copy tiếp.
- Bỏ qua bước eject bằng `-SkipEject` nếu muốn giữ ổ gắn sau khi copy.

### 2. Kiểm tra nội dung và hash thư viện MP3
**Mục đích:** Đối chiếu danh sách file `.mp3` giữa nguồn và nhiều ổ đích; tùy chọn so sánh hash toàn bộ hoặc N file cuối.

**Thực hiện:**
```powershell
.\check_copy_hash.ps1 -SourceRoot "D:\DuLieuNguon" -DestDrives F:,G: -Hash -HashLastN 0 -HashAlgorithm MD5
```

**Mẹo/Lưu ý:**
- Bỏ tham số `-Hash` để chạy nhanh (so sánh tên/size). Dùng `-HashLastN <N>` để tăng tốc khi thư viện rất lớn.
- Thêm `-LogFile <path>` để gom log chung với bước copy của master script.

### 3. Lưu cache và remount USB khi bị rớt
**Mục đích:** Ghi lại thông tin ổ USB hiện tại (serial, dung lượng, partition) để gán lại đúng ký tự ổ nếu USB bị ngắt kết nối trong quá trình copy.

**Thực hiện:**
- Capture cache trước khi copy (thường master script gọi tự động):
  ```powershell
  .\Remount-Usb.ps1 -Mode Capture -Drive F:,G: -CachePath .\usb_remount_cache.json
  ```
- Khi cần remount thủ công:
  ```powershell
  .\Remount-Usb.ps1 -Mode Remount -Drive F: -CachePath .\usb_remount_cache.json -WaitSec 20
  ```

**Mẹo/Lưu ý:**
- Yêu cầu PowerShell chạy với quyền Administrator để thao tác driver/partition.
- Đảm bảo ký tự ổ không bị thiết bị khác chiếm trước khi remount.

### 4. Tháo/eject USB sau khi hoàn tất
**Mục đích:** Eject an toàn các ổ USB đã xử lý để tránh lỗi ghi.

**Thực hiện:**
```powershell
.\removedrv.ps1
```

**Mẹo/Lưu ý:**
- Trong master script, bước eject diễn ra tự động trừ khi bật `-SkipEject`.

### 5. Làm mới driver USB Storage (khi remount thất bại)
**Mục đích:** Đặt lại trạng thái driver USB trong trường hợp thiết bị không nhận hoặc gán sai ký tự ổ.

**Thực hiện:**
```powershell
.\Reset-UsbStorage.ps1
```

**Mẹo/Lưu ý:**
- Chạy với quyền Administrator; sau khi reset có thể cần rút cắm lại USB.

## Xử lý sự cố (Troubleshooting)
- **Không tìm thấy USB hợp lệ / báo Size=0:** Kiểm tra USB đã được nhận dạng trong Windows và có dung lượng thật; thử cắm lại hoặc dùng `Remount-Usb.ps1 -Mode Capture` rồi chạy master script.
- **Thiếu dung lượng trống:** Master script sẽ bỏ qua ổ không đủ dung lượng. Giảm thư mục nguồn hoặc đổi USB dung lượng lớn hơn.
- **Không format được FAT32 (>32GB):** Dùng USB nhỏ hơn hoặc format thủ công sang exFAT rồi chạy lại với tùy chọn mirror (`/MIR`) khi cần xóa file thừa.
- **Bị chặn bởi ExecutionPolicy:** Đã xử lý bằng `Set-ExecutionPolicy -Scope Process Bypass`. Nếu vẫn lỗi, mở PowerShell bằng quyền Administrator và thử lại.
- **Remount thất bại:** Đảm bảo đã capture cache trước đó; thử `Reset-UsbStorage.ps1` rồi remount lại.

## Câu hỏi thường gặp (FAQ)
- **Có thể chỉ chạy bước kiểm tra không?** Có. Dùng `check_copy_hash.ps1` độc lập để kiểm tra thư mục đích hiện có.
- **Muốn giữ nguyên dữ liệu trên USB?** Thêm `-AutoYes` và bỏ `-EnableHash`/`-SkipEject` nếu chỉ muốn copy thêm; master script chỉ xóa/format khi cần giải phóng dung lượng.
- **Có bắt buộc chạy PowerShell 7?** Không, nhưng PowerShell 7+ giúp hiệu năng tốt hơn; script tự phát hiện và ưu tiên nếu có.
- **Log lưu ở đâu?** Theo mặc định master script tạo file trong thư mục `logs` (ví dụ `copycheckeject_yyyyMMdd_HHmmss.log`). Bạn có thể chỉ định `-LogDir` riêng.

## Thông tin Liên hệ & Hỗ trợ
- Email hỗ trợ: `support@example.com`
- Điện thoại: `+84-000-000-000`
- Trang chủ/Repo: Vui lòng xem kho chứa CopyUSB nơi bạn tải script.
