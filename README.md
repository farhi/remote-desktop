# remote-desktop
A remote desktop service that launches virtual machines and displays them in your browser.

##### Table of Contents
- [What is provided by this service](#what-is-provided-by-this-service)
- [Installation](#installation)
- [Installation with GPU](#installation-gpu-passthrough)
- [Configuration](#customize-to-your-needs)
- [Usage](#usage-local-for-testing)
- [How it works](#how-it-works)

## What is provided by this service

The service allows authorized users to launch a remote virtual machine, and display it in a browser window. No additional software installation is needed on the client side. This project has been developed on a Debian-class system, and is thus suited for it.

Once installed (see below), connect to:
- http://server/desktop

Basically a user can enter some login/password or email, then specify what resources are needed (cpu, memory). It is also possible to select the type of machine (system), and if the machine is accessed only once, or can be accessed many times. After accepting the Terms and Conditions, the user can click on "Create".

<br>
<img src="src/html/desktop/images/machine-specs.png">
<br>

The user credentials can be tested against IMAP, SMTP, and LDAP. In this case, a user ID (login name) and password are required. Authentication can also be achieved using an email sent with connection information.

When authentication is successful, a virtual machine is launched and can be displayed in the browser window. In most cases (this depends on the configuration - see below), a unique "token" is requested to secure the connection.

<br>
<img src="src/html/desktop/images/create.png">
<br>

Just enter the given token, and you will access the virtual machine remote desktop. Use full screen, adapt screen resolution and keyboard layout, and you'll be good to go !

<br>
<img src="src/html/desktop/images/display.png">
<br>

Features
--------
- Supports authentication using SMTP, IMAP, LDAP and email. See "customize" section below.
- Checks the server load to avoid DoS. See "customize" section below.
- Handles both single-shot login, and re-entrant (persistent) connections.
- Persistent connections allow to close the browser and re-connect later while the session is still running. The connection information can also be shared to allow multiple users to collaborate. :warning: Beware: all users will have mouse/keyboard control, so that friendly collaboration rules must be set in place.
- Single-shot connections only allow one single connection. Any browser closing or virtual machine shutdown will imply to loose the virtual machine. However, this mode is lighter to handle for the server, and can be suited for e.g. tutorials and demo.
- No need to install anything on the client side.
- The rendering of the web service is responsive design. It adapts to the browser window size.
- Can monitor running sessions.
- Can mount host volumes.
- Can optionally assign physical GPU to sessions (see below).

## Installation

Install required packages. On a Debian-class system:
```bash
sudo apt install apache2 libapache2-mod-perl2
sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq
sudo apt install libcgi-pm-perl liblist-moreutils-perl libsys-cpu-perl libsys-cpuload-perl libsys-meminfo-perl libnet-dns-perl libproc-background-perl  libproc-processtable-perl libemail-valid-perl libnet-smtps-perl libmail-imapclient-perl libnet-ldap-perl libemail-valid-perl libjson-perl
```

Then make sure all is set-up:
```bash
sudo adduser www-data kvm
sudo adduser www-data libvirt
sudo adduser www-data libvirt-qemu
sudo chmod 755 /etc/qemu-ifup
```

- copy the html directory content into e.g. `/var/www/html` (Apache2 / Debian). You should now have a 'desktop' item there.
- copy the cgi-bin directory content into e.g. `/usr/lib/cgi-bin` (Apache2 / Debian).

The `cgi-bin` section of the Apache configuration file e.g. in `/etc/apache2/conf-available/serve-cgi-bin.conf` should be tuned as follows:
```
<Directory "/usr/lib/cgi-bin">
  ...
  SetHandler perl-script
  PerlResponseHandler ModPerl::Registry
  PerlOptions +ParseHeaders
</Directory> 
```

and finally:
```bash
sudo chown -R www-data /var/www/html/desktop
sudo find /var/www/html -type f -exec chmod a+r {} +
sudo find /var/www/html -type d -exec chmod a+rx {} +
sudo chmod 755 /usr/lib/cgi-bin/desktop.pl
sudo a2enmod cgi
sudo service apache2 restart
```

The noVNC (1.1.0) and websockify packages are included within this project.

The installation steps for GPU pass-through are described at the end of this documentation.

## Customize to your needs

Edit the `cgi-bin/desktop.pl` file, and its **service configuration** section (at the beginning of the file):
- adapt location of files (esp. directories to `machines`,`snapshots`).
- adapt the default specification of virtual machines (cpu, mem).
- adapt the restrictions for using the service (number of connections, load limit).
- adapt the user credential tests you wish to use. They are all tested one after the other, until one works.

Most options below can be changed in the script, or overridden with command line argument `--name=value`.

### Location of files and directories

These settings should be kept to their default for an Apache web server.

| Locations | Default | Description |
|------------------|---------|-------------|
| `dir_html` | /var/www/html   | HTML server root |
| `dir_service`  | /var/www/html/desktop     | Location of service |
| `dir_machines` | /var/www/html/desktop/machines | Full path to machines (ISO,VM) |
| `dir_snapshots` | /var/www/html/desktop/snapshots | Where snapshot are stored |
| `dir_cfg` | /tmp | Temporary files (JSON for sessions) |
| `dir_novnc` | /var/www/html/desktop/novnc | Location of noVNC and websockify |
| `dir_mounts` | (/mnt,/media) | Volumes from host to mount in guests. Use e.g. `mount -t 9p -o trans=virtio,access=client host_media /mnt/media` in guest. |

### Server load settings

| Important options | Default | Description |
|------------------|---------|-------------|
| `snapshot_lifetime` | 86400   | Time in seconds above which sessions are stopped |
| `service_max_load`  | 0.8     | Maximal load of the machine, in 0-1 where 1 means all CPU's are used |
| `service_max_instance_nb` | 10 | Maximum number of simultaneous sessions |
| `service_allow_persistent` | 1 | You can disable persistent sessions, which use more resources |
| `service_use_vnc_token` | 1 | You can disable VNC connection security here: no Token, direct access to the remote desktop |
| `service_min_port` | 6000 | When 0, a random port in 0-65535 is found. When positive, a random port in [`service_min_port service_min_port+service_max_instance_nb`] is found. Recommended value is 6000. This option should be set if you plan to broadcast the service. Then it is better to restrict the port range. |

### User credential settings

It is possible to activate more than one authentication mechanism, which are tested until one works. The details of the SMTP, IMAP and LDAP server settings are to tune in the CGI script.

| User authentication | Default | Description |
|------------------|---------|-------------|
| `check_user_with_email` | 0 | When set and user ID is an email, a message with the connection token is sent as authentication |
| `check_user_with_imap` | 0 | When set, the user ID/password is checked against specified IMAP server |
| `check_user_with_smtp` | 0 | When set, the user ID/password is checked against specified SMTP server |
| `check_user_with_ldap` | 0 | When set, the user ID/password is checked against specified LDAP server |

:warning: The SSL encryption level of the IMAP server (for user credentials) should match that of the server running the remote desktop service. 
The current Debian rules are to use SSL v1.2 or v1.3. In case the user IMAP authentication brings errors such as:
```
IMAP error "Unable to connect to <server>: SSL connect attempt failed error:1425F102:SSL routines:ssl_choose_client_version:unsupported protocol."
```
which appears in the Apache2 error log (`/var/log/apache2/error.log`), then you may [downgrade the SSL encryption](https://stackoverflow.com/questions/53058362/openssl-v1-1-1-ssl-choose-client-version-unsupported-protocol) requirement in the file `/etc/ssl/openssl.cnf` in a section such as:
```
[system_default_sect]
MinProtocol = TLSv1
CipherString = DEFAULT@SECLEVEL=1
```

### Creating virtual machines

It is possible to create a VM from an ISO, just like you would boot physically. An empty disk is first created (here with size 10GB).
```bash
qemu-img create -f qcow2 machine1.qcow2 10G
```
Then you should boot from an ISO file (here indicated as `file.iso`)
```bash
qemu-system-x86_64  -m 4096 -smp 4 -hda machine1.qcow2 -name MySuperbVM -boot d -cdrom file.iso -enable-kvm -cpu host -vga qxl -net user -net nic,model=ne2k_pci
```
and install the system on the prepared disk. 

You may also convert an existing VDI/VMDK file (VirtualBox and VMWare formats - here `file.vmdk`) into QCOW2 for QEMU (here machine1.qcow2`) with command:
```bash
qemu-img convert -f vmdk -O qcow2 file.vmdk machine1.qcow2
```

Last, you may dump an existing physical disk (with a functional system - here from device `dev/sda`) into a QCOW2 format:
```bash
qemu-img convert -o qcow2 /dev/sda machine1.qcow2
```

The QCOW2 format allows to resize disks, for instance with:
```bash
qemu-img resize machine1.qcow2 +50G
```

### Adding virtual machines

Place any ISO, QCOW2, VDI, VMDK, RAW virtual machine file in the `html/desktop/machines` 
directory either local in the repo for testing, or in the HTML server e.g. at
`/var/www/html/desktop/machines`.

```bash
ls html/desktop/machines

dsl.iso    slax.iso    machine1.iso ...
```

Then edit the `html/desktop/index.html` web page in the:
- section `<label for="machine">Machine</label>`

and add entries to reflect the VM files in `html/machines`:
```html
<select id="machine" name="machine">
  <option value="slax.iso">Slax (Debian)</option>
  <option value="dsl.iso">Damn Small Linux</option>
  ...
  <option value="machine1.iso">My superb VM</option>
  ...
</select>
```
You can also remove unnecessary sections (e.g. video driver, GPU) at will. Defaults will then be used.

:+1: This project provides minimal ISO's for testing (in `html/desktop/machines`):
- [Slax](https://www.slax.org/) a modern, yet very compact Debian system (265 MB)
- [DSL](http://www.damnsmalllinux.org/) a very compact, old-style Linux (50 MB)

There exist some virtual machine repositories, for instance:
- https://marketplace.opennebula.systems/appliance
- https://github.com/palmercluff/qemu-images
- https://www.osboxes.org

## Usage: local (for testing)

It is possible to test that all works by launching a Slax distribution.

```bash
cd remote-desktop/src
perl cgi-bin/desktop.pl --dir_service=html/desktop \
  --dir_html=html --dir_snapshots=/tmp --qemu_video=std \
  --dir_machines=html/desktop/machines/ --dir_novnc=$PWD/html/desktop/novnc/
```

A text is displayed (HTML format) in the terminal, which indicates a URL.

Connect with a web browser to the displayed URL, such as:
- http://localhost:38443/vnc.html?host=localhost&port=38443

for this test (executed as a script), there is no token to secure the VNC, as it is local.

The `desktop.pl` script can be used as a command with additional arguments. The
full list of supported options is obtained with:
```bash
desktop.pl --help
```

You can additionally monitor a running process with:
```bash
desktop.pl --session_watch=/path/to/json
```

You can force a session to stop with:
```bash
desktop.pl --session_stop=/path/to/json
```

And you can stop and clear all sessions with:
```bash
desktop.pl --session_purge=1
```

Last, you can monitor all running sessions, with:
```bash
desktop.pl --service_monitor=1 > /tmp/mon.html
firefox /tmp/mon.html
```
which generates an HTML and renders it in a browser.

:warning: For all the above commands, make sure you have to permissions to access the `dir_snapshots` and `dir_cfg` directories. You can specify these with:
```bash
desktop.pl  ... --dir_snapshots=/tmp --dir_cfg=/tmp
```

## Usage: as a web service

First make sure the service has been installed in the `html/desktop` root level of the host, and the `cgi-bin/desktop.pl` e.g. in the `/usr/lib/cgi-bin`.

Open a browser and go to the:
- http://localhost/desktop/

Customize your machine and launch it. Follow instructions, enter Token to connect the display. You can of course access the service remotely if the server is on a network.

Connect within a browser to the displayed IP, such as:
- http://localhost:38443/vnc.html?host=localhost&port=38443

and enter the displayed token (to secure the VNC connection), such as:
- 8nrnmcru

When used as as web service, any authenticated user listed in the `user_admin` (in `desktop.pl` configuration section) will also be able to start the `[ADMIN]` entries to e.g. monitor the service (status, and lists all running sessions), and purge (kill) all running sessions (which also cleans-up all temporary files).

## Installation: GPU pass-through

It is possible, as an experimental feature, to use a physical GPU into virtual machine sessions. 

:warning: This GPU is exclusively attached to the virtual machine, and can not anymore be used on the server for display. This implies that you should have at least two distinct GPU's (of different model).

In the following, we have assume we have a server with an AMD CPU, and NVIDIA GPU's, all running on a Debian 10 "buster" system. The first step is to ensure that your server can detach a GPU from the host system. The feature which is used is called IOMMU/VFIO.
```
$ sudo dmesg | grep "AMD-Vi\|Intel VT-d"
[    1.059323] AMD-Vi: IOMMU performance counters supported
$ lscpu | grep -i "Virtualisation"
Virtualisation :                        AMD-V
$ egrep -q '^flags.*(svm|vmx)' /proc/cpuinfo && echo virtualization extensions available
virtualization extensions available
$ lspci -nnv | grep "VGA\|Audio\|Kernel driver in use: snd_hda_intel\|Kernel driver in use: nouveau\|Kernel driver in use: nvidia\|Kernel driver in use: nouveaufb\|Kernel driver in use: radeon"
4c:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP108 [10de:1d01] (rev a1) (prog-if 00 [VGA controller])
    Kernel driver in use: nvidia
4c:00.1 Audio device [0403]: NVIDIA Corporation GP108 High Definition Audio Controller [10de:0fb8] (rev a1)
    Subsystem: ASUSTeK Computer Inc. GP108 High Definition Audio Controller [1043:8746]
    Kernel driver in use: snd_hda_intel
4d:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP108 [10de:1d01] (rev a1) (prog-if 00 [VGA controller])
    Kernel driver in use: nvidia
4d:00.1 Audio device [0403]: NVIDIA Corporation GP108 High Definition Audio Controller [10de:0fb8] (rev a1)
    Subsystem: ASUSTeK Computer Inc. GP108 High Definition Audio Controller [1043:8621]
    Kernel driver in use: snd_hda_intel
```
which results in a list of available GPU. In the following, we assume we have two low-cost/power NVIDIA GT 1030 (384 cores, 2 GB memory) cards, on PCI addresses `4c:00` and `4d:00`. It is important to also take note of the hardware vendor:model code for the GPU, here `10de:1d01`.

In the following step, we detach these GT 1030 cards at boot. In the `/etc/default/grub` file activate IOMMU, and flag the vendor:model codes (here with video and sound parts - multiple cards are possible separated with comas):
```
GRUB_CMDLINE_LINUX_DEFAULT = "quiet amd_iommu=on iommu=pt vfio-pci.ids=10de:1d01,10de:0fb8"
```
This information should also be added as a `modprobe` option. Create for instance the file `/etc/modprobe.d/vfio.conf` with content:
```bash
# /etc/modprobe.d/vfio.conf
options vfio-pci ids=10de:1d01,10de:0fb8 disable_vga=1
```
and push necessary modules into the kernel by adding:
```
# /etc/initramfs-tools/modules
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
vhost-netdev
```
into file `/etc/initramfs-tools/modules`.

Finally reconfigure the boot and linux kernel, and restart the server:
```bash
sudo update-initramfs -u
sudo update-grub
sudo reboot
```
After reboot, the command `lspci -nnk` will show the detached cards as used by the `vfio-pci` kernel driver.

:warning: all identical GPU of that model (`10de:1d01`) are detached. It is not possible to keep one on the server, and send the other same model to the VM. This is why at least two different GPU models are physically needed in the computer.

It is now necessary to configure the system so that the Apache user can launch qemu with IOMMU/VFIO pass-through. Else you get errors such as:

`VFIO: ... permission denied`

Change VFIO access rules so that group `kvm` can use it. Add in file `/etc/udev/rules.d/10-qemu-hw-users.rules`:
```
# /etc/udev/rules.d/10-qemu-hw-users.rules
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm"
```
then restart `udev`
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

You may experience in the Apache error.log messages like:
```
qemu-system-x86_64: -device vfio-pci,host=0000:4c:00.0,multifunction=on: VFIO_MAP_DMA: -12
qemu-system-x86_64: -device vfio-pci,host=0000:4c:00.0,multifunction=on: vfio_dma_map(0x55966269d230, 0x100000, 0xbff00000, 0x7f55b7f00000) = -12 (Cannot allocate memory)
```
as well as:
```
vfio_pin_pages_remote: RLIMIT_MEMLOCK (65536) exceeded
```
is `dmesg` which is triggered by a low memory allocation threashold `ulimit`.

Adapt the memory pre-allocation for the GPU. This is done in `/etc/security/limits.conf` by adding lines at the end:
```
# /etc/security/limits.conf
*    soft memlock 20000000
*    hard memlock 20000000
@kvm soft memlock unlimited
@kvm hard memlock unlimited
```
The value is given in Kb, here 20 GB for all users, and unlimited for group `kvm`. Perhaps this 20 GB value should match the internal GPU memory.

Do something similar when Apache starts with SystemD e.g. in `/etc/systemd/system/multi-user.target.wants/apache2.service`
```
# /etc/systemd/system/multi-user.target.wants/apache2.service
[Service]
...
LimitMEMLOCK=infinity
```

## How it works

A static HTML page with an attached style sheet (handling responsive design), calls a perl CGI on the Apache server. This CGI creates a snapshot of the selected virtual machine (so that local changes by the user do not affect the master VM files). A `qemu` command line is assembled, typically (here 4 SMP cores and 8 GB memory):
```bash
qemu-system-x86_64  -m 8192 -smp 4 -hda machine1-snapshot.qcow2 -device ich9-ahci,id=ahci -enable-kvm -cpu host -vga qxl -netdev user,id=mynet0 -device virtio-net,netdev=mynet0 -device virtio-balloon
```
The integrated QEMU VNC server is also launched, so that we can access the VM display. As indicated, we also use the `virtio-balloon` device, which allows to share the unused memory when multiple VM's are launched. When IOMMU/VFIO GPU are available, their PCI slot is passed to QEMU with the `virtio-pci` option.

A websocket is attached to the QEMU VNC, and redirected to a noVNC port, so that we can display the VM screen in a browser.

A monitoring page is also handled by the CGI script, to display the server load and running sessions. These can be killed one-by-one, or all at once.

The perl CGI script that does all the job fits in only 1500 lines.

## Credits

(c) 2020 Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.

    https://gitlab.com/soleil-data-treatment/remote-desktop

We have benefited from the following web resources.

#### Debian/Ubuntu documentation

- https://doc.ubuntu-fr.org/vfio (in French)
- https://alpha.lordran.net/posts/2018/05/12/vfio/ (in French)
- https://passthroughpo.st/gpu-debian/
- https://wiki.debian.org/VGAPassthrough
- https://davidyat.es/2016/09/08/gpu-passthrough/
- https://heiko-sieger.info/low-end-kvm-virtual-machine/

#### Other documentation

- https://mathiashueber.com/windows-virtual-machine-gpu-passthrough-ubuntu/
- https://wiki.archlinux.org/index.php/PCI_passthrough_via_OVMF
- https://neg-serg.github.io/2017/06/pci-pass/ (ARCH linux)
- https://wiki.gentoo.org/wiki/GPU_passthrough_with_libvirt_qemu_kvm (Gentoo)
- https://medium.com/@calerogers/gpu-virtualization-with-kvm-qemu-63ca98a6a172

### VirtualBox documentation

- https://docs.oracle.com/en/virtualization/virtualbox/6.0/admin/pcipassthrough.html


