# DockerGHCS

DockerGHCS hỗ trợ ba lựa chọn: **Windows** và **macOS** chạy trong Docker thông qua [dockur/windows](https://github.com/dockur/windows) và [dockurr/macos](https://github.com/dockur/macos), cùng **Proxmox VE** chạy trực tiếp qua QEMU/KVM. Script `a.sh` tự kiểm tra package, storage, Docker hoặc QEMU/KVM rồi khởi động đúng lựa chọn trong menu.

> **Lưu ý quan trọng:** Windows và macOS cần Docker daemon cùng `/dev/kvm`; Proxmox cần QEMU/KVM hoặc TCG fallback, firmware OVMF và đủ storage. GitHub Codespaces không phải lúc nào cũng cấp Docker daemon hoặc KVM, vì vậy khả năng chạy thực tế phụ thuộc vào Codespace/Ubuntu host.

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

| Lựa chọn | Cách chạy | Cổng chính |
|---|---|---|
| Windows | Docker Compose với `ghcr.io/dockur/windows` | Web viewer `8006`, RDP `3389` TCP/UDP |
| macOS | Docker Compose với `dockurr/macos` | Web viewer `8006`, VNC `5900` |
| Proxmox | QEMU/KVM trực tiếp với OVMF và noVNC | noVNC `6080`, hostfwd `8006 → 8006` |

Windows dùng `RAM_SIZE: "half"`, `CPU_CORES: "max"`, `DISK_SIZE: "400G"`, user `windowsghcs`, password `123456`, `/dev/kvm` và `/dev/net/tun`. `a.sh` truyền VirtIO driver vào QEMU bằng `ARGUMENTS` và mount storage/ISO theo đúng đường dẫn mà Compose sử dụng. macOS dùng `VERSION: "15"`, không có `USERNAME` hoặc `PASSWORD`, và không hỏi Windows ISO.

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

Nhập `3` trong menu để chạy Proxmox VE 9.2-1 trực tiếp qua QEMU/KVM. Theo phương án 2, QEMU chuyển tiếp riêng host port `8006` vào guest port `8006`, còn noVNC chạy ở host port `6080`. Script sẽ cài `qemu-system-x86`, `qemu-utils`, `ovmf`, `cpulimit`, `novnc`, `websockify`, `psmisc`, `unzip` và `python3-pip`; `psmisc` cung cấp `fuser` để dừng process trên dải cổng; nếu Ubuntu repository có package `qemu-kvm` thì cũng cài thêm; tải ISO chính thức vào `/mnt/proxmox-ve_9.2-1.iso`; kiểm tra SHA256; tạo `/mnt/a.img` nếu chưa có; sau đó khởi động QEMU với 2 vCPU, 8 GB RAM, UEFI OVMF, VNC nội bộ `localhost:5900`, noVNC ở cổng `6080` và Proxmox Web UI qua hostfwd `8006`. NIC dùng `virtio-net-pci` với QEMU user-mode IPv4, DHCP gateway mặc định `10.0.2.2`, DNS proxy `10.0.2.3` và tắt IPv6 để tránh lỗi khi một repository trả về địa chỉ IPv6.

Cấu hình Proxmox dùng hostfwd **chỉ cho cổng 8006** theo phương án 2: host `8006` → guest `8006`. noVNC dùng host port `6080`. Script kiểm tra để hai cổng không trùng nhau và không nằm trong dải VNC `5900–5999`; trước khi khởi động, script kill toàn bộ process đang chiếm TCP/UDP port `5900–5999`, nên chỉ dùng lựa chọn này nếu bạn chấp nhận dừng mọi dịch vụ trong dải cổng đó. QEMU vẫn dùng user-mode networking cho kết nối outbound qua NIC virtio. Sau khi Proxmox installer khởi động, chọn cấu hình mạng DHCP cho interface virtio; kiểm tra gateway bằng `ip route` và kiểm tra DNS bằng `getent hosts download.proxmox.com`.

QEMU được chạy trực tiếp, không bọc bằng `cpulimit`, để PID và mã lỗi được theo dõi chính xác. Audio được tắt bằng `QEMU_AUDIO_DRV=none` và `-audiodev driver=none,id=noaudio`, vì Proxmox không cần PipeWire. Các cảnh báo như `can't load config client.conf` của PipeWire thường không phải nguyên nhân chính. Script đợi VNC `localhost:5900` và noVNC `6080` mở thật sự trước khi báo thành công; log lệnh và lỗi QEMU nằm tại `/tmp/dockerghcs-proxmox-qemu.log`, còn noVNC nằm tại `/tmp/dockerghcs-proxmox-novnc.log`. Nếu Debian truy cập được nhưng `enterprise.proxmox.com` không tải được, kiểm tra DNS, thời gian hệ thống và chứng chỉ TLS trước. Repository enterprise của Proxmox cần subscription hợp lệ; sau khi cài đặt, có thể dùng repository no-subscription phù hợp cho testing/non-production thay vì coi lỗi xác thực enterprise là lỗi mạng. Nếu QEMU vẫn dừng, hãy gửi 80 dòng cuối của hai file log cùng kết quả `ls -l /dev/kvm`.

### Dán text vào Proxmox qua noVNC

noVNC đã có panel **Clipboard** riêng. Để dán text vào Proxmox mà không cần cấp quyền clipboard cho trình duyệt hoặc dùng clipboard hệ điều hành, hãy mở panel **Clipboard**, nhập hoặc dán text vào ô của panel rồi bấm **Send**. Cách này gửi nội dung qua API VNC đến máy ảo; nó không yêu cầu Ctrl+V trực tiếp trên canvas. Chỉ dùng nút **Copy/Send** trong panel khi bạn chủ động muốn truyền hoặc nhận nội dung clipboard.

### Kết nối Proxmox qua XFCE4

Để chuẩn bị môi trường desktop dùng khi kết nối và thao tác với Proxmox trong Codespace/Ubuntu, tải và chạy `xfce4.sh`:

```bash
wget https://raw.githubusercontent.com/MinhNekYT/WindowsGHCS/main/xfce4.sh
chmod +x xfce4.sh
./xfce4.sh
```

Script `xfce4.sh` cài XFCE4, ưu tiên TigerVNC và dùng TightVNC làm fallback, cùng Google Chrome Stable. Script tạo cấu hình `~/.vnc/xstartup` để khởi động đúng phiên XFCE4 qua D-Bus, nhưng không lưu sẵn VNC password và không tự bật desktop session. Sau khi tải xong mọi thứ, chạy bằng user desktop:

```bash
./xfce4.sh -start
```

Lệnh `-start` sẽ yêu cầu tạo VNC password nếu chưa có, sau đó tự khởi động phiên XFCE4 qua VNC và noVNC. Mặc định phiên là `:1`, tương ứng TCP port `5901`, còn noVNC dùng host port `6080`. Hãy mở cổng `6080` trong Codespaces/Ubuntu host để truy cập noVNC từ máy client.

Lệnh đổi hoặc tạo lại VNC password:

```bash
./xfce4.sh -password
```

Khi `./xfce4.sh -start` đang chạy ở foreground, nhấn **Ctrl+C** để dừng toàn bộ VNC, noVNC và XFCE4. Script không còn dùng các tùy chọn `-stop` hoặc `-status`. Có thể đổi cấu hình bằng `VNC_DISPLAY=:2`, `NOVNC_PORT=6081`, `VNC_GEOMETRY=1920x1080` và `VNC_DEPTH=24` khi chạy script. Proxmox vẫn được khởi động bằng lựa chọn `3` của `a.sh`, với noVNC ở cổng `6080` và Web UI guest `8006` được chuyển tiếp qua host port `8006`.

Mặc định `/mnt/a.img` là raw disk **400G**. Nếu ổ đã tồn tại nhỏ hơn 400G, script sẽ mở rộng ổ; nếu ổ lớn hơn, script giữ nguyên và không thu nhỏ. Có thể đổi dung lượng trước khi chạy:

```bash
sudo PROXMOX_DISK_SIZE=128G ./a.sh
```

Host có `/dev/kvm` với quyền đọc/ghi thì script dùng KVM và CPU model `host`; nếu Codespace không cấp KVM, script tự dùng TCG với CPU model `max`, có thể chậm hơn nhưng không dừng chỉ vì thiếu `/dev/kvm`. Cần đủ dung lượng trống cho ISO và raw disk. Trình tải ISO hỗ trợ cả `curl` và `wget`, sau đó kiểm tra kích thước và SHA256 Proxmox. Kết nối Proxmox dùng port forwarding của Codespace/Ubuntu host và hướng dẫn XFCE4 ở trên. Lần cài đầu tiên boot từ ISO; sau khi cài xong, nếu muốn boot ổ đĩa thay vì ISO, đổi `-boot order=d,menu=on` thành `-boot c` trong `a.sh` hoặc xóa ISO sau khi tắt QEMU.

## Giấy phép

Dự án được phát hành theo [MIT License](LICENSE), bản quyền thuộc về **Hoang Minh (MinhNekYT)**. Người khác được phép sử dụng, sao chép, sửa đổi và phân phối dự án theo các điều kiện của giấy phép MIT.
