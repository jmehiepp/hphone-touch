# Điều phối HPhone Touch qua USB

`pc/app.py` là giao diện Windows/macOS để chọn nhiều iPhone đã cài HPhone Touch, tải script, chạy, dừng và kiểm tra trạng thái. Công cụ không thực hiện jailbreak, nâng cấp iOS hay xóa bootstrap. Một máy lỗi được ghi riêng; các máy khác tiếp tục. Mặc định tối đa bốn máy xử lý đồng thời; các lệnh cho cùng một máy được xếp tuần tự.

## Chạy từ mã nguồn

Dùng Python 3.11 trở lên có Tk. Trên Windows cần Apple Mobile Device Service/driver hoạt động (iMazing hoặc Apple Devices đã nhận máy).

```powershell
py -m venv .venv-fleet
.venv-fleet\Scripts\python -m pip install -r pc/requirements.txt
.venv-fleet\Scripts\python pc/app.py
```

Phiên bản phụ thuộc được ghim theo môi trường triển khai hiện tại: pymobiledevice3 11.50.3, Paramiko 5.1.0. Mã bộ điều phối và kiểm thử không nhập các phụ thuộc này cho đến khi thực sự quét/kết nối thiết bị.

1. Jailbreak bằng Dopamine RootHide và cài HPhone Touch từ kho Sileo trên từng máy. Cài OpenSSH nếu chưa có.
2. Cắm các iPhone qua hub có nguồn phù hợp; mở khóa và bấm Tin cậy PC. Bấm **Quét USB**.
3. Chọn máy rồi bấm **Kết nối máy đã chọn**. Mỗi máy có hộp nhập tài khoản `mobile` hoặc `root` và mật khẩu SSH riêng, được che trên màn hình. Có thể bỏ qua một máy trong danh sách.
4. Chọn `.lua` trên PC. **Tải lên** chỉ lưu; **Tải lên & chạy** lưu rồi gửi chạy. Hoặc nhập tên script đã có trên iPhone và bấm **Chạy**. Chỉ các dòng đang được chọn mới nhận thao tác.
5. **Cập nhật trạng thái** đọc trạng thái hiện tại; **Dừng** yêu cầu dừng script trên các máy đã chọn. Khi lỗi, kiểm tra dòng lỗi, cáp và trạng thái jailbreak, rồi kết nối lại. Công cụ không tự gửi lại lệnh chạy sau lỗi mạng vì script có thể đã bắt đầu chạy.

Một máy chưa jailbreak, thiếu gói, thiếu OpenSSH hoặc chưa Tin cậy sẽ báo lỗi cụ thể và không ngăn các máy còn lại hoạt động. Đây là điều phối các thiết bị đã chuẩn bị sẵn, không phải công cụ tự jailbreak 35 máy.

## Kết nối và báo cáo

Mọi kết nối dùng USB qua usbmuxd. Công cụ đọc token và cổng thực tế qua SSH, sau đó gọi HTTP qua socket USB đến cổng đó. Bản 0.2 đọc `/api/summary` để tránh tải toàn bộ log của mọi máy; chỉ lùi về `/api/status` khi máy cũ trả 404 cho endpoint mới. Không dò LAN, không mở listener LAN và không giả định mọi máy dùng chung mật khẩu hoặc cùng cổng daemon.

Mật khẩu chỉ tồn tại trong lời gọi xác thực. Token API được giữ trong bộ nhớ phiên; bấm **Ngắt kết nối** hoặc đóng cửa sổ để loại bỏ tham chiếu token. Python không bảo đảm xóa vật lý mọi bản sao chuỗi trong RAM. SSH kết thúc ngay khi lấy xong token/cổng; không giữ phiên shell root và không chạy sudo.

Chỉ dấu vân tay khóa công khai SSH được lưu tại `~/.hphone-touch/ssh-host-keys/<UDID>.json`. Khóa đổi sẽ chặn kết nối; công cụ không tự chấp nhận khóa mới. Lần đầu ghi nhận sau khi xác thực và kiểm tra daemon thành công. Nếu đã cài lại jailbreak và muốn thay khóa đã lưu, kiểm tra đúng thiết bị rồi chủ động xóa đúng tệp dấu vân tay của máy đó.

**Xuất báo cáo** ghi JSON gồm model/iOS, UDID, trạng thái, số script, phiên bản và lỗi vận hành. Không xuất token, mật khẩu, mã Lua hay log script. Báo cáo có thông tin nhận dạng thiết bị; lưu trong dự án nội bộ của chủ máy.

Đóng cửa sổ không dừng các script đang chạy trên iPhone. Bấm **Dừng** và kiểm tra trạng thái trước khi đóng nếu muốn kết thúc công việc trên điện thoại.

## Đóng gói Windows

Trong môi trường Windows có các phụ thuộc ở trên và PyInstaller:

```powershell
pyinstaller --clean --noconfirm pc/HPhoneTouchFleet.spec
```

Kết quả mặc định là `dist/HPhoneTouchFleet.exe`; Apple USB driver vẫn phải được cài riêng. Bản Windows đã được build và chạy kiểm tra khởi tạo Tk, bảng thiết bị, chọn dòng và nhập các thư viện USB/SSH trong chính EXE. Kiểm tra này không kết nối điện thoại, không xác thực SSH và không thay thế thử chạy script thật qua EXE.

## Kiểm thử và giới hạn

```powershell
py tests/test_fleet.py
node --check web/app.js
```

Kiểm thử dùng transport/thiết bị giả để xác minh giới hạn luồng, thứ tự tải→chạy, chống gửi lặp trên cùng máy, lỗi từng máy, kết nối lại, thay khóa SSH, header xác thực và báo cáo không chứa bí mật. Kiểm thử này không chứng minh vận hành đủ 35 máy, chất lượng hub/cáp hoặc khả năng jailbreak lại sau reboot. Cần kiểm tra thực tế từng profile iOS/RootHide và một lô nhỏ trước khi ghi nhận nghiệm thu cả dàn.

## Giao diện trên iPhone / trình duyệt USB

Dashboard có phím tắt lưu/chạy/đoạn chọn; danh sách job để dừng riêng; log và xuất log; tìm tài liệu API; hẹn giờ và tự chạy. Khung ảnh có chụp tự động không chồng yêu cầu, zoom, chọn màu/chèn mẫu nhiều màu, chạm/kéo vuốt và cắt ảnh mẫu PNG. Ảnh/tệp được tải lên qua API tệp trong thư mục dữ liệu script; mỗi lần tối đa 700 KiB.

Các khả năng native phụ thuộc bridge và quyền thực tế trên máy. Dashboard hiển thị lỗi trả về thay vì khẳng định thao tác đã có hiệu lực trong ứng dụng đích. Dashboard gửi heartbeat khi đang hiển thị để daemon định tuyến dialog/toast về đúng giao diện. Sự kiện có đích `overlay` được để cho helper SpringBoard xử lý; xem [hướng dẫn overlay](OVERLAY.md) để biết điều kiện kích hoạt. Phần dashboard tự nó chỉ hiển thị thông báo khi đang mở.
