# Kiểm tra HPhone Touch 0.1.10 trên thiết bị

Ngày 10/11/2026. Máy thử: iPhone 6s (iPhone8,1), iOS 15.8.4, Dopamine RootHide 3.0.13-30. Chỉ xác nhận máy thử này; không suy ra mọi thiết bị đều tương thích.

| Ca kiểm | Kết quả thực tế |
| --- | --- |
| Kho Sileo | Client tải index thành công; APT thấy candidate đúng tên gói |
| Cài gói | Tải HTTPS, kiểm SHA256, cài qua USB/dpkg; trạng thái install ok installed |
| App/icon | Icon có trên Home; mở app hiện Sẵn sàng |
| hello.lua từ thao tác chạm | API chạm nút Lưu & chạy; log đủ Step 1, 2, 3 và Finished |
| Chạy/dừng Lua | Script mẫu chạy; vòng lặp vô hạn dừng được; daemon còn hoạt động |
| Đọc/lưu/xóa script | Đã kiểm trên thiết bị; file thử được xóa sau kiểm tra |
| Chụp màn hình | PNG 750×1334, nội dung và màu đối chiếu đúng màn hình thật |
| Chạm | Đã xác nhận tác động vào nút chạy trong UI, có log thực thi tương ứng |
| Home | Đã quan sát chuyển từ app về màn hình Home |
| OCR | HTTP 200, 16 khối chữ từ UI app; có text, confidence và bounding box; PID daemon không đổi |
| Bộ nhớ | API kernel trả thành công; đọc lại active/inactive limit đều 256 MiB cho chính PID daemon |
| API thiếu token | HTTP 401 trên thiết bị |
| Xung đột cổng | Cổng 8765 đang bận; daemon chọn cổng khác, app đọc cổng tự động |
| Power/âm lượng | Chưa thử |
| Reboot rồi jailbreak lại | Chưa thử |
| Gỡ/cài lại | Chưa thử; nâng cấp 0.1.x giữ hello.lua và token |
| Path traversal/symlink | Qua host test chạy daemon thật với bridge stub; chưa thử lại trên iPhone |
| 35 máy/chạy dài hạn | Chưa thử |

CI có 9 kiểm tra (4 package/APT, 5 nhóm HTTP/Lua daemon). Host test dùng bridge stub, không thay thế kiểm phần cứng. Build/test/deploy: https://github.com/jmehiepp/hphone-touch/actions/runs/42780541408

OCR Fast phụ thuộc ngôn ngữ Vision trên iOS 15; không đảm bảo nhận đầy đủ dấu tiếng Việt hoặc chữ nhỏ. Ảnh, log, UDID, mật khẩu và token của máy thử giữ cục bộ, không đưa vào repo công khai.
