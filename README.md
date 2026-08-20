# DockerGHCS

DockerGHCS hỗ trợ ba lựa chọn: **Windows**, **macOS** và **Proxmox VE**, đều chạy trực tiếp bằng **QEMU/KVM**. Windows dùng raw disk; macOS dùng quy trình [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM), recovery image của Apple và OpenCore ISO; Proxmox dùng installer unattended hiện có. Script `a.sh` tự kiểm tra package, storage, QEMU/KVM, OVMF, PulseAudio và noVNC rồi khởi động lựa chọn trong menu.

> **Lưu ý quan trọng:** Windows cần QEMU/KVM hoặc TCG fallback; macOS cần QEMU/KVM thật, CPU phù hợp và không dùng TCG fallback; Proxmox có thể dùng KVM hoặc TCG. Cả ba cần firmware OVMF, đủ storage và host có quyền chạy QEMU. GitHub Codespaces không phải lúc nào cũng cấp `/dev/kvm`, vì vậy macOS có thể không chạy trong Codespace không hỗ trợ nested virtualization.

## Cách sử dụng

Tạo Codespace hoặc Ubuntu host có tối thiểu 4 CPU, 16 GB RAM và dung lượng trống phù hợp. Khi chạy `a.sh`, script hỏi dung lượng đĩa ảo bằng GB và mặc định là `400G`; nhấn Enter để dùng mặc định. Windows và Proxmox tạo raw disk; macOS tạo qcow2 disk `mac_hdd_ng.img`. Các disk có thể sparse nhưng filesystem không được đầy.

Trong thư mục repository, chạy:

```bash
git pull origin main
chmod +x a.sh
./a.sh
```

Script sẽ hỏi xác nhận `y/n`, không phân biệt chữ hoa chữ thường, sau đó hỏi lựa chọn hệ điều hành và dung lượng disk. Với Windows, script hỏi link ISO, tải vào `/mnt/custom.iso`, tải VirtIO driver vào `/mnt/driver.iso` và boot bằng QEMU. Nếu `/mnt/custom.iso` đã tồn tại, script dùng lại file hợp lệ thay vì ghi đè.

## Cài từ repository khác

Bạn có thể chạy script trong một repository khác bằng cách sao chép đoạn lệnh sau:

```bash
wget -O a.sh https://raw.githubusercontent.com/MinhNekYT/DockerGHCS/refs/heads/main/a.sh
chmod +x a.sh
bash a.sh
```

Khi chạy từ repository khác, `a.sh` tự tải các script còn thiếu trong thư mục `automated/` từ DockerGHCS. Vì vậy repository khác chỉ cần tải `a.sh`; không cần chép file YAML. Riêng `xfce4.sh` vẫn có thể chạy độc lập trong Ubuntu/Codespace và tự bỏ qua package đã cài.

Nếu QEMU/KVM, OVMF, PulseAudio và noVNC đã có sẵn, script sẽ bỏ qua package đã cài. Khi chạy lại, script giữ nguyên ISO và disk hiện có, dừng QEMU/noVNC cũ của disk tương ứng rồi chạy lại. Proxmox vẫn dọn mọi process đang giữ **TCP hoặc UDP port từ 5900 đến 5999**. `custom.iso`, `driver.iso`, BaseSystem image, OpenCore ISO và các disk hợp lệ được tái sử dụng; script không ghi đè chúng.

## Cấu hình hiện tại

| Lựa chọn | Cách chạy | Cổng chính |
|---|---|---|
| Windows | QEMU/KVM trực tiếp, raw disk, UEFI OVMF | noVNC `8006`, RDP hostfwd `3389` |
| macOS | QEMU/KVM + osx-kvm + LongQT OpenCore ISO, qcow2 disk | noVNC `8006`, SSH hostfwd `2222` |
| Proxmox | QEMU/KVM trực tiếp với OVMF và noVNC | noVNC `8888`, hostfwd `8006 → 8006` |

Windows QEMU dùng `windows.img` raw, UEFI OVMF, virtio-blk, virtio-net, HDA audio và VirtIO driver ISO. macOS QEMU dùng `mac_hdd_ng.img` qcow2, recovery `BaseSystem.img`, LongQT OpenCore ISO, CPU model tương thích Sequoia 15, HDA audio và user-mode networking. Các cấu hình legacy đã được loại bỏ; `a.sh` chỉ sử dụng runtime QEMU trong `automated/`.

## Nếu gặp lỗi QEMU/KVM

Nếu Windows hoặc Proxmox không khởi động, kiểm tra QEMU, KVM, firmware và log trước khi chạy lại:

```bash
git pull origin main
ls -l /dev/kvm
qemu-system-x86_64 --version
qemu-img --version
sudo tail -n 100 /tmp/dockerghcs-qemu.log
sudo tail -n 100 /tmp/dockerghcs-novnc.log
```

Nếu macOS báo thiếu KVM, hãy chạy trên host có nested virtualization thật sự. Script macOS sẽ tải `kvm_amd.conf` cho AMD hoặc `kvm.conf` cho Intel vào `/etc/modprobe.d/kvm.conf`, chạy `modprobe`, rồi thêm user vào các group `kvm`, `libvirt` và `input`. Cần đăng nhập lại hoặc khởi động shell mới để group membership có hiệu lực; script vẫn chạy QEMU bằng root sau bước privilege elevation nên không phụ thuộc vào shell hiện tại.

Log của macOS và Windows nằm tại `/tmp/dockerghcs-qemu.log`; log noVNC tại `/tmp/dockerghcs-novnc.log`; log PulseAudio tại `/tmp/dockerghcs-pulseaudio.log`. Nếu QEMU dừng ngay, gửi 80 dòng cuối của log cùng kết quả `ls -l /dev/kvm`.

## Chọn Windows, macOS hoặc Proxmox

Khi chạy `a.sh`, script hiển thị menu:

```text
1) Windows
2) macOS
3) Proxmox (QEMU/KVM)
```

Nhập `1` để cài Windows bằng `automated/windows-qemu.sh`. Script hỏi link ISO nếu `/mnt/custom.iso` chưa tồn tại, tải VirtIO driver ISO, tạo `/mnt/windows.img` dạng raw và khởi động Windows bằng QEMU/OVMF. Nhập `2` để cài macOS Sequoia 15 bằng `automated/macos-qemu.sh`; script tự tải tool `kholia/OSX-KVM`, chạy `fetch-macOS-v2.py --shortname sequoia`, chuyển `BaseSystem.dmg` thành `BaseSystem.img`, tải LongQT OpenCore ISO và tạo `/mnt/mac_hdd_ng.img` dạng qcow2.

MacOS QEMU cần `/dev/kvm` thật sự và CPU có AVX2; script không giả vờ chạy bằng TCG khi KVM thiếu. Script tự chọn `kvm_amd.conf` cho AMD hoặc `kvm.conf` cho Intel, chép vào `/etc/modprobe.d/kvm.conf`, chạy `modprobe`, rồi thêm user vào group `kvm`, `libvirt` và `input`. Lần cài đầu, mở noVNC `8006`, chọn OpenCore và `BaseSystem`, mở Disk Utility, format disk APFS rồi cài macOS. OpenCore ISO phải được gắn như CD/DVD, không phải hard disk [1] [2].

Theo tài liệu upstream, macOS virtualization có yêu cầu phần cứng, giới hạn hiệu năng/đồ họa và vấn đề pháp lý riêng. Chỉ sử dụng macOS khi bạn có quyền và giấy phép phù hợp với phần cứng và Apple EULA.

## Proxmox qua QEMU/KVM

Nhập `3` trong menu để chạy Proxmox VE 9.2-1 trực tiếp qua QEMU/KVM. Theo mặc định, `a.sh` dùng Proxmox Automated Installation: script tạo answer file, tự cài `proxmox-auto-install-assistant`, chuẩn bị một ISO unattended và khởi động ISO đó bằng QEMU. Cấu hình mặc định là country code `vn` (Vietnam), FQDN `pve.local`, timezone `Asia/Ho_Chi_Minh`, network DHCP và filesystem ext4 trên disk guest `sda`. Script sẽ hỏi mật khẩu root Proxmox bằng prompt ẩn; mật khẩu không được ghi vào repository. First-boot hook tự đặt hostname/FQDN, tắt repository enterprise và bật `pve-no-subscription` cho Trixie.

Theo phương án 2, QEMU chuyển tiếp riêng host port `8006` vào guest port `8006`, còn noVNC chạy ở host port `8888`. Script sẽ cài `qemu-system-x86`, `qemu-system-gui`, `qemu-utils`, `ovmf`, `cpulimit`, `novnc`, `websockify`, `psmisc`, `pulseaudio`, `pulseaudio-utils`, `unzip`, `python3-pip`, `xorriso` và assistant package; tải ISO chính thức vào `/mnt/proxmox-ve_9.2-1.iso`; kiểm tra SHA256; tạo `/mnt/a.img` nếu chưa có; sau đó khởi động QEMU với 2 vCPU, 8 GB RAM, UEFI OVMF, VNC nội bộ `localhost:5900`, noVNC ở cổng `8888` và Proxmox Web UI qua hostfwd `8006`. NIC dùng `virtio-net-pci` với QEMU user-mode IPv4, DHCP gateway mặc định `10.0.2.2`, DNS proxy `10.0.2.3` và tắt IPv6.

Nếu muốn dùng installer thủ công thay vì unattended:

```bash
PROXMOX_AUTO_INSTALL=0 ./a.sh
```

Có thể đổi FQDN, country hoặc timezone trước khi chạy; country phải là mã quốc gia hai chữ cái:

```bash
PROXMOX_FQDN=pve.local PROXMOX_COUNTRY=vn \
PROXMOX_TIMEZONE=Asia/Ho_Chi_Minh ./a.sh
```

Script lưu metadata riêng cho auto ISO, chỉ tái sử dụng ISO khi FQDN, country, timezone và password hash khớp. Nếu `/mnt/a.img` đã có partition table, script hiểu rằng Proxmox đã được cài và boot disk hiện tại thay vì chạy installer lần nữa. Muốn cài lại từ đầu, hãy dừng QEMU rồi xóa riêng `/mnt/a.img`, `/mnt/proxmox-ve_9.2-1-auto.iso`, `/mnt/dockerghcs-proxmox-auto.meta`, `/mnt/dockerghcs-proxmox-answer.toml` và `/mnt/dockerghcs-proxmox-first-boot.sh`; không xóa ISO gốc nếu muốn tải lại nhanh hơn.

Cấu hình Proxmox dùng hostfwd **chỉ cho cổng 8006** theo phương án 2: host `8006` → guest `8006`. noVNC dùng host port `8888`. Script kiểm tra để hai cổng không trùng nhau và không nằm trong dải VNC `5900–5999`; trước khi khởi động, script kill toàn bộ process đang chiếm TCP/UDP port `5900–5999`, nên chỉ dùng lựa chọn này nếu bạn chấp nhận dừng mọi dịch vụ trong dải cổng đó. QEMU vẫn dùng user-mode networking cho kết nối outbound qua NIC virtio. Sau khi Proxmox installer khởi động, chọn cấu hình mạng DHCP cho interface virtio; kiểm tra gateway bằng `ip route` và kiểm tra DNS bằng `getent hosts download.proxmox.com`.

QEMU được chạy trực tiếp, không bọc bằng `cpulimit`, để PID và mã lỗi được theo dõi chính xác. Script khởi động PulseAudio system mode tại `/run/pulse/native`, rồi gắn sound card ảo `ich9-intel-hda`/`hda-duplex` vào QEMU bằng backend `pa`. Các cảnh báo như `can't load config client.conf` của PipeWire không còn là dependency của luồng này. noVNC chuẩn là client RFB nên truyền hình ảnh, bàn phím, chuột và clipboard; RFB/noVNC không tự mang một kênh audio riêng. PulseAudio vẫn cung cấp backend âm thanh cho QEMU và các client audio tương thích. Script đợi VNC `localhost:5900` và noVNC `8888` mở thật sự trước khi báo thành công; log lệnh và lỗi QEMU nằm tại `/tmp/dockerghcs-proxmox-qemu.log`, còn noVNC nằm tại `/tmp/dockerghcs-proxmox-novnc.log`. Nếu QEMU vẫn dừng, hãy gửi 80 dòng cuối của hai file log cùng kết quả `ls -l /dev/kvm`.

### Sửa lỗi `401 Unauthorized` của Proxmox repository

Nếu trong Proxmox xuất hiện `401 Unauthorized` từ `enterprise.proxmox.com`, mạng của VM đã hoạt động; lỗi là do repository `pve-enterprise` yêu cầu subscription. Ảnh lỗi có cả `ceph-squid` và `pve`, vì vậy cần tắt các repository enterprise nếu máy không có subscription. Proxmox mô tả repository no-subscription là lựa chọn không yêu cầu subscription, phù hợp cho testing/non-production [tài liệu repository chính thức](https://pve.proxmox.com/wiki/Package_Repositories).

Đối với Proxmox VE 9 trên Debian Trixie, chạy trong terminal Proxmox bằng `root`:

```bash
# Tắt repository enterprise của PVE nếu tồn tại.
for f in /etc/apt/sources.list.d/pve-enterprise.sources \
         /etc/apt/sources.list.d/pve-enterprise.list; do
  if [ -f "$f" ]; then
    mv "$f" "$f.disabled"
  fi
done

# Nếu chưa dùng Ceph, tắt Ceph enterprise để apt update không còn báo 401.
if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
  mv /etc/apt/sources.list.d/ceph.sources \
     /etc/apt/sources.list.d/ceph.sources.disabled
fi

# Bật repository Proxmox no-subscription chính thức cho Trixie.
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt-get update
```

Nếu cần Ceph, không tắt toàn bộ `ceph.sources` một cách mù quáng; hãy cấu hình repository Ceph no-subscription tương ứng với phiên bản Ceph đang dùng. Không bật đồng thời enterprise và no-subscription cho cùng một sản phẩm nếu không hiểu rõ pinning/repository priority. Repository no-subscription phù hợp cho lab và testing, không phải lựa chọn được Proxmox khuyến nghị cho production.

### Dán text vào Proxmox qua noVNC

noVNC đã có panel **Clipboard** riêng. Để dán text vào Proxmox mà không cần cấp quyền clipboard cho trình duyệt hoặc dùng clipboard hệ điều hành, hãy mở panel **Clipboard**, nhập hoặc dán text vào ô của panel rồi bấm **Send**. Cách này gửi nội dung qua API VNC đến máy ảo; nó không yêu cầu Ctrl+V trực tiếp trên canvas. Chỉ dùng nút **Copy/Send** trong panel khi bạn chủ động muốn truyền hoặc nhận nội dung clipboard.

### Kết nối Proxmox qua XFCE4

Để chuẩn bị môi trường desktop dùng khi kết nối và thao tác với Proxmox trong Codespace/Ubuntu, tải và chạy `xfce4.sh`:

```bash
wget https://raw.githubusercontent.com/MinhNekYT/WindowsGHCS/main/xfce4.sh
chmod +x xfce4.sh
./xfce4.sh
```

Thư mục `automated/` chứa `common.sh`, `windows-qemu.sh`, `macos-qemu.sh` và `proxmox-qemu.sh`. Ba script dùng chung QEMU/OVMF/PulseAudio/noVNC helper; Windows tạo raw disk, macOS tạo qcow2 disk và Proxmox gọi luồng unattended ổn định trong `a.sh`.

Script `xfce4.sh` cài XFCE4, ưu tiên TigerVNC và dùng TightVNC làm fallback, cùng Google Chrome Stable và PulseAudio (`pulseaudio`, `pulseaudio-utils`, `alsa-utils`). Script tạo cấu hình `~/.vnc/xstartup` để khởi động đúng phiên XFCE4 qua D-Bus và đặt `PULSE_SERVER` tới socket PulseAudio riêng của phiên desktop. Khi chạy không có tham số, script sẽ cài các package còn thiếu rồi tự động khởi động VNC, noVNC và XFCE4; những lần chạy sau sẽ bỏ qua package đã có và chạy ngay.

```bash
./xfce4.sh
```

Nếu chưa có VNC password, script sẽ yêu cầu tạo password ẩn bên trong lần khởi động đầu tiên. Mặc định phiên là `:1`, tương ứng TCP port `5901`, còn noVNC của XFCE4 dùng host port `6080`. PulseAudio chạy trong phiên user tại `~/.vnc/pulse/native`. Tuy nhiên, noVNC chuẩn chỉ chuyển RFB và không stream audio trực tiếp; muốn nghe âm thanh từ máy ảo/container qua trình duyệt, dùng web viewer có hỗ trợ audio của dockur và bật **Settings → Advanced → Audio**. Hãy mở cổng `6080` trong Codespaces/Ubuntu host để truy cập noVNC từ máy client.

Lệnh `./xfce4.sh -start` vẫn được giữ như alias tương thích, nhưng không cần dùng. Script chạy ở foreground; nhấn **Ctrl+C** để dừng toàn bộ VNC, noVNC và XFCE4. Không có lệnh quản lý riêng cho password, stop hoặc status. Có thể đổi cấu hình bằng `VNC_DISPLAY=:2`, `NOVNC_PORT=6081`, `VNC_GEOMETRY=1920x1080` và `VNC_DEPTH=24` khi chạy script. Proxmox vẫn được khởi động bằng lựa chọn `3` của `a.sh`, với noVNC riêng ở cổng `8888` và Web UI guest `8006` được chuyển tiếp qua host port `8006`.

Các file `windows.yaml` và `macos.yaml` legacy đã được loại bỏ để tránh giữ password hoặc cấu hình Docker không còn dùng. Toàn bộ Windows/macOS runtime đi qua QEMU trong `automated/`. Audio của các VM QEMU đi qua PulseAudio backend và thiết bị HDA ảo. noVNC chuẩn vẫn chỉ truyền RFB, nên âm thanh trong trình duyệt phụ thuộc vào client/web viewer có hỗ trợ audio riêng.

Nếu Google Chrome crash trong VNC, hãy mở Chrome bằng launcher đã cấu hình:

```bash
google-chrome-xfce
```

Launcher dùng X11, profile riêng, `--disable-dev-shm-usage`, SwiftShader và GPU compositing tắt. Nếu Chrome thoát bất thường, launcher tự thử lại một lần với `--no-sandbox`/`--disable-setuid-sandbox`, nhưng vẫn từ chối chạy Chrome bằng root. Không nên chạy trực tiếp `sudo google-chrome`; hãy chạy dưới user desktop trong phiên XFCE4.

Mặc định `/mnt/a.img` là raw disk **400G**. Nếu ổ đã tồn tại nhỏ hơn 400G, script sẽ mở rộng ổ; nếu ổ lớn hơn, script giữ nguyên và không thu nhỏ. Có thể đổi dung lượng trước khi chạy:

```bash
sudo PROXMOX_DISK_SIZE=128G ./a.sh
```

Host có `/dev/kvm` với quyền đọc/ghi thì Windows/Proxmox dùng KVM; nếu Codespace không cấp KVM, Windows/Proxmox có thể dùng TCG chậm hơn. macOS không dùng TCG fallback và sẽ dừng với thông báo cần KVM. Cần đủ dung lượng trống cho ISO và disk. Trình tải ISO hỗ trợ `curl`, sau đó kiểm tra kích thước file; Proxmox còn kiểm tra SHA256. Kết nối VM dùng port forwarding của Codespace/Ubuntu host và hướng dẫn XFCE4 ở trên. Lần cài đầu của Windows/Proxmox boot từ ISO; sau khi đã tạo partition table, script tự boot disk. macOS giữ OpenCore ISO làm CD/DVD boot media theo hướng dẫn upstream.

### References

[1]: https://github.com/kholia/OSX-KVM — OSX-KVM: fetch macOS recovery media, convert `BaseSystem.dmg` and boot macOS with QEMU/KVM.

[2]: https://github.com/LongQT-sea/OpenCore-ISO — OpenCore ISO for QEMU/KVM; the ISO must be attached as a CD/DVD drive.

## Giấy phép

Dự án được phát hành theo [MIT License](LICENSE), bản quyền thuộc về **Hoang Minh (MinhNekYT)**. Người khác được phép sử dụng, sao chép, sửa đổi và phân phối dự án theo các điều kiện của giấy phép MIT.
