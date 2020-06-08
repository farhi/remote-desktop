# remote-desktop
A remote desktop service that launches virtual machines and display them in your browser

Installation
============

Install required packages. On a Debian-class system:
- sudo apt install python3 python3-pam python3-psutil 
- sudo apt install apache2 libapache2-mod-python
- sudo apt install apache2 libapache2-mod-perl2
- sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq
- sudo apt install libsys-cpu-perl libsys-cpuload-perl libsys-meminfo-perl
- sudo apt install libcgi-pm-perl
- sudo apt install libnet-dns-perl           libproc-background-perl 
- sudo apt install libproc-processtable-perl libemail-valid-perl
- sudo apt install qemu qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils spice-html iptables dnsmasq

Then make sure all is set-up:
- sudo adduser www-data kvm
- sudo chmod 755 /etc/qemu-ifup
- copy the html directory content into /var/www/html. You should now have a 'desktop' item there.
- copy the cgi-bin directory content into /usr/lib/cgi-bin
- sudo chown -R www-data /var/www/html/desktop
- sudo a2enmod cgi

The noVNC (1.1.0) and websockify packages are included within this project.

Customize to your needs
=======================

Edit the `cgi-bin/desktop.pl` file, and its **service configuration** section (at the beginning of the file):
- adapt location of files (esp. directories to `machines`,`snapshots`).
- adapt the default specification of virtual machines (cpu, mem).
- adapt the restrictions for using the service (number of connections, load limit).

Place any ISO, QCOW2, VDI, VMDK virtual machine file in the `html/desktop/machines` 
directory either local in the repo for testing, or in the HTML server e.g. at
`/var/www/html/desktop/machines`.

```bash
ls html/desktop/machines

dsl.iso   machine1.iso ...
```

Then edit the `html/desktop/index.html` web page in the:
- section `<label for="machine">Machine</label>`

and add entries to reflect the VM files in `html/machines`:
```html
<select id="machine" name="machine">
  <option value="dsl.iso">Damn Small Linux</option>
  <option value="machine1.iso">My superb VM</option>
  ...
</select>
```

This package provides a minimal ISO for testing (in `html/desktop/machines`):
- [Damn Small Linux aka DSL](http://www.damnsmalllinux.org/)

DSL does not properly work with modern systems. Expect strange behaviours with 
the mouse and keyboard. Use the `std` video driver or `--qemu_video=std` option, as proposed in the local test below.

Usage: local (for testing)
==========================

It is possible to test that all works by launching a Damn Small Linux distribution.

```bash
cd remote-desktop/src
perl cgi-bin/desktop.pl --dir_service=html/desktop \
  --dir_html=html --dir_snapshots=/tmp --qemu_video=std
```

A text is displayed (HTML format) in the terminal, which indicates a URL.

Connect within a browser to the displayed IP, such as:
- http://localhost:38443/vnc.html?host=localhost&port=38443

for this test (executed as a script), there is no token to secure the VNC, as it is local.

Usage: as a web service
=======================

First make sure the service has been installed in the `html/desktop` root level of the host, and the `cgi-bin/desktop.pl` e.g. in the `/usr/lib/cgi-bin`.

Open a browser and go to the:
- http://localhost/desktop/

Customize your machine and launch it. Follow instructions, enter Token to connect the display. You can of course access the service remotely if the server is on a network.

Connect within a browser to the displayed IP, such as:
- http://localhost:38443/vnc.html?host=localhost&port=38443

and enter the displayed token (to secure the VNC connection), such as:
- 8nrnmcru

Credits
=======
(c) 2020 Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.


