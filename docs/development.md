# Phát triển và phát hành

## Môi trường và build

Dùng Windows 10/11 x64, .NET 10 SDK, Node.js 22+ và Python 3.13+. `global.json` cho phép các feature band ổn định của SDK 10.0. Các script chạy bằng Windows PowerShell 5.1 có sẵn trong Windows.

```powershell
npm ci --ignore-scripts
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Version 1.0.1
```

NuGet được khôi phục với `--locked-mode`; WebView2 được ghim cùng phiên bản SDK với bản ứng dụng đã nhập. Khi chủ động nâng dependency, cập nhật cả lockfile và kiểm tra lại. `npm ci` dùng `package-lock.json`.

Kết quả ở `artifacts/publish`: EXE/DLL của host, thư mục `web`, `backend`, các thư viện WebView2, README và LICENSE. Đây là bản framework-dependent: máy chạy cần .NET 10 Desktop Runtime và WebView2 Runtime. Không commit thư mục `artifacts`, `bin`, `obj` hoặc hồ sơ người dùng.

## Cấu trúc và nguồn gốc

`MainWindow` sở hữu cửa sổ và WebView2. `BackendProcess` sở hữu tiến trình PowerShell, truyền JSON theo từng dòng qua stdin/stdout và đóng tiến trình khi cửa sổ đóng. `AppPaths` quản lý đường dẫn ứng dụng và hồ sơ `%LOCALAPPDATA%\SkillsJunction`.

WebView2 chỉ ánh xạ thư mục `web` vào `https://appassets.local/`. Backend được gọi qua thông điệp JSON, không được phục vụ như tài nguyên web. Backend và giao diện giữ nguyên giao thức, cấu hình và hành vi Junction hiện có.

Gói nhập ban đầu chỉ chứa DLL/EXE, không có dự án C#. Host hiện tại được dựng lại sau khi kiểm tra hành vi và dùng ILSpy đọc host đã biên dịch. Không tuyên bố đây là source gốc của tác giả. SDK WebView2 thêm tham chiếu WPF dù dự án chỉ dùng WinForms; project bỏ tham chiếu WPF không dùng để tránh xung đột WindowsBase khi build .NET 10.

## Kiểm tra

```powershell
npm run check
npm audit --audit-level=high
python -m unittest discover -s tests -v
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Version 1.0.1
dotnet format src/SkillsJunction.Desktop/SkillsJunction.Desktop.csproj --verify-no-changes --no-restore
npm run test:desktop
```

Python kiểm tra Junction thật, lưu lựa chọn skill, bảo vệ mục có sẵn, lỗi ghi cấu hình và nội dung ZIP. Playwright khởi chạy EXE thật, kết nối WebView2 qua CDP, kiểm tra khởi động, thông điệp tiếng Việt, bật/tắt skill và đóng tiến trình backend.

Mỗi kiểm tra dùng thư mục tạm cùng `LOCALAPPDATA` riêng, không đọc cấu hình sử dụng hằng ngày. Cổng CDP chỉ mở trên loopback trong tiến trình kiểm tra; ứng dụng thông thường không bật cổng này. Để kiểm tra bản ZIP đã giải nén, đặt `APP_PUBLISH_DIR` tới thư mục chứa EXE rồi chạy `npm run test:desktop`.

## Đóng gói

Dùng cùng phiên bản ở cả bước build và đóng gói:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Version 1.0.1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 1.0.1
```

Kết quả nằm ở `artifacts/releases/SkillsJunction-v1.0.1-win-x64.zip` và `SHA256SUMS.txt`. ZIP có một thư mục gốc theo phiên bản. Script chỉ lấy các tệp cần chạy, README và LICENSE; không lấy log, hồ sơ, kiểm tra hay debug symbol. Có thể truyền `-PublishDirectory` và `-OutputDirectory` nếu cần đóng gói ở vị trí khác.

## GitHub Actions và phát hành

PR và nhánh `main` chạy cùng quy trình Windows: cài dependency theo lockfile, kiểm tra backend/package, build, kiểm tra định dạng, mở EXE thật và tạo ZIP. ZIP của CI được lưu ở mục Artifacts trong lần chạy workflow.

Sau khi PR đã merge và sẵn sàng phát hành phiên bản mới:

```powershell
git switch main
git pull --ff-only
git tag -a v1.0.1 -m 'Skills Junction v1.0.1'
git push origin v1.0.1
```

Tag chạy lại đầy đủ các bước kiểm tra. Chỉ khi đạt, job `release` nhận quyền `contents: write`, tải artifact đã kiểm tra, xác nhận SHA-256 rồi tạo GitHub Release với ZIP và checksum. Các job kiểm tra chỉ có quyền đọc. Actions được ghim theo commit SHA và Dependabot đề xuất cập nhật hằng tuần.

Quy trình không ghi đè release có sẵn. Tag và tài sản `v1.0.0` được giữ nguyên; nếu cần sửa một phiên bản đã công bố, tạo phiên bản tiếp theo. Không đưa EXE/DLL/ZIP trở lại lịch sử mã nguồn hiện tại; các commit nhập cũ vẫn tồn tại trong lịch sử Git.

## Tài liệu tham khảo

- [WebView2 với WinForms](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/winforms)
- [Ánh xạ virtual host vào thư mục](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.setvirtualhostnametofoldermapping?view=webview2-dotnet-1.0.4258.31)
- [Kiểm tra WebView2 bằng Playwright](https://playwright.dev/docs/webview2)
- [dotnet publish](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-publish)
- [Build và kiểm tra .NET trong GitHub Actions](https://docs.github.com/en/actions/tutorials/build-and-test-code/net)
- [ILSpy](https://github.com/icsharpcode/ILSpy)
