# remote-desktop
A remote desktop service that launches virtual machines and display them in your browser

Installation
============

- sudo apt install python3 python3-pam python3-psutil

The noVNC (1.1.0) and websockify packages are included within this project.

Usage: local (for testing)
==========================

```python
python3 src/cgi-bin/cloud_vm.py         \
  --service src/html/desktop            \
  --machines src/html/desktop/machines/ \
  --novnc $PWD/src/html/desktop/novnc/
```
then connect within a browser to the displayed IP, such as:
- http://127.0.0.1:6080/vnc.html?host=127.0.0.1&port=6080

and enter the displayed token (to secure the VNC connection), such as:
- 8nrnmcru

This package provides a minimal ISO for testing:
- [Damn Small Linux](http://www.damnsmalllinux.org/)

It does not properly work with modern systems. Expect strange behaviours with 
the mouse and keyboard.

Usage: as a web service
=======================


