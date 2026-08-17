# WindowsGHCS

WindowsGHCS chạy Windows trong container Docker thông qua [dockur/windows](https://github.com/dockur/windows). Script `a.sh` cài hoặc kiểm tra Docker, chuẩn bị storage, tải Windows ISO và VirtIO driver, sau đó khởi động Docker Compose.

> **Lưu ý quan trọng:** Máy chủ phải có Docker daemon đang hoạt động và thiết bị `/dev/kvm` có quyền đọc/ghi. GitHub Codespaces không phải lúc nào cũng cấp KVM hoặc Docker daemon; nếu thiếu một trong hai điều kiện này, Windows container không thể chạy đúng.

## Cách sử dụng

Tạo Codespace hoặc Ubuntu host có tối thiểu 4 CPU, 16 GB RAM và dung lượng trống phù hợp. Vì cấu hình hiện tại dùng đĩa ảo `400G`, storage cần đủ lớn khi Windows phát sinh dữ liệu; đĩa ảo có thể bắt đầu dưới dạng sparse nhưng không được để filesystem đầy.

Trong thư mục repository, chạy:

```bash
git pull origin main
chmod +x a.sh
./a.sh
```

Script sẽ hỏi xác nhận `y/n`, không phân biệt chữ hoa chữ thường. Sau đó script hỏi link ISO Windows, tải ISO thành `/mnt/custom.iso` và tải VirtIO driver thành `/mnt/driver.iso`. Nếu `/mnt/custom.iso` đã tồn tại, script dừng để tránh ghi đè bản Windows trước đó.

## Cấu hình hiện tại

| Thành phần | Giá trị |
|---|---|
| Image | `ghcr.io/dockur/windows` |
| RAM | `half` |
| CPU | `max` |
| Disk ảo | `400G` |
| Windows user | `windowsghcs` |
| Windows password | `123456` |
| Web viewer | `http://localhost:8006` |
| RDP | Cổng `3389` TCP/UDP |
| Thiết bị | `/dev/kvm`, `/dev/net/tun` |

`a.sh` cũng truyền VirtIO driver vào QEMU bằng `ARGUMENTS` và mount storage/ISO theo đúng đường dẫn mà Compose sử dụng.

## Nếu gặp lỗi Docker

Nếu lần chạy trước dừng ở `docker-ce` với mã lỗi `100`, hãy lấy code mới nhất trước khi chạy lại:

```bash
git pull origin main
./a.sh
```

Script mới sẽ kiểm tra Docker/Compose đang có sẵn, phục hồi trạng thái `dpkg`, xử lý package xung đột, thử Docker CE trước và dùng package Ubuntu làm fallback khi môi trường Codespaces không tương thích. Script không dùng `newgrp`, vì lệnh đó có thể mở shell tương tác và làm quy trình bị treo.

Nếu vẫn thất bại, hãy gửi toàn bộ phần log bắt đầu từ `Errors were encountered while processing`, cùng kết quả của:

```bash
sudo dpkg --audit
sudo docker info
ls -l /dev/kvm
```

## Giấy phép

Dự án được phát hành theo [MIT License](LICENSE), bản quyền thuộc về **Hoang Minh (MinhNekYT)**. Người khác được phép sử dụng, sao chép, sửa đổi và phân phối dự án theo các điều kiện của giấy phép MIT.
