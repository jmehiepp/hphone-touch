# HPhone Touch

Công cụ tự động hóa Lua độc lập cho iPhone dùng Dopamine RootHide. Mục tiêu đầu tiên: iPhone 6s (ARM64), iOS 15.x. **0.1.9 là bản thử nghiệm, đang kiểm tra trên thiết bị. Không tuyên bố tương đương đầy đủ HBTouch.**

Kho Sileo dự kiến: `https://jmehiepp.github.io/hphone-touch/`. Chỉ có gói sau khi GitHub Actions build và kiểm tra thành công. Đây là kho APT riêng, Sileo là ứng dụng đọc kho. Release hiện chưa ký GPG.

## Chức năng

| Phần | Bản 0.1 |
| --- | --- |
| App iPhone và giao diện web thích ứng | Có mã nguồn |
| Danh sách, đọc, lưu, xóa script `.lua` | Có mã nguồn |
| Lua 5.4.9, log, chạy một script, dừng hợp tác | Có mã nguồn |
| Chạm pixel, Home/Power/âm lượng | Cầu IOHID; cần thử thiết bị |
| Chụp màn hình PNG | Cầu IOMobileFramebuffer; cần thử thiết bị |
| OCR | Apple Vision từ ảnh màn hình; cần thử thiết bị |
| Swipe, tìm ảnh/màu, bật app, nhập chữ, overlay | Chưa có |
| Cookie, keychain, wipe, backup/restore app | Chưa có |
| Điều phối 35 máy và 169 API tài liệu bản gốc | Chưa có |

Không dùng binary, tài nguyên, máy chủ cấp phép hoặc thương hiệu HBTouch. Báo cáo REA trước đó là tài liệu tham khảo phạm vi và hành vi, không phải chứng nhận tương thích.

## Cài và kiểm tra

1. iPhone phải jailbreak bằng **Dopamine RootHide**; chưa hỗ trợ rootless thông thường hoặc máy chưa jailbreak.
2. Sau khi kho đã xuất bản, thêm URL trên trong Sileo → Sources → +, tìm **HPhone Touch**.
3. Mở app, chạy `hello.lua`; kiểm tra log đủ ba bước. Chạy `while true do end` rồi bấm Dừng để kiểm tra hook hủy.
4. Chụp màn hình; đối chiếu ảnh với máy. Kiểm tra một chạm ở màn hình chính và Home; xác nhận bằng mắt. Thử OCR với chữ rõ trên màn hình.
5. Gỡ/cài lại gói, kiểm tra script vẫn giữ. Khởi động lại và jailbreak lại, xác nhận daemon/app hoạt động với jbroot mới.

Chỉ triển khai nhiều máy sau khi hoàn tất các bước này trên máy thử. Báo kết quả theo `docs/DEVICE_TEST.md`.

## Lua API

```lua
print('Bắt đầu')
sleep(1)                 -- giây; tối đa 86400
tap(100, 200)            -- pixel ảnh gốc, hướng dọc
key('home')              -- home, power, volumeUp, volumeDown
local png = screenshot() -- chuỗi bytes PNG
local text = ocr()       -- mảng {text, confidence, x, y, w, h}
for _, row in ipairs(text) do print(row.text) end
```

OCR dùng tọa độ chuẩn hóa 0–1, gốc trái dưới. Chạm gửi sự kiện IOHID không xác nhận app đích đã nhận. Cầu không dùng được sẽ báo lỗi rõ. Dừng dựa trên hook Lua và `sleep`; không ngắt cưỡng bức hàm C đang chờ hay tiến trình do script tự mở. Lua mở thư viện chuẩn, script chạy với quyền `mobile`; chỉ chạy script tin cậy. Không cấp quyền root cho daemon.

OCR dùng chế độ Fast/CPU để phù hợp iPhone 6s; độ chính xác và ngôn ngữ nhận dạng phụ thuộc Vision trên iOS của máy. Daemon đặt và đọc lại giới hạn 256 MiB cho chính PID của mình; chỉ cho chạy một OCR mỗi lần. Kết quả áp dụng giới hạn có trong `/api/status`.

Lua được biên dịch với `LUA_USE_IOS`; `os.execute` không khả dụng theo cấu hình iOS chính thức của Lua. Giới hạn heap Lua là 32 MiB mỗi lần chạy; log giữ tối đa 500 dòng, mỗi dòng 4096 ký tự.

## Truy cập từ PC

Daemon chỉ nghe loopback `127.0.0.1`, không mở LAN. Nó ưu tiên cổng đã lưu (mặc định 8765); nếu cổng bận, hệ thống chọn cổng trống. Cổng thực tế lưu ở `/var/mobile/Library/HPhoneTouch/port`, quyền `0600`; app đọc tự động. Mọi API yêu cầu header `X-HPhone-Token`; token riêng thiết bị lưu quyền `0600` ở `/var/mobile/Library/HPhoneTouch/token`. Từ PC, chuyển tiếp USB đến cổng đọc từ file `port`, mở địa chỉ chuyển tiếp và nhập token vào giao diện. Token giữ trong sessionStorage của tab. Hiện chưa tích hợp chuyển tiếp hay lấy token tự động vào RootHideFleet.

Các API thay đổi trạng thái chỉ dùng POST. HTTP giới hạn header 16 KiB, JSON 1 MiB, timeout 5 giây; chỉ phục vụ ba tài nguyên tĩnh cố định. Thư mục script giới hạn tên phẳng `.lua`; API lưu từ chối symlink cuối đường dẫn. Chưa có HTTPS vì chỉ nghe loopback.

## Build

Trên macOS với Xcode và [RootHide Theos](https://github.com/roothide/theos):

```sh
export THEOS=/path/to/theos
python3 scripts/fetch_lua.py
gmake package FINALPACKAGE=1
python3 scripts/apt_repo.py packages repo-out
```

Lua tải từ repo chính thức `lua/lua`, commit của tag 5.4.9 và SHA256 được ghim trước khi giải nén. Theos cũng ghim commit, dùng SDK iPhoneOS của Xcode. Pipeline kiểm tra ARM64 ALL (không yêu cầu CPU ARM64e), minimum iOS ≤15.0, plist, launch daemon, maintainer script, web và giấy phép trước khi publish. Tên kiến trúc Debian `iphoneos-arm64e` là quy ước RootHide, không phải yêu cầu chip A12.

GitHub Actions ghi bản kho phẳng vào nhánh `gh-pages` và triển khai trực tiếp qua `deploy-pages`; Pages chọn nguồn **GitHub Actions**. Pipeline chỉ publish khi compile và kiểm gói thành công; chưa thay thế kiểm thử runtime trên iPhone. Theo [API RootHide chính thức](https://github.com/roothide/Developer), code native gọi `jbroot()` khi đọc tài nguyên bootstrap; script/plist dùng đường dẫn jbroot. Không sửa bootstrap hay gỡ jailbreak khi cài tool.

## Giấy phép

Mã HPhone Touch: MIT. Lua giữ giấy phép MIT của Lua trong `lua.h`, README chính thức và gói cài. Apple frameworks và Theos không được phân phối kèm binary của dự án.
