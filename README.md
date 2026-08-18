# DockerGHCS

DockerGHCS chạy Windows trong container Docker thông qua [dockur/windows](https://github.com/dockur/windows). Script `a.sh` cài hoặc kiểm tra Docker, chuẩn bị storage, tải Windows ISO và VirtIO driver, sau đó khởi động Docker Compose.

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

## Cài từ repository khác

Bạn có thể chạy script trong một repository khác bằng cách sao chép đoạn lệnh sau:

```bash
wget -O a.sh https://raw.githubusercontent.com/MinhNekYT/DockerGHCS/refs/heads/main/a.sh
chmod +x a.sh
bash a.sh
```

Khi chạy, `a.sh` kiểm tra file cấu hình trong cùng thư mục với script. Nếu thiếu `windows.yaml` hoặc `macos.yaml`, script tự tải file tương ứng từ DockerGHCS bằng các URL raw chính thức. Vì vậy repository khác không cần chép sẵn các file YAML.

Nếu package, Docker daemon, QEMU/KVM, OVMF và noVNC đã có sẵn, script sẽ bỏ qua bước cài lại. Khi chạy lại, script giữ nguyên ISO và `/mnt/a.img`, dừng container Docker cũ trước khi chạy Compose, hoặc dừng QEMU/noVNC cũ trước khi chạy Proxmox. Trước khi chạy Proxmox, script sẽ kill mọi process đang giữ **TCP hoặc UDP port từ 5900 đến 5999**. `custom.iso` không bị ghi đè; nếu file hợp lệ đã tồn tại, script dùng lại file đó và không hỏi link ISO lần nữa.

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

Script mới sẽ kiểm tra Docker/Compose đang có sẵn, phục hồi trạng thái `dpkg`, xử lý package xung đột, thử Docker CE trước và dùng package Ubuntu làm fallback khi môi trường Codespaces không tương thích. Khi Docker đã hoạt động, script bỏ qua cài lại package. Script không dùng `newgrp`, vì lệnh đó có thể mở shell tương tác và làm quy trình bị treo.

Nếu vẫn thất bại, hãy gửi toàn bộ phần log bắt đầu từ `Errors were encountered while processing`, cùng kết quả của:

```bash
sudo dpkg --audit
sudo docker info
ls -l /dev/kvm
```

## Chọn Windows, macOS hoặc Proxmox

Khi chạy `a.sh`, script hiển thị menu:

```text
1) Windows
2) macOS
3) Proxmox (QEMU/KVM)
```

Nhập `1` để dùng `windows.yaml` và cài Windows từ link ISO do bạn cung cấp. Nhập `2` để dùng `macos.yaml`; script không hỏi Windows ISO và không thêm `USERNAME` hoặc `PASSWORD` vào cấu hình macOS. Lần đầu macOS khởi động, image `dockurr/macos` sẽ tự tải bộ cài cần thiết.

Cấu hình macOS sử dụng `VERSION: "15"`, `RAM_SIZE: "half"`, `CPU_CORES: "max"`, `DISK_SIZE: "400G"`, `/dev/kvm`, `/dev/net/tun`, cổng web `8006` và VNC `5900`. Cấu hình này cần Linux host có KVM, CPU hỗ trợ AVX2, tối thiểu 4 GB RAM và ít nhất 32 GB dung lượng trống. GitHub Codespaces chỉ chạy được nếu Codespace/host thực sự cấp Docker daemon và `/dev/kvm`.

Theo tài liệu chính thức của dockur/macos, macOS được cung cấp bởi Apple và điều khoản sử dụng của Apple có thể giới hạn việc cài đặt trên phần cứng không phải Apple. Chỉ sử dụng cấu hình này khi bạn có quyền và giấy phép phù hợp.

## Proxmox qua QEMU/KVM

Nhập `3` trong menu để chạy Proxmox VE 9.2-1 trực tiếp qua QEMU/KVM, không dùng Docker Compose và không dùng `hostfwd`. Script sẽ cài `qemu-system-x86`, `qemu-utils`, `ovmf`, `cpulimit`, `novnc`, `websockify`, `psmisc`, `unzip` và `python3-pip`; `psmisc` cung cấp `fuser` để dừng process trên dải cổng; nếu Ubuntu repository có package `qemu-kvm` thì cũng cài thêm; tải ISO chính thức vào `/mnt/proxmox-ve_9.2-1.iso`; kiểm tra SHA256; tạo `/mnt/a.img` nếu chưa có; sau đó khởi động QEMU với 2 vCPU, 8 GB RAM, UEFI OVMF, VNC nội bộ `localhost:5900` và noVNC ở cổng `8006`.

Cấu hình Proxmox bỏ `hostfwd` theo yêu cầu. Trước khi khởi động, script kill toàn bộ process đang chiếm TCP/UDP port 5900–5999; chỉ dùng lựa chọn này nếu bạn chấp nhận dừng mọi dịch vụ trong dải cổng đó. Vì vậy không có chuyển tiếp RDP/3389 tự động; truy cập giao diện Proxmox qua noVNC ở cổng 8006. QEMU vẫn dùng user-mode networking cho kết nối outbound, nhưng không mở host port forwarding.

QEMU được tắt audio bằng `QEMU_AUDIO_DRV=none` và `-audiodev driver=none,id=noaudio`, vì Proxmox không cần PipeWire. Các cảnh báo như `can't load config client.conf` của PipeWire thường không phải nguyên nhân chính; script đã tránh khởi tạo audio và lưu log QEMU tại `/tmp/dockerghcs-proxmox-qemu.log`. Nếu QEMU vẫn dừng, hãy gửi 40 dòng cuối của file log này cùng kết quả `ls -l /dev/kvm`.

Mặc định `/mnt/a.img` là raw disk `64G`. Có thể đổi dung lượng trước khi chạy:

```bash
sudo PROXMOX_DISK_SIZE=128G ./a.sh
```

Host cần có `/dev/kvm`, quyền đọc/ghi KVM và đủ dung lượng trống. Lần cài đầu tiên boot từ ISO; sau khi cài xong, nếu muốn boot ổ đĩa thay vì ISO, đổi `-boot order=d,menu=on` thành `-boot c` trong `a.sh` hoặc xóa ISO sau khi tắt QEMU.

## Giấy phép

Dự án được phát hành theo [MIT License](LICENSE), bản quyền thuộc về **Hoang Minh (MinhNekYT)**. Người khác được phép sử dụng, sao chép, sửa đổi và phân phối dự án theo các điều kiện của giấy phép MIT.
