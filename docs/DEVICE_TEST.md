# Biên bản kiểm tra thiết bị 0.1.0

Trạng thái hiện tại: **chưa thử runtime**. Không được đổi thành PASS chỉ dựa vào CI hoặc symbol có trong hệ thống.

| Ca kiểm | Kỳ vọng | Kết quả |
| --- | --- | --- |
| Cài qua Sileo | Không báo lỗi dpkg, có icon | Chưa chạy |
| Mở app | Giao diện hiện, trạng thái sẵn sàng | Chưa chạy |
| hello.lua | Log ba bước và Finished | Chưa chạy |
| Vòng lặp vô hạn → Dừng | Thoát script, daemon còn sống | Chưa chạy |
| Lưu/đọc/xóa script | Nội dung khớp UTF-8 | Chưa chạy |
| Chụp màn hình | PNG đúng nội dung, màu, kích thước | Chưa chạy |
| Chạm ảnh màn hình | App đích nhận đúng vị trí | Chưa chạy |
| Home, Power, Volume | Phím tác động đúng | Chưa chạy |
| OCR | Nội dung chữ và bounding box hợp lý | Chưa chạy |
| Reboot + jailbreak lại | App/daemon vẫn hoạt động | Chưa chạy |
| Gỡ/cài lại | Giữ nguyên script/token | Chưa chạy |
| API không token | HTTP 401 | Chưa chạy |
| Đường dẫn ../ / symlink | Từ chối, không ghi ngoài script | Chưa chạy |

Ghi kèm model/iOS, phiên bản RootHide, phiên bản gói, ngày, ảnh/log lỗi. Không đưa token, mật khẩu, UDID hoặc dữ liệu cá nhân vào issue công khai.
