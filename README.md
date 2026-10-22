# Skills Junction

Ứng dụng Windows quản lý liên kết NTFS Junction cho các thư mục Skills.

## Chạy ứng dụng

1. Tải hoặc clone toàn bộ repo và giữ nguyên các tệp đi kèm.
2. Cài .NET 10 Desktop Runtime và Microsoft Edge WebView2 Runtime.
3. Chạy `SkillsJunction.WebView2.exe` trên Windows 10/11 (x64).

Xem `README.txt` để biết cách tạo, sửa và bật/tắt Junction.

## Bật/tắt từng skill

Chọn **Skills** trên một cặp thư mục, rồi dùng công tắc bên cạnh tên skill:

- **Tắt**: gỡ Junction riêng của skill do ứng dụng quản lý, giữ nguyên thư mục nguồn và ghi nhớ lựa chọn. Bật lại cả nhóm hoặc mở lại ứng dụng sẽ không tạo lại skill đã tắt.
- **Bật**: tạo lại Junction cho riêng skill đó.
- **Công tắc mờ**: mục ở đích đã có sẵn hoặc đã đổi nguồn, nên công tắc bị khóa để giữ nguyên dữ liệu.

Lựa chọn được lưu theo từng cặp thư mục trong `pairs.json`; cấu hình cũ vẫn đọc được.

Kiểm tra phần bật/tắt trên Windows bằng `python -m unittest discover -s tests -v`. Các kiểm tra dùng Junction thật trong thư mục tạm và hồ sơ cấu hình riêng.

## Chỉnh sửa giao diện

- `index.html`: cấu trúc trang.
- `styles.css`: bố cục và giao diện.
- `app.js`: tương tác và giao tiếp với WebView2.
- `SkillsJunction.WebView2.ps1`: phần xử lý Junction.

Repo khởi đầu từ gói ứng dụng đã biên dịch. Mã nguồn dự án C# của chương trình chủ WebView2 chưa có trong gói này. Các tệp DLL và runtime được giữ kèm để ứng dụng có thể chạy; thay đổi HTML/CSS/JS không cần biên dịch lại EXE.

Dữ liệu người dùng nằm tại `%LOCALAPPDATA%\SkillsJunction`, không nằm trong repo.
