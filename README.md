# DockerGHCS

DockerGHCS chạy Windows trong container Docker thông qua [dockur/windows](https://github.com/dockur/windows). Script `a.sh` cài hoặc kiểm tra Docker, chuẩn bị storage, tải Windows ISO và VirtIO driver, sau đó khởi động Docker Compose.

> **Lưu ý quan trọng:** Máy chủ phải có Docker daemon đang hoạt động và thiết bị `/dev/kvm` có quyền đọc/ghi. GitHub Codespaces không phải lúc nào cũng cấp KVM hoặc Docker daemon; nếu thiếu một trong hai điều kiện này, Windows container không thể chạy đúng.

## Cách sử dụng

Tạo Codespace hoặc Ubuntu host có tối thiểu 4 CPU, 16 GB RAM và dung lượng trống phù hợp. Vì cấu hình hiện tại dùng đĩa ảo `400G`, storage cần đủ lớn khi Windows phát sinh dữ liệu; đĩa ảo có thể bắt đầu dưới dạng sparse nhưng không được để filesystem đầy.

### Cài Google Chrome và XFCE4

Nếu chỉ cần cài Google Chrome Stable và môi trường desktop XFCE4 trong Codespace, chạy script độc lập sau:

```bash
wget -O install-chrome-xfce.sh https://raw.githubusercontent.com/MinhNekYT/WindowsGHCS/main/install-chrome-xfce.sh
chmod +x install-chrome-xfce.sh
./install-chrome-xfce.sh
```

Script yêu cầu quyền `sudo`, chỉ hỗ trợ hệ Debian/Ubuntu trên kiến trúc `x86_64`, có thể chạy lại an toàn và không cài display manager. Việc cài package không tự tạo GUI tương tác trong Codespace; để sử dụng desktop cần kết hợp thêm X11, VNC hoặc RDP và expose port phù hợp. Chrome có thể kiểm thử ở chế độ headless bằng `google-chrome --headless=new --no-sandbox --disable-gpu --dump-dom https://example.com`.

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
| Web viewer | Host port `8006` (mở bằng địa chỉ host/forwarded) |
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

Nhập `3` trong menu để chạy Proxmox VE 9.2-1 trực tiếp qua QEMU/KVM. Theo phương án 2, QEMU chuyển tiếp riêng host port `8006` vào guest port `8006`, còn noVNC chạy ở host port `6080`. Script sẽ cài `qemu-system-x86`, `qemu-utils`, `ovmf`, `cpulimit`, `novnc`, `websockify`, `psmisc`, `unzip`, `python3-pip` và `cloudflared`; `psmisc` cung cấp `fuser` để dừng process trên dải cổng; nếu Ubuntu repository có package `qemu-kvm` thì cũng cài thêm; tải ISO chính thức vào `/mnt/proxmox-ve_9.2-1.iso`; kiểm tra SHA256; tạo `/mnt/a.img` nếu chưa có; sau đó khởi động QEMU với 2 vCPU, 8 GB RAM, UEFI OVMF, VNC nội bộ `localhost:5900`, noVNC ở cổng `6080` và Proxmox Web UI qua hostfwd `8006`. NIC dùng `virtio-net-pci` với QEMU user-mode IPv4, DHCP gateway mặc định `10.0.2.2`, DNS proxy `10.0.2.3` và tắt IPv6 để tránh lỗi khi một repository trả về địa chỉ IPv6.

Cấu hình Proxmox dùng hostfwd **chỉ cho cổng 8006** theo phương án 2: host `8006` → guest `8006`. noVNC dùng host port `6080`. Script kiểm tra để hai cổng không trùng nhau và không nằm trong dải VNC `5900–5999`; trước khi khởi động, script kill toàn bộ process đang chiếm TCP/UDP port `5900–5999`, nên chỉ dùng lựa chọn này nếu bạn chấp nhận dừng mọi dịch vụ trong dải cổng đó. QEMU vẫn dùng user-mode networking cho kết nối outbound qua NIC virtio. Sau khi Proxmox installer khởi động, chọn cấu hình mạng DHCP cho interface virtio; kiểm tra gateway bằng `ip route` và kiểm tra DNS bằng `getent hosts download.proxmox.com`.

QEMU được chạy trực tiếp, không bọc bằng `cpulimit`, để PID và mã lỗi được theo dõi chính xác. Audio được tắt bằng `QEMU_AUDIO_DRV=none` và `-audiodev driver=none,id=noaudio`, vì Proxmox không cần PipeWire. Các cảnh báo như `can't load config client.conf` của PipeWire thường không phải nguyên nhân chính. Script đợi VNC `localhost:5900` và noVNC `6080` mở thật sự trước khi báo thành công; log lệnh và lỗi QEMU nằm tại `/tmp/dockerghcs-proxmox-qemu.log`, còn noVNC nằm tại `/tmp/dockerghcs-proxmox-novnc.log`. Nếu Debian truy cập được nhưng `enterprise.proxmox.com` không tải được, kiểm tra DNS, thời gian hệ thống và chứng chỉ TLS trước. Repository enterprise của Proxmox cần subscription hợp lệ; sau khi cài đặt, có thể dùng repository no-subscription phù hợp cho testing/non-production thay vì coi lỗi xác thực enterprise là lỗi mạng. Nếu QEMU vẫn dừng, hãy gửi 80 dòng cuối của hai file log cùng kết quả `ls -l /dev/kvm`.

### Dán text vào Proxmox qua noVNC

noVNC đã có panel **Clipboard** riêng. Để dán text vào Proxmox mà không cần cấp quyền clipboard cho trình duyệt hoặc dùng clipboard hệ điều hành, hãy mở panel **Clipboard**, nhập hoặc dán text vào ô của panel rồi bấm **Send**. Cách này gửi nội dung qua API VNC đến máy ảo; nó không yêu cầu Ctrl+V trực tiếp trên canvas. Chỉ dùng nút **Copy/Send** trong panel khi bạn chủ động muốn truyền hoặc nhận nội dung clipboard.

### Cloudflare Tunnel

Sau khi QEMU và noVNC sẵn sàng, script cài `cloudflared` từ repository chính thức Cloudflare nếu chưa có. Script yêu cầu nhập **Tunnel service token** bằng chế độ ẩn; token không được ghi vào `README.md`, `a.sh` hoặc commit Git. Khi chạy bằng user thường, token không được đưa vào danh sách đối số của `sudo`; script truyền qua file tạm mode `600`, đọc lại một lần ở root rồi xóa file. Có thể truyền token qua biến môi trường `CLOUDFLARE_TUNNEL_TOKEN` để không phải nhập lại trong phiên hiện tại. Nếu muốn script in trực tiếp hostname public sau khi khởi động, truyền thêm `CLOUDFLARE_PROXMOX_HOSTNAME` và `CLOUDFLARE_NOVNC_HOSTNAME`.

```bash
CLOUDFLARE_TUNNEL_TOKEN='YOUR_TUNNEL_TOKEN' \
CLOUDFLARE_PROXMOX_HOSTNAME='proxmox.example.com' \
CLOUDFLARE_NOVNC_HOSTNAME='novnc.example.com' \
./a.sh
```

Script hiển thị public IPv4 của VM cùng direct endpoint `IPv4:6080` cho noVNC và `IPv4:8006` cho Proxmox nếu các cổng đó được forward. Script không dùng `http://localhost` hoặc `http://127.0.0.1` làm địa chỉ để người dùng mở từ máy client. Hai origin nội bộ `127.0.0.1:6080` và `127.0.0.1:8006` chỉ dành cho Cloudflare route. Khi dùng Tunnel, hãy mở hostname Cloudflare đã cấu hình, ví dụ `https://novnc.example.com` hoặc `https://proxmox.example.com`; token chỉ kết nối connector và không tự tạo public hostname.

Trong Cloudflare Dashboard, cấu hình origin noVNC tới `http://127.0.0.1:6080` và origin Proxmox tới `https://127.0.0.1:8006`; với Proxmox dùng chứng chỉ tự ký, bật `noTLSVerify` trong origin request. Đây là địa chỉ origin nội bộ của Tunnel, không phải URL để mở trên máy client.

Mặc định `/mnt/a.img` là raw disk **400G**. Nếu ổ đã tồn tại nhỏ hơn 400G, script sẽ mở rộng ổ; nếu ổ lớn hơn, script giữ nguyên và không thu nhỏ. Có thể đổi dung lượng trước khi chạy:

```bash
sudo PROXMOX_DISK_SIZE=128G ./a.sh
```

Host có `/dev/kvm` với quyền đọc/ghi thì script dùng KVM và CPU model `host`; nếu Codespace không cấp KVM, script tự dùng TCG với CPU model `max`, có thể chậm hơn nhưng không dừng chỉ vì thiếu `/dev/kvm`. Cần đủ dung lượng trống cho ISO và raw disk. Trình tải ISO hỗ trợ cả `curl` và `wget`, sau đó kiểm tra kích thước và SHA256 Proxmox. Lần cài đầu tiên boot từ ISO; sau khi cài xong, nếu muốn boot ổ đĩa thay vì ISO, đổi `-boot order=d,menu=on` thành `-boot c` trong `a.sh` hoặc xóa ISO sau khi tắt QEMU.

## Giấy phép

Dự án được phát hành theo [MIT License](LICENSE), bản quyền thuộc về **Hoang Minh (MinhNekYT)**. Người khác được phép sử dụng, sao chép, sửa đổi và phân phối dự án theo các điều kiện của giấy phép MIT.
